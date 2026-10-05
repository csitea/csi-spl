package hub

import (
	"net/http"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// POST /v1/view/previews (topic e1f8f797): the topics and messages that the
// visible message bodies LINK to, resolved in one call into short preview
// cards: the kind, a title (the topic's first line, at most 100 characters),
// up to three excerpt lines, the author and the time. The door is
// /v1/view/ids': the session's tenant, then the reader's channels and DM
// ends. On top of it the row a card prints must itself be readable: a topic
// whose first message the reader may not read has no card. An id the reader
// may not read reads exactly like an unknown one: it is left out, so the
// link stays a plain link and never leaks a title.

const (
	viewPreviewsMax     = 20
	viewPreviewsMaxBody = 4 << 10
	previewTitleMax     = 100
	previewLineMax      = 160
	previewLines        = 3
)

// viewPreview is one card. id is the uuid as asked; task_id / msg_id / channel
// / peer are where the card opens, as /v1/view/ids answers them.
type viewPreview struct {
	viewIDHit
	Title   string `json:"title"`
	Excerpt string `json:"excerpt"`
	From    string `json:"from"`
	TS      string `json:"ts"`
}

type viewPreviewsBody struct {
	Previews []viewPreview `json:"previews"`
}

func (s *Server) handleViewPreviews(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	var req viewIDsReq
	if !readJSONStrict(w, r, &req, viewPreviewsMaxBody, "invalid JSON body (only ids)") {
		return
	}
	ids, rf := viewPreviewIDs(req.IDs)
	if rf != nil {
		writeErr(w, rf.status, rf.token, rf.detail)
		return
	}
	body := viewPreviewsBody{Previews: []viewPreview{}}
	lk, ok := s.o.Store.(store.IDLookups)
	pv, ok2 := s.o.Store.(store.LinkPreviews)
	if !ok || !ok2 || len(ids) == 0 {
		writeJSON(w, http.StatusOK, body)
		return
	}
	hum, ok := s.readerID(r, t.ID)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "previews unavailable")
		return
	}
	mine, err := s.readerChannels(r.Context(), t.ID, hum)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "previews unavailable")
		return
	}
	facts, err := lk.LookupIDs(r.Context(), t.ID, ids, nil, s.o.Now(), s.o.LobbyTaskID)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("view previews")
		writeErr(w, http.StatusInternalServerError, "internal", "previews unavailable")
		return
	}
	rd, err := s.idReaderFor(r.Context(), t.ID, hum, mine)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "previews unavailable")
		return
	}
	var hits []viewIDHit
	var tasks, msgs []string
	for _, id := range ids {
		f, found := pickIDFact(facts, id)
		if !found {
			continue
		}
		hit, may := rd.place(f)
		if !may {
			continue
		}
		hit.ID = id
		hits = append(hits, hit)
		if !slices.Contains(tasks, f.TaskID) {
			tasks = append(tasks, f.TaskID)
		}
		if f.Kind == store.IDMessage {
			msgs = append(msgs, f.MsgID)
		}
	}
	if len(hits) == 0 {
		writeJSON(w, http.StatusOK, body)
		return
	}
	starters, rows, err := pv.PreviewRows(r.Context(), t.ID, tasks, msgs, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("view previews rows")
		writeErr(w, http.StatusInternalServerError, "internal", "previews unavailable")
		return
	}
	for _, hit := range hits {
		if p, ok := rd.preview(hit, starters, rows); ok {
			body.Previews = append(body.Previews, p)
		}
	}
	writeJSON(w, http.StatusOK, body)
}

// viewPreviewIDs is the asked ids, canonical lower case, each once, in asked
// order. Only full uuids: a link names its object exactly.
func viewPreviewIDs(raw []string) ([]string, *viewRefusal) {
	var out []string
	for _, s := range raw {
		id := strings.ToLower(strings.TrimSpace(s))
		if !uuidRe.MatchString(id) {
			return nil, &viewRefusal{http.StatusBadRequest, "bad_id", "each id is a uuid"}
		}
		if !slices.Contains(out, id) {
			out = append(out, id)
		}
	}
	if len(out) > viewPreviewsMax {
		return nil, &viewRefusal{http.StatusBadRequest, "too_many", "at most 20 ids per call"}
	}
	return out, nil
}

// readable applies the id door to one stored row: its channel, or for a DM
// row its two ends.
func (rd idReader) readable(p store.PreviewRow) bool {
	if rd.mod.drops(p.MsgID) { // specs/077 T016: a hidden message prints nothing
		return false
	}
	if p.Channel != "" {
		return rd.channel(p.Channel)
	}
	return rd.hum == "" || p.FromID == rd.hum || p.ToID == rd.hum
}

// preview is the card for hit; false when the row it would print is gone or
// not readable. A topic prints its first message: the title is its first
// line, the excerpt the lines after. A message prints its own body under
// its topic's title (its own first line when that topic's first message is
// not readable).
func (rd idReader) preview(hit viewIDHit, starters, rows map[string]store.PreviewRow) (viewPreview, bool) {
	out := viewPreview{viewIDHit: hit}
	st, hasStart := starters[hit.TaskID]
	hasStart = hasStart && rd.readable(st)
	if hit.Kind == store.IDTopic {
		if !hasStart {
			return out, false
		}
		out.Title, out.Excerpt = previewText(st.Body)
		out.From, out.TS = st.FromID, rfc(st.ReceivedAt)
		return out, true
	}
	m, ok := rows[hit.MsgID]
	if !ok || !rd.readable(m) {
		return out, false
	}
	title, rest := previewText(m.Body)
	switch {
	case hasStart && st.MsgID == m.MsgID:
		out.Title, out.Excerpt = title, rest
	case hasStart:
		out.Title, _ = previewText(st.Body)
		out.Excerpt = previewExcerpt(m.Body)
	default:
		out.Title, out.Excerpt = title, rest
	}
	out.From, out.TS = m.FromID, rfc(m.ReceivedAt)
	return out, true
}

// previewText is body's title (its first non-empty line, at most
// previewTitleMax runes) and the excerpt of the lines after it.
func previewText(body string) (title, excerpt string) {
	lines := previewLinesOf(body)
	if len(lines) == 0 {
		return "", ""
	}
	return cutRunes(lines[0], previewTitleMax), joinExcerpt(lines[1:])
}

// previewExcerpt is the first lines of body itself.
func previewExcerpt(body string) string {
	return joinExcerpt(previewLinesOf(body))
}

// previewLinesOf is body's non-empty lines, trimmed, without code fence
// markers.
func previewLinesOf(body string) []string {
	var out []string
	for _, l := range strings.Split(body, "\n") {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "```") {
			continue
		}
		out = append(out, l)
	}
	return out
}

func joinExcerpt(lines []string) string {
	if len(lines) > previewLines {
		lines = lines[:previewLines]
	}
	cut := make([]string, len(lines))
	for i, l := range lines {
		cut[i] = cutRunes(l, previewLineMax)
	}
	return strings.Join(cut, "\n")
}

// cutRunes is s cut to n runes, an ellipsis marking a cut.
func cutRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n-1]) + "…"
}
