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
// tenant-scoped, in retention only. Messages, files and threads live here;
// robots, users, channels and boxes are small and the hub filters the rows
// ViewBoxes / Humans / ViewChannelStats already return.

// ErrSearchBudget is a search statement that ran past its time budget
// (search-v1 §5.1: 503 search_budget).
var ErrSearchBudget = errors.New("search: time budget exceeded")

// SearchQuery is one section's page.
type SearchQuery struct {
	Q      *search.Query
	Now    time.Time
	Viewer string // member HUM-*: DMs only when party of the thread; "" = no filter (door off)
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

// SearchThreadRow is one matching thread.
type SearchThreadRow struct {
	ThreadRow
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
	SearchThreads(ctx context.Context, tenant string, q SearchQuery) ([]SearchThreadRow, error)
	// TenantHumans lists the tenant's member humans (disabled excluded),
	// sorted by HUM-* id.
	TenantHumans(ctx context.Context, tenant string) ([]HumanEntry, error)
}

// Title is a thread's title: the first line of its first body, trimmed, at
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

// viewerTasksLocked: the live tasks the viewer is party of (DM privacy).
func (s *Memory) viewerTasksLocked(live []*Message, viewer string) map[string]bool {
	out := map[string]bool{}
	for _, m := range live {
		if m.FromID == viewer || m.ToID == viewer {
			out[m.TaskID] = true
		}
	}
	return out
}

func (s *Memory) SearchMessages(_ context.Context, tenant string, q SearchQuery) ([]SearchMsgRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	live := s.liveLocked(tenant, q.Now)
	mine := s.viewerTasksLocked(live, q.Viewer)
	var out []SearchMsgRow
	for i := len(live) - 1; i >= 0; i-- { // newest first
		m := live[i]
		if q.Viewer != "" && m.Channel == "" && !mine[m.TaskID] {
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
	mine := s.viewerTasksLocked(live, q.Viewer)
	var out []SearchFileRow
	for i := len(live) - 1; i >= 0; i-- {
		m := live[i]
		if q.Viewer != "" && m.Channel == "" && !mine[m.TaskID] {
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

func (s *Memory) SearchThreads(_ context.Context, tenant string, q SearchQuery) ([]SearchThreadRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	byTask := map[string]*SearchThreadRow{}
	msgs := map[string][]search.Msg{}
	var order []string
	for _, m := range s.liveLocked(tenant, q.Now) { // oldest first
		r := byTask[m.TaskID]
		if r == nil {
			r = &SearchThreadRow{ThreadRow: ThreadRow{TaskID: m.TaskID, Channel: m.Channel, Parent: m.ParentTaskID,
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
	var out []SearchThreadRow
	for _, id := range order {
		r := byTask[id]
		if q.Viewer != "" && r.Channel == "" {
			party := false
			for _, m := range msgs[id] {
				party = party || m.FromID == q.Viewer || m.ToID == q.Viewer
			}
			if !party {
				continue
			}
		}
		th := search.Thread{TaskID: id, Parent: r.Parent, Channel: r.Channel, Title: r.Title, LastAt: r.LastAt, Msgs: msgs[id]}
		if !search.MatchThread(q.Q.Root, th) || !q.older(r.LastAt, r.TaskID) {
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

// sortHumans orders by the HUM-* number (HUM-2 before HUM-10).
func sortHumans(hs []HumanEntry) {
	num := func(id string) int {
		n := 0
		for _, r := range strings.TrimPrefix(id, "HUM-") {
			n = n*10 + int(r-'0')
		}
		return n
	}
	sort.Slice(hs, func(i, j int) bool { return num(hs[i].HumanID) < num(hs[j].HumanID) })
}
