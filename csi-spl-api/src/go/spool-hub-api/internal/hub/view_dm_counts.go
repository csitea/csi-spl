package hub

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// DM counts on the topic list (DB payload audit 2026-10-02, cut 1): the DM
// seed (`?dm=true&dm_counts=true`) used to inline each DM's newest 50
// messages, envelopes and all, only so the WUI could count the per-peer
// unread and total. The hub now counts them itself from a thin read and
// sends two small maps per topic. The rules are the WUI's, ported line for
// line so a badge reads exactly as before (utils/channel-feed.mjs
// unreadFromDms / dmTotalsFromDms, utils/read-cursor.mjs isUnread,
// utils/typed-by.mjs isViewersOwn):
//
//   - unread: an incoming DM line newer than the reader's cursor for that
//     peer. Our own lines - and one we typed at the agent's terminal
//     (typed_by, CLE-77889) - are never new; a channel row is not a DM.
//   - total (CLE-77845): every line of a topic held whole, under its own
//     peer; a topic longer than the page adds its count to each end that is
//     not us.
//
// Both count the newest dmCountsPerTopic lines of a topic, the page the WUI
// counted, and compare times as the WUI did: as strings.

// dmCountsPerTopic is the page the WUI counted (stores/channel.ts
// DM_SEED_PER_TOPIC).
const dmCountsPerTopic = perTopicMax

// viewDMCounts is one topic's per-peer counts, keyed "<id>@<box>" as the
// sidebar labels a peer ("dm:" + key is the WUI's cursor key).
type viewDMCounts struct {
	Unread map[string]int `json:"unread"`
	Total  map[string]int `json:"total"`
}

// dmCursor is the reader's read cursor for one peer: utils/read-cursor.mjs
// { ts, id }, sent as dm_read=<id>@<box>~<ts>~<msg-id>.
type dmCursor struct{ ts, id string }

// parseDMReads reads the repeated dm_read=<peer>~<ts>[~<msg-id>] marks.
// false = a malformed mark.
func parseDMReads(marks []string) (map[string]dmCursor, bool) {
	out := make(map[string]dmCursor, len(marks))
	for _, mk := range marks {
		peer, rest, ok := strings.Cut(mk, "~")
		if !ok || peer == "" || len(mk) > 256 {
			return nil, false
		}
		ts, id, _ := strings.Cut(rest, "~")
		out[peer] = dmCursor{ts: ts, id: id}
	}
	return out, true
}

// dmCountsWanted parses dm_counts= and dm_read=. false = it answered.
func dmCountsWanted(w http.ResponseWriter, r *http.Request) (bool, map[string]dmCursor, bool) {
	q := r.URL.Query()
	var want bool
	if !parseTriBool(w, q.Get("dm_counts"), "dm_counts", &want) {
		return false, nil, false
	}
	reads, ok := parseDMReads(q["dm_read"])
	if !ok {
		writeErr(w, http.StatusBadRequest, "bad_json", "dm_read must be <peer>~<ts>[~<msg-id>]")
		return false, nil, false
	}
	return want, reads, true
}

// bareID is the id part of "<id>@<box>".
func bareID(s string) string {
	id, _, _ := strings.Cut(s, "@")
	return id
}

// isViewersOwn is utils/typed-by.mjs isViewersOwn (HUMAN_ID = humanIDRe).
func isViewersOwn(m store.TopicMsgMeta, self string) bool {
	me := bareID(self)
	if me == "" {
		return false
	}
	if bareID(m.FromID) == me {
		return true
	}
	typed := bareID(m.TypedBy)
	return humanIDRe.MatchString(typed) && typed == me
}

// dmPeerOf is utils/channel-feed.mjs dmPeerOf: the end that is not us.
func dmPeerOf(m store.TopicMsgMeta, self string) string {
	for _, e := range [2][2]string{{m.FromID, m.FromBox}, {m.ToID, m.ToBox}} {
		if e[0] == "" || e[0] == self || e[0] == "ALL-0" {
			continue
		}
		if e[1] != "" {
			return e[0] + "@" + e[1]
		}
		return e[0]
	}
	return ""
}

// dmUnread is utils/read-cursor.mjs isUnread over the view's received_at.
func dmUnread(m store.TopicMsgMeta, c dmCursor, ok bool) bool {
	if !ok || c.ts == "" {
		return true
	}
	ts := rfc(m.ReceivedAt)
	if ts != c.ts {
		return ts > c.ts
	}
	return m.MsgID != c.id
}

// dmCounts is one topic's counts from its newest lines (newest first, at
// most dmCountsPerTopic) and the topic row.
func dmCounts(v viewTopic, msgs []store.TopicMsgMeta, self string, reads map[string]dmCursor) *viewDMCounts {
	out := &viewDMCounts{Unread: map[string]int{}, Total: map[string]int{}}
	for _, m := range msgs {
		if m.Channel != "" || m.FromID == "" || isViewersOwn(m, self) {
			continue
		}
		peer := dmPeerOf(m, self)
		if peer == "" {
			continue
		}
		c, ok := reads[peer]
		if dmUnread(m, c, ok) {
			out.Unread[peer]++
		}
	}
	if len(msgs) >= v.Count {
		for _, m := range msgs {
			if p := dmPeerOf(m, self); m.Channel == "" && p != "" {
				out.Total[p]++
			}
		}
		return out
	}
	for _, label := range v.Participants {
		id := bareID(label)
		if id == "" || id == self || id == "ALL-0" {
			continue
		}
		out.Total[label] += v.Count
	}
	return out
}

// attachDMCounts reads the newest lines of every topic in out through the
// reader door of sq and sets each topic's DM counts. false = it answered.
func (s *Server) attachDMCounts(w http.ResponseWriter, r *http.Request, t store.Tenant, sq store.TopicQuery, reads map[string]dmCursor, out []viewTopic) bool {
	ids := make([]string, len(out))
	for i := range out {
		ids[i] = out[i].TaskID
	}
	var meta map[string][]store.TopicMsgMeta
	var err error
	if b, ok := s.o.Store.(store.TopicsMetaReader); ok {
		meta, err = b.ViewTopicsMeta(r.Context(), t.ID, store.TopicsMsgQuery{TaskIDs: ids, PerTopic: dmCountsPerTopic,
			Reader: sq.Reader, ReaderChannels: sq.ReaderChannels, HideArchivedIn: s.o.LobbyTaskID, Now: sq.Now})
	} else {
		meta = map[string][]store.TopicMsgMeta{}
		for _, id := range ids {
			var rows []store.ViewMsg
			if rows, err = s.o.Store.ViewTopic(r.Context(), t.ID, store.TopicMsgQuery{TaskID: id, Desc: true, Limit: dmCountsPerTopic,
				Reader: sq.Reader, ReaderChannels: sq.ReaderChannels, HideArchived: id == s.o.LobbyTaskID && id != "", Now: sq.Now}); err != nil {
				break
			}
			for _, m := range rows {
				meta[id] = append(meta[id], metaOf(m))
			}
		}
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("topics dm_counts")
		writeErr(w, http.StatusInternalServerError, "internal", "topics unavailable")
		return false
	}
	for i := range out {
		out[i].DM = dmCounts(out[i], meta[out[i].TaskID], sq.Reader, reads)
	}
	return true
}

// metaOf is the TopicMsgMeta of a full view row (the store without the thin
// read): the ends from the envelope, the place from the row.
func metaOf(m store.ViewMsg) store.TopicMsgMeta {
	var env struct {
		FromBox string `json:"from_box"`
		ToBox   string `json:"to_box"`
		Msg     struct {
			From string `json:"from"`
			To   string `json:"to"`
		} `json:"msg"`
	}
	_ = json.Unmarshal(m.Env, &env)
	ch := m.RowChannel
	if m.Move.Moved() {
		ch = m.Move.Channel
	}
	return store.TopicMsgMeta{MsgID: m.MsgID, ReceivedAt: m.ReceivedAt, FromID: env.Msg.From, FromBox: env.FromBox,
		ToID: env.Msg.To, ToBox: env.ToBox, TypedBy: m.TypedBy, Channel: ch}
}
