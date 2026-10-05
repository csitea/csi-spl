package hub

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// DM counts on the topic list (DB payload audit 2026-10-02, cut 1): the DM
// seed (`?dm=true&dm_counts=true`) used to inline each DM's newest 50
// messages, envelopes and all, only so the WUI could count the per-peer
// unread and total. The hub sends two small maps per topic instead. The
// rules are the WUI's, ported line for line so a badge reads exactly as
// before: store.DMPageCounts counts a topic's page (and, round 2 R2-4,
// Postgres counts it in SQL with one GROUP BY, ViewTopicsDMCounts), and
// dmCounts adds the topic-level rule:
//
//   - total (CLE-77845): a topic held whole totals its page per peer; a
//     topic longer than the page adds its count to each end that is not us.
//
// Both count the newest dmCountsPerTopic lines of a topic, the page the WUI
// counted.

// dmCountsPerTopic is the page the WUI counted (stores/channel.ts
// DM_SEED_PER_TOPIC).
const dmCountsPerTopic = perTopicMax

// viewDMCounts is one topic's per-peer counts, keyed "<id>@<box>" as the
// sidebar labels a peer ("dm:" + key is the WUI's cursor key).
type viewDMCounts struct {
	Unread map[string]int `json:"unread"`
	Total  map[string]int `json:"total"`
}

// parseDMReads reads the repeated dm_read=<peer>~<ts>[~<msg-id>] marks.
// false = a malformed mark.
func parseDMReads(marks []string) (map[string]store.DMRead, bool) {
	out := make(map[string]store.DMRead, len(marks))
	for _, mk := range marks {
		peer, rest, ok := strings.Cut(mk, "~")
		if !ok || peer == "" || len(mk) > 256 {
			return nil, false
		}
		ts, id, _ := strings.Cut(rest, "~")
		out[peer] = store.DMRead{TS: ts, MsgID: id}
	}
	return out, true
}

// dmCountsWanted parses dm_counts= and dm_read=. false = it answered.
func dmCountsWanted(w http.ResponseWriter, r *http.Request) (bool, map[string]store.DMRead, bool) {
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

// dmCounts is one topic's counts from its page counts and the topic row.
func dmCounts(v viewTopic, c store.TopicDMCounts, self string) *viewDMCounts {
	out := &viewDMCounts{Unread: c.Unread, Total: c.Total}
	if out.Unread == nil {
		out.Unread = map[string]int{}
	}
	if c.Page >= v.Count {
		if out.Total == nil {
			out.Total = map[string]int{}
		}
		return out
	}
	out.Total = map[string]int{}
	for _, label := range v.Participants {
		id, _, _ := strings.Cut(label, "@")
		if id == "" || id == self || id == "ALL-0" {
			continue
		}
		out.Total[label] += v.Count
	}
	return out
}

// attachDMCounts counts the newest lines of every topic in out through the
// reader door of sq and sets each topic's DM counts. false = it answered.
func (s *Server) attachDMCounts(w http.ResponseWriter, r *http.Request, t store.Tenant, sq store.TopicQuery, reads map[string]store.DMRead, out []viewTopic) bool {
	ids := make([]string, len(out))
	for i := range out {
		ids[i] = out[i].TaskID
	}
	q := store.TopicsMsgQuery{TaskIDs: ids, PerTopic: dmCountsPerTopic,
		Reader: sq.Reader, ReaderChannels: sq.ReaderChannels, HideArchivedIn: s.o.LobbyTaskID, Now: sq.Now}
	counts := map[string]store.TopicDMCounts{}
	var err error
	if b, ok := s.o.Store.(store.TopicsDMCounter); ok {
		counts, err = b.ViewTopicsDMCounts(r.Context(), t.ID, q, reads)
	} else {
		counts, err = s.dmCountsByTopic(r, t.ID, q, reads)
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("topics dm_counts")
		writeErr(w, http.StatusInternalServerError, "internal", "topics unavailable")
		return false
	}
	for i := range out {
		out[i].DM = dmCounts(out[i], counts[out[i].TaskID], sq.Reader)
	}
	return true
}

// dmCountsByTopic is the fallback for a store without the batch count: one
// ViewTopic per topic, counted by store.DMPageCounts.
func (s *Server) dmCountsByTopic(r *http.Request, tenant string, q store.TopicsMsgQuery, reads map[string]store.DMRead) (map[string]store.TopicDMCounts, error) {
	out := map[string]store.TopicDMCounts{}
	for _, id := range q.TaskIDs {
		rows, err := s.o.Store.ViewTopic(r.Context(), tenant, store.TopicMsgQuery{TaskID: id, Desc: true, Limit: q.PerTopic,
			Reader: q.Reader, ReaderChannels: q.ReaderChannels, HideArchived: id == q.HideArchivedIn && id != "", Now: q.Now})
		if err != nil {
			return nil, err
		}
		msgs := make([]store.TopicMsgMeta, 0, len(rows))
		for _, m := range rows {
			msgs = append(msgs, metaOf(m, s.o.Log))
		}
		out[id] = store.DMPageCounts(msgs, q.Reader, reads)
	}
	return out, nil
}

// metaOf is the TopicMsgMeta of a full view row (the store without the thin
// read): the ends from the envelope, the place from the row. An undecodable
// envelope yields empty ends, so the row counts as no-party; the decode error
// is logged at debug with the msg_id so a corrupt envelope is visible.
func metaOf(m store.ViewMsg, log zerolog.Logger) store.TopicMsgMeta {
	var env struct {
		FromBox string `json:"from_box"`
		ToBox   string `json:"to_box"`
		Msg     struct {
			From string `json:"from"`
			To   string `json:"to"`
		} `json:"msg"`
	}
	if err := json.Unmarshal(m.Env, &env); err != nil {
		log.Debug().Err(err).Str("msg_id", m.MsgID).Msg("dm_counts: undecodable envelope, no ends")
	}
	ch := m.RowChannel
	if m.Move.Moved() {
		ch = m.Move.Channel
	}
	return store.TopicMsgMeta{MsgID: m.MsgID, ReceivedAt: m.ReceivedAt, FromID: env.Msg.From, FromBox: env.FromBox,
		ToID: env.Msg.To, ToBox: env.ToBox, TypedBy: m.TypedBy, Channel: ch}
}
