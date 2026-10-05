package hub

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A member's read marks on the hub (rdb 0098, CLE-77930). The owner, t1
// bf737f3f: unread is "for me and me only ... not the new messages which I
// have seen" - and the cursors lived only in one browser's storage, so a line
// read on the phone stayed new on the desktop. GET /v1/me/reads answers every
// mark; PUT /v1/me/reads moves the marks it names forward (never back) and
// answers those marks only, as stored (a later one from another device wins),
// so a tab learns where each mark it sent now stands. The rest of the map
// reaches a tab on its GET (load, and every time it is shown again): perf
// edition 20261004 E11, prd 24 h n=11 113 PUTs answered the whole map at p50
// 16.7 KB each. ?full=1 still answers every mark, for a caller that merged
// other devices' marks off the PUT. GET
// /v1/view/channels counts unread against these marks as well as its read=
// (store channelMarksCTE, inside the stats batch: no extra round trip).

// wireReadMark is one mark on the wire: ts/id are the WUI cursor's, cursor
// the view-v1 one (a channel row's last_cursor), count a thread's seen total.
type wireReadMark struct {
	TS     string `json:"ts,omitempty"`
	ID     string `json:"id,omitempty"`
	Cursor string `json:"cursor,omitempty"`
	Count  int    `json:"count,omitempty"`
}

// readMarkSkew is how far ahead of the hub's clock a mark may claim to be: a
// device clock running fast must not mark lines read before they arrive.
const readMarkSkew = time.Minute

func (s *Server) readMarkStore() (store.ReadMarks, bool) {
	rm, ok := s.o.Store.(store.ReadMarks)
	return rm, ok
}

func wireReadMarks(marks map[string]store.ReadMark) map[string]wireReadMark {
	out := make(map[string]wireReadMark, len(marks))
	for k, m := range marks {
		w := wireReadMark{TS: rfc(m.At), ID: m.MsgID, Count: m.Seen}
		if m.MsgID != "" {
			w.Cursor = encCursor(m.At, m.MsgID)
		}
		out[k] = w
	}
	return out
}

// parseReadMarkBody validates PUT /v1/me/reads: at most store.MaxReadMarks
// keys, each ch:/t:/dm: or f:seen / f:<msg_id> (spec 062), each with a cursor or an RFC 3339 ts; a mark ahead of
// now is clamped to now.
func parseReadMarkBody(in map[string]wireReadMark, now time.Time) (map[string]store.ReadMark, bool) {
	if len(in) > store.MaxReadMarks {
		return nil, false
	}
	out := make(map[string]store.ReadMark, len(in))
	for k, w := range in {
		if !store.ValidReadMarkKey(k) || w.Count < 0 {
			return nil, false
		}
		m := store.ReadMark{MsgID: w.ID, Seen: w.Count}
		if w.Cursor != "" {
			at, id, err := decCursor(w.Cursor)
			if err != nil {
				return nil, false
			}
			m.At, m.MsgID = at, id
		} else {
			at, err := time.Parse(time.RFC3339Nano, w.TS)
			if err != nil {
				return nil, false
			}
			m.At = at
		}
		if len(m.MsgID) > 200 {
			return nil, false
		}
		if m.At.After(now.Add(readMarkSkew)) {
			m.At = now
		}
		out[k] = m
	}
	return out, true
}

// handleReadMarks is GET and PUT /v1/me/reads.
func (s *Server) handleReadMarks(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return
	}
	if hum == "" {
		writeForbidden(w, rbac.TopicsRead, "read marks need a signed-in member session")
		return
	}
	rm, ok := s.readMarkStore()
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "read marks unavailable")
		return
	}
	var written map[string]store.ReadMark
	if r.Method == http.MethodPut {
		var body struct {
			Marks map[string]wireReadMark `json:"marks"`
		}
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&body); err != nil || body.Marks == nil {
			writeErr(w, http.StatusBadRequest, "bad_json", "body must be {marks: {<ch:|t:|dm:|f:key>: {ts|cursor, id, count}}}")
			return
		}
		marks, valid := parseReadMarkBody(body.Marks, s.o.Now())
		if !valid {
			writeErr(w, http.StatusBadRequest, "bad_json", "at most 200 marks; keys ch:/t:/dm:<id>, f:seen or f:<msg_id>; each a cursor or an RFC 3339 ts")
			return
		}
		written = marks
		if err := rm.SaveReadMarks(r.Context(), t.ID, hum, marks, s.o.Now()); err != nil {
			s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("read marks write")
			writeErr(w, http.StatusInternalServerError, "internal", "read marks not stored")
			return
		}
		// spec 062 FR-007: the member's flow counts move on every socket at
		// once. The store announced the write (spool_wui "f:<member>"), and
		// each process's wake worker pushes the frame; without one, push here.
		if !s.wuiWaking.Load() {
			s.pushFlowCounts(r.Context(), t.ID, hum)
		}
	}
	marks, err := rm.ReadMarksOf(r.Context(), t.ID, hum)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("read marks read")
		writeErr(w, http.StatusInternalServerError, "internal", "read marks unavailable")
		return
	}
	if written != nil && r.URL.Query().Get("full") != "1" {
		marks = onlyKeysOf(marks, written)
	}
	writeJSON(w, http.StatusOK, map[string]any{"marks": wireReadMarks(marks)})
}

// onlyKeysOf is the stored marks of the keys a PUT wrote (E11).
func onlyKeysOf(stored, written map[string]store.ReadMark) map[string]store.ReadMark {
	out := make(map[string]store.ReadMark, len(written))
	for k := range written {
		if m, ok := stored[k]; ok {
			out[k] = m
		}
	}
	return out
}

// readMarksPreflight: GET/PUT with the headers every browser route allows.
func (s *Server) readMarksPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PUT")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}
