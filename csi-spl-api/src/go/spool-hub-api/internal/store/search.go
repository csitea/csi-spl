package store

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
)

// Search (specs/003 contracts/search-v1.md, FR-029 – FR-032). Read-only,
// tenant-scoped, in retention only. Messages, files and topics live here;
// robots, users, channels and boxes are small and the hub filters the rows
// ViewBoxes / Humans / ViewChannelStats already return.

// The issue workflow's closed sets reach the search grammar (1.2: status:,
// priority:) from here, the one place they are defined (issues.go).
func init() {
	search.IssueStatuses = IssueStatuses
	search.IssueStatusNormalize = NormalizeIssueStatus
	search.IssuePriorityMin = IssuePriorityMin
	search.IssuePriorityMax = IssuePriorityMax
}

// ErrSearchBudget is a search statement that ran past its time budget
// (search-v1 §5.1: 503 search_budget).
var ErrSearchBudget = errors.New("search: time budget exceeded")

// SearchQuery is one section's page.
type SearchQuery struct {
	Q      *search.Query
	Now    time.Time
	Viewer string // member HUM-*: DMs only when party of the topic; "" = no filter (door off)
	// ViewerChannels are the CREATED channels Viewer belongs to (rdb 0028).
	// Without it a search hands back the text of every channel of the
	// tenant, which is the same leak the topic read had.
	ViewerChannels []string
	// Lobby is the shared lobby task: archived topics are never searched
	// (specs/041), and an archived lobby card hides itself, not the lobby.
	Lobby  string
	Limit  int
	Budget time.Duration // Postgres statement_timeout; 0 = none

	Relevance bool // messages: rank, paged by Offset
	Offset    int
	// Keyset (newest first): strictly older than (AfterAt, AfterID[, AfterIdx]).
	AfterAt  time.Time
	AfterID  string
	AfterIdx int // files: the attachment ordinal within AfterID's message
}

// SearchMsgRow is one matching message.
type SearchMsgRow struct {
	search.Msg
	TS time.Time // the message's own signed ts
}

// SearchFileRow is one matching attachment.
type SearchFileRow struct {
	search.File
	Idx    int    // 1-based ordinal in the message's files[]
	FileID string // "" for a path attachment
	Mode   string
}

// SearchTopicRow is one matching topic.
type SearchTopicRow struct {
	TopicRow
	Title string
}

// HumanEntry is one member human as search may show it (never the email).
type HumanEntry struct {
	HumanID      string
	DisplayName  string
	AvatarFileID string
}

// Searcher is implemented by Memory and Postgres.
type Searcher interface {
	SearchMessages(ctx context.Context, tenant string, q SearchQuery) ([]SearchMsgRow, error)
	SearchFiles(ctx context.Context, tenant string, q SearchQuery) ([]SearchFileRow, error)
	SearchTopics(ctx context.Context, tenant string, q SearchQuery) ([]SearchTopicRow, error)
	// TenantHumans lists the tenant's member humans (disabled excluded),
	// sorted by HUM-* id.
	TenantHumans(ctx context.Context, tenant string) ([]HumanEntry, error)
}

// Title is a topic's title: the first line of its first body, trimmed, at
// most 140 characters (view-v1 §4.3 subject).
func Title(body string) string {
	line, _, _ := strings.Cut(body, "\n")
	line = strings.TrimSpace(line)
	if utf8.RuneCountInString(line) > 140 {
		line = string([]rune(line)[:140])
	}
	return line
}

type fileRef struct {
	Mode   string `json:"mode"`
	Kind   string `json:"kind"`
	FileID string `json:"file_id"`
	Name   string `json:"name"`
	Bytes  *int64 `json:"bytes"`
}

func fileRefs(raw []byte) []fileRef {
	var fs []fileRef
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &fs)
	}
	return fs
}

func searchMsg(m *Message) search.Msg {
	return search.Msg{MsgID: m.MsgID, TaskID: m.TaskID, Parent: m.ParentTaskID, Channel: m.Channel, Kind: m.Kind,
		Body: m.Body, FromID: m.FromID, FromBox: m.FromBox, ToID: m.ToID, ToBox: m.ToBox,
		ReceivedAt: m.ReceivedAt, Files: len(fileRefs(m.Files))}
}

// before reports (at, id) strictly older than the keyset.
func (q SearchQuery) older(at time.Time, id string) bool {
	return q.AfterAt.IsZero() || newer(q.AfterAt, q.AfterID, at, id)
}

// ---- memory -----------------------------------------------------------------------

// Hides reports whether this reader must not see a message in channel. A DM
// (channel "") is decided by party, per message: readable.
func (q SearchQuery) Hides(channel string) bool {
	if q.Viewer == "" || channel == "" || ChannelPublic(channel) {
		return false
	}
	for _, c := range q.ViewerChannels {
		if c == channel {
			return false
		}
	}
	return true
}

// readable is the per-message read door (rdb 0028, CLE-34986): a DM row by
// its two ends, a channel row by what Hides allows. "" viewer reads all.
func (q SearchQuery) readable(m *Message) bool {
	if q.Viewer == "" {
		return true
	}
	if m.Channel == "" {
		return m.FromID == q.Viewer || m.ToID == q.Viewer
	}
	return !q.Hides(m.Channel)
}

func (s *Memory) SearchMessages(_ context.Context, tenant string, q SearchQuery) ([]SearchMsgRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	live := s.liveLocked(tenant, q.Now)
	var out []SearchMsgRow
	for i := len(live) - 1; i >= 0; i-- { // newest first
		m := live[i]
		if !q.readable(m) || s.archivedHiddenLocked(tenant, m, q.Lobby) {
			continue
		}
		sm := searchMsg(m)
		if !search.MatchMsg(q.Q.Root, sm) {
			continue
		}
		if !q.Relevance && !q.older(m.ReceivedAt, m.MsgID) {
			continue
		}
		out = append(out, SearchMsgRow{Msg: sm, TS: m.TS})
	}
	if q.Relevance {
		rank := map[string]int{}
		for _, r := range out {
			rank[r.MsgID] = q.Q.Rank(r.Body)
		}
		sort.SliceStable(out, func(i, j int) bool { return rank[out[i].MsgID] > rank[out[j].MsgID] })
		if q.Offset >= len(out) {
			return nil, nil
		}
		out = out[q.Offset:]
	}
	if q.Limit > 0 && len(out) > q.Limit {
		out = out[:q.Limit]
	}
	return out, nil
}

func (s *Memory) SearchFiles(_ context.Context, tenant string, q SearchQuery) ([]SearchFileRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	live := s.liveLocked(tenant, q.Now)
	var out []SearchFileRow
	for i := len(live) - 1; i >= 0; i-- {
		m := live[i]
		if !q.readable(m) || s.archivedHiddenLocked(tenant, m, q.Lobby) {
			continue
		}
		sm := searchMsg(m)
		for j, f := range fileRefs(m.Files) {
			idx := j + 1
			if !q.AfterAt.IsZero() && !(q.older(m.ReceivedAt, m.MsgID) ||
				(m.ReceivedAt.Equal(q.AfterAt) && m.MsgID == q.AfterID && idx > q.AfterIdx)) {
				continue
			}
			sf := search.File{Msg: sm, Name: f.Name, Kind: f.Kind}
			if f.Bytes != nil {
				sf.Bytes, sf.HasBytes = *f.Bytes, true
			}
			if !search.MatchFile(q.Q.Root, sf) {
				continue
			}
			out = append(out, SearchFileRow{File: sf, Idx: idx, FileID: f.FileID, Mode: f.Mode})
			if q.Limit > 0 && len(out) == q.Limit {
				return out, nil
			}
		}
	}
	return out, nil
}

func (s *Memory) SearchTopics(_ context.Context, tenant string, q SearchQuery) ([]SearchTopicRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	byTask := map[string]*SearchTopicRow{}
	msgs := map[string][]search.Msg{}
	var order []string
	for _, m := range s.liveLocked(tenant, q.Now) { // oldest first
		if !q.readable(m) || s.archivedHiddenLocked(tenant, m, q.Lobby) { // per message, before the aggregate (CLE-34986); specs/041
			continue
		}
		r := byTask[m.TaskID]
		if r == nil {
			r = &SearchTopicRow{TopicRow: TopicRow{TaskID: m.TaskID, Channel: m.Channel, Parent: m.ParentTaskID,
				FirstAt: m.ReceivedAt, FirstMsg: m.Msg}, Title: Title(m.Body)}
			byTask[m.TaskID] = r
			order = append(order, m.TaskID)
		}
		r.LastAt = m.ReceivedAt
		r.Count++
		r.Kinds = append(r.Kinds, m.Kind)
		r.Parties = append(r.Parties, m.FromID+"@"+m.FromBox, m.ToID+"@"+m.ToBox)
		msgs[m.TaskID] = append(msgs[m.TaskID], searchMsg(m))
	}
	var out []SearchTopicRow
	for _, id := range order {
		r := byTask[id]
		th := search.Topic{TaskID: id, Parent: r.Parent, Channel: r.Channel, Title: r.Title, LastAt: r.LastAt, Msgs: msgs[id]}
		if !search.MatchTopic(q.Q.Root, th) || !q.older(r.LastAt, r.TaskID) {
			continue
		}
		out = append(out, *r)
	}
	sort.Slice(out, func(i, j int) bool { return newer(out[i].LastAt, out[i].TaskID, out[j].LastAt, out[j].TaskID) })
	if q.Limit > 0 && len(out) > q.Limit {
		out = out[:q.Limit]
	}
	return out, nil
}

func (s *Memory) TenantHumans(_ context.Context, tenant string) ([]HumanEntry, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	out := []HumanEntry{}
	for k := range s.hum.members {
		if hm, ok := s.hum.humans[k[1]]; k[0] == tenant && ok && !hm.disabled {
			out = append(out, HumanEntry{HumanID: k[1], DisplayName: hm.name, AvatarFileID: hm.avatar})
		}
	}
	sortHumans(out)
	return out, nil
}

// sortHumans orders NEWEST member first (CLE-3425: every listing is newest
// first), by the HUM-<n> the hub hands out in order - so HUM-10 before HUM-2,
// which is also why this counts digits instead of comparing strings.
func sortHumans(hs []HumanEntry) {
	/* 0 for anything that is not a HUM-<digits> (a 010 id such as
	   HUM-google-sub-1@t1): those keep a stable a-z tail instead of being
	   ranked by the character codes of their text, which is what counting
	   without this guard did. */
	num := func(id string) int {
		rest, ok := strings.CutPrefix(id, "HUM-")
		if !ok {
			return 0
		}
		n := 0
		for _, r := range rest {
			if r < '0' || r > '9' {
				return 0
			}
			n = n*10 + int(r-'0')
		}
		return n
	}
	sort.Slice(hs, func(i, j int) bool {
		if num(hs[i].HumanID) != num(hs[j].HumanID) {
			return num(hs[i].HumanID) > num(hs[j].HumanID)
		}
		return hs[i].HumanID < hs[j].HumanID
	})
}
