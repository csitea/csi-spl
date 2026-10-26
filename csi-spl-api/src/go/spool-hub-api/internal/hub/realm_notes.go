package hub

import (
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The Notes routes (spec 155 v1.1 sections 2.4, 5 and 6, build row B4): a
// person's own notes in the personal realm, shown in every workspace they
// belong to (D1).
//
//	GET    /v1/me/realm/notes                          the list (summaries)
//	POST   /v1/me/realm/notes                          a new note
//	DELETE /v1/me/realm/notes                          erase every note
//	GET    /v1/me/realm/notes/export                   every note whole, as a file
//	GET    /v1/me/realm/notes/{id}                     one note, items and links
//	PATCH  /v1/me/realm/notes/{id}                     title, body, pinned, archived, position
//	DELETE /v1/me/realm/notes/{id}                     the note; items and links cascade
//	PUT    /v1/me/realm/notes/{id}/items               the whole checklist
//	POST   /v1/me/realm/notes/{id}/links               one more link
//	PATCH  /v1/me/realm/notes/{id}/links/{link_id}     a link's label or position
//	DELETE /v1/me/realm/notes/{id}/links/{link_id}     one link
//
// Who: realmCaller (realm.go), so the person is the session's HUM-* alone;
// a workspace header is 400 tenant_named, an act-as clone, an agent or a box
// token 403 person_only. Another person's note id is 404, never 403 (spec
// 5): the store reads it as ErrNotFound.
//
// D4 (2.4): every answer that carries a link compares its workspace with the
// person's seats; a link into a workspace the person no longer belongs to
// comes back with label "" and left true, and each note write passes the
// seats to the store, which erases those stored labels in its transaction.
//
// Kill switch (section 6): Options.NotesEnabled false answers every route
// 404 notes_off to the signed-in person; the stored notes stay.
//
// Privacy (2.8): a log line carries the op, the person id, the note id and
// the outcome, never a title, body, checklist line, label, ref or URL.

const (
	notesOff = "notes_off"
	// notesBodyMax holds the largest note the store admits: a 20 000
	// character body, 200 lines of 500 and 100 links of a 2 048 character
	// ref, at up to 4 bytes a character, plus the JSON around them.
	notesBodyMax = 2 << 20
)

// notesMe is the caller of a notes route: the realm person, the store and
// the workspaces the person sits in now (D4).
type notesMe struct {
	person string
	st     store.Notes
	ws     []string
}

// notesCaller is realmCaller, then the kill switch, plus the person's seats:
// a caller that is not a person is refused before the switch answers, as on
// the other realm routes (the demo walk, FR-003).
func (s *Server) notesCaller(w http.ResponseWriter, r *http.Request) (notesMe, bool) {
	c, ok := s.realmCaller(w, r)
	if !ok {
		return notesMe{}, false
	}
	if !s.o.NotesEnabled {
		writeErr(w, http.StatusNotFound, notesOff, "notes are switched off on this hub")
		return notesMe{}, false
	}
	ns, ok := c.st.(store.Notes)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "realm_unavailable", "notes are not kept by this hub")
		return notesMe{}, false
	}
	ml, ok := s.o.Store.(store.MembershipLister)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "realm_unavailable", "the personal realm is unavailable")
		return notesMe{}, false
	}
	seats, err := ml.Memberships(r.Context(), c.person)
	if err != nil {
		s.o.Log.Error().Err(err).Str("op", "notes_caller").Str("person", c.person).Msg("notes")
		writeErr(w, http.StatusServiceUnavailable, "realm_unavailable", "the personal realm is unavailable")
		return notesMe{}, false
	}
	ws := make([]string, 0, len(seats))
	for _, m := range seats {
		ws = append(ws, m.TenantID)
	}
	return notesMe{person: c.person, st: ns, ws: ws}, true
}

// notesLog is the one log line of a notes write: ids and the outcome only.
func (s *Server) notesLog(op string, c notesMe, noteID, outcome string) {
	s.o.Log.Info().Str("op", op).Str("person", c.person).Str("note", noteID).Str("outcome", outcome).Msg("notes")
}

// notesFail answers a store error; the log line carries the op, the ids and
// the error, never a note value.
func (s *Server) notesFail(w http.ResponseWriter, op string, c notesMe, noteID string, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such note")
	case errors.Is(err, store.ErrNotesFull):
		writeErr(w, http.StatusBadRequest, "notes_full", "the person holds the most notes allowed")
	case errors.Is(err, store.ErrRealmBad):
		writeErr(w, http.StatusBadRequest, "bad_note", strings.TrimPrefix(err.Error(), "store: "))
	case errors.Is(err, store.ErrNoPerson):
		writeErr(w, http.StatusForbidden, realmPersonly, "the personal realm is for the signed-in person only")
	default:
		s.o.Log.Error().Err(err).Str("op", op).Str("person", c.person).Str("note", noteID).Msg("notes")
		writeErrCause(w, http.StatusInternalServerError, "internal", "notes are unavailable", err)
	}
}

// readNotesJSON: a capped body, no unknown field (a person_id is 400).
func readNotesJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	return readJSONStrict(w, r, v, notesBodyMax, "invalid JSON body for this notes route")
}

// ---- the wire ----------------------------------------------------------------

type noteItemJSON struct {
	ID       string  `json:"id"`
	Text     string  `json:"text"`
	Done     bool    `json:"done"`
	Position float64 `json:"position"`
}

type noteLinkJSON struct {
	ID          string  `json:"id"`
	Kind        string  `json:"kind"`
	WorkspaceID string  `json:"workspace_id,omitempty"`
	Ref         string  `json:"ref"`
	Day         string  `json:"day,omitempty"`
	Label       string  `json:"label"`
	Left        bool    `json:"left"`
	Position    float64 `json:"position"`
	CreatedAt   string  `json:"created_at"`
}

type noteJSON struct {
	ID         string         `json:"id"`
	Title      string         `json:"title"`
	Body       string         `json:"body"`
	Pinned     bool           `json:"pinned"`
	Position   float64        `json:"position"`
	Archived   bool           `json:"archived"`
	ArchivedAt string         `json:"archived_at,omitempty"`
	CreatedAt  string         `json:"created_at"`
	UpdatedAt  string         `json:"updated_at"`
	Items      []noteItemJSON `json:"items"`
	Links      []noteLinkJSON `json:"links"`
}

type noteSummaryJSON struct {
	ID         string  `json:"id"`
	Title      string  `json:"title"`
	Snippet    string  `json:"snippet"`
	Pinned     bool    `json:"pinned"`
	Position   float64 `json:"position"`
	Archived   bool    `json:"archived"`
	ArchivedAt string  `json:"archived_at,omitempty"`
	UpdatedAt  string  `json:"updated_at"`
	ItemsDone  int     `json:"items_done"`
	ItemsTotal int     `json:"items_total"`
	LinkCount  int     `json:"link_count"`
}

func notesTime(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }

func notesArchived(t *time.Time) string {
	if t == nil {
		return ""
	}
	return notesTime(*t)
}

// linkOut is one link as the person may read it: D4 drops the label of a
// link into a workspace the person has left.
func (c notesMe) linkOut(l store.NoteLink) noteLinkJSON {
	out := noteLinkJSON{ID: l.ID, Kind: l.Kind, WorkspaceID: l.WorkspaceID, Ref: l.Ref, Day: l.Day,
		Label: l.Label, Position: l.Position, CreatedAt: notesTime(l.CreatedAt)}
	if l.WorkspaceID != "" && !slices.Contains(c.ws, l.WorkspaceID) {
		out.Label, out.Left = "", true
	}
	return out
}

func (c notesMe) noteOut(n store.Note) noteJSON {
	out := noteJSON{ID: n.ID, Title: n.Title, Body: n.Body, Pinned: n.Pinned, Position: n.Position,
		Archived: n.ArchivedAt != nil, ArchivedAt: notesArchived(n.ArchivedAt),
		CreatedAt: notesTime(n.CreatedAt), UpdatedAt: notesTime(n.UpdatedAt),
		Items: make([]noteItemJSON, 0, len(n.Items)), Links: make([]noteLinkJSON, 0, len(n.Links))}
	for _, it := range n.Items {
		out.Items = append(out.Items, noteItemJSON(it))
	}
	for _, l := range n.Links {
		out.Links = append(out.Links, c.linkOut(l))
	}
	return out
}

func noteSummaryOut(n store.NoteSummary) noteSummaryJSON {
	return noteSummaryJSON{ID: n.ID, Title: n.Title, Snippet: n.Snippet, Pinned: n.Pinned, Position: n.Position,
		Archived: n.ArchivedAt != nil, ArchivedAt: notesArchived(n.ArchivedAt), UpdatedAt: notesTime(n.UpdatedAt),
		ItemsDone: n.ItemsDone, ItemsTotal: n.ItemsTotal, LinkCount: n.LinkCount}
}

// noteItemIn is a checklist line as sent: an id keeps the line's id.
type noteItemIn struct {
	ID   string `json:"id"`
	Text string `json:"text"`
	Done bool   `json:"done"`
}

type noteLinkIn struct {
	Kind        string `json:"kind"`
	WorkspaceID string `json:"workspace_id"`
	Ref         string `json:"ref"`
	Day         string `json:"day"`
	Label       string `json:"label"`
}

func noteItemsIn(in []noteItemIn) []store.NoteItem {
	out := make([]store.NoteItem, 0, len(in))
	for _, it := range in {
		out = append(out, store.NoteItem{ID: it.ID, Text: it.Text, Done: it.Done})
	}
	return out
}

func (l noteLinkIn) link() store.NoteLink {
	return store.NoteLink{Kind: l.Kind, WorkspaceID: l.WorkspaceID, Ref: l.Ref, Day: l.Day, Label: l.Label}
}

// ---- the list, create, erase, export -----------------------------------------

// GET /v1/me/realm/notes: every note of the person as a summary, archived
// ones too (the WUI filters them).
func (s *Server) handleListNotes(w http.ResponseWriter, r *http.Request) {
	c, ok := s.notesCaller(w, r)
	if !ok {
		return
	}
	ns, err := c.st.ListNotes(r.Context(), c.person)
	if err != nil {
		s.notesFail(w, "notes_list", c, "", err)
		return
	}
	out := make([]noteSummaryJSON, 0, len(ns))
	for _, n := range ns {
		out = append(out, noteSummaryOut(n))
	}
	writeJSON(w, http.StatusOK, map[string]any{"notes": out})
}

type noteCreateIn struct {
	Title  string       `json:"title"`
	Body   string       `json:"body"`
	Pinned bool         `json:"pinned"`
	Items  []noteItemIn `json:"items"`
	Links  []noteLinkIn `json:"links"`
}

// POST /v1/me/realm/notes: a new note on top of the person's order; 201.
func (s *Server) handleCreateNote(w http.ResponseWriter, r *http.Request) {
	c, ok := s.notesCaller(w, r)
	if !ok {
		return
	}
	var in noteCreateIn
	if !readNotesJSON(w, r, &in) {
		return
	}
	n := store.Note{Title: in.Title, Body: in.Body, Pinned: in.Pinned, Items: noteItemsIn(in.Items)}
	for _, l := range in.Links {
		n.Links = append(n.Links, l.link())
	}
	got, err := c.st.CreateNote(r.Context(), c.person, n, s.o.Now())
	if err != nil {
		s.notesFail(w, "notes_create", c, "", err)
		return
	}
	s.notesLog("notes_create", c, got.ID, "created")
	writeJSON(w, http.StatusCreated, c.noteOut(got))
}

// DELETE /v1/me/realm/notes: erases every note of the person (2.8); 204.
func (s *Server) handleEraseNotes(w http.ResponseWriter, r *http.Request) {
	c, ok := s.notesCaller(w, r)
	if !ok {
		return
	}
	if _, err := c.st.EraseNotes(r.Context(), c.person); err != nil {
		s.notesFail(w, "notes_erase", c, "", err)
		return
	}
	s.notesLog("notes_erase", c, "", "erased")
	w.WriteHeader(http.StatusNoContent)
}

// GET /v1/me/realm/notes/export: every note whole, archived ones too, as one
// JSON file notes-<date>.json (2.8).
func (s *Server) handleExportNotes(w http.ResponseWriter, r *http.Request) {
	c, ok := s.notesCaller(w, r)
	if !ok {
		return
	}
	ns, err := c.st.ExportNotes(r.Context(), c.person)
	if err != nil {
		s.notesFail(w, "notes_export", c, "", err)
		return
	}
	out := make([]noteJSON, 0, len(ns))
	for _, n := range ns {
		out = append(out, c.noteOut(n))
	}
	now := s.o.Now().UTC()
	w.Header().Set("Content-Disposition", `attachment; filename="notes-`+now.Format(time.DateOnly)+`.json"`)
	s.notesLog("notes_export", c, "", "exported")
	writeJSON(w, http.StatusOK, map[string]any{"exported_at": notesTime(now), "notes": out})
}

// ---- one note ----------------------------------------------------------------

// GET /v1/me/realm/notes/{id}: the note with its items and links.
func (s *Server) handleGetNote(w http.ResponseWriter, r *http.Request) {
	c, ok := s.notesCaller(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	n, err := c.st.NoteOf(r.Context(), c.person, id)
	if err != nil {
		s.notesFail(w, "notes_get", c, id, err)
		return
	}
	writeJSON(w, http.StatusOK, c.noteOut(n))
}

type notePatchIn struct {
	Title    *string  `json:"title"`
	Body     *string  `json:"body"`
	Pinned   *bool    `json:"pinned"`
	Archived *bool    `json:"archived"`
	Position *float64 `json:"position"`
}

// PATCH /v1/me/realm/notes/{id}: the fields sent; the others are kept.
func (s *Server) handlePatchNote(w http.ResponseWriter, r *http.Request) {
	c, ok := s.notesCaller(w, r)
	if !ok {
		return
	}
	var in notePatchIn
	if !readNotesJSON(w, r, &in) {
		return
	}
	id := r.PathValue("id")
	p := store.NotePatch{Title: in.Title, Body: in.Body, Pinned: in.Pinned, Archived: in.Archived, Position: in.Position}
	n, err := c.st.PatchNote(r.Context(), c.person, id, p, c.ws, s.o.Now())
	if err != nil {
		s.notesFail(w, "notes_patch", c, id, err)
		return
	}
	s.notesLog("notes_patch", c, id, "patched")
	writeJSON(w, http.StatusOK, c.noteOut(n))
}

// DELETE /v1/me/realm/notes/{id}: 204; its items and links cascade.
func (s *Server) handleDeleteNote(w http.ResponseWriter, r *http.Request) {
	c, ok := s.notesCaller(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	if err := c.st.DeleteNote(r.Context(), c.person, id); err != nil {
		s.notesFail(w, "notes_delete", c, id, err)
		return
	}
	s.notesLog("notes_delete", c, id, "deleted")
	w.WriteHeader(http.StatusNoContent)
}

// PUT /v1/me/realm/notes/{id}/items: the whole checklist, in the order sent.
func (s *Server) handlePutNoteItems(w http.ResponseWriter, r *http.Request) {
	c, ok := s.notesCaller(w, r)
	if !ok {
		return
	}
	var in struct {
		Items []noteItemIn `json:"items"`
	}
	if !readNotesJSON(w, r, &in) {
		return
	}
	id := r.PathValue("id")
	n, err := c.st.PutNoteItems(r.Context(), c.person, id, noteItemsIn(in.Items), c.ws, s.o.Now())
	if err != nil {
		s.notesFail(w, "notes_items", c, id, err)
		return
	}
	s.notesLog("notes_items", c, id, "replaced")
	writeJSON(w, http.StatusOK, c.noteOut(n))
}

// ---- links -------------------------------------------------------------------

// POST /v1/me/realm/notes/{id}/links: one more link, after the others; 201.
func (s *Server) handleAddNoteLink(w http.ResponseWriter, r *http.Request) {
	c, ok := s.notesCaller(w, r)
	if !ok {
		return
	}
	var in noteLinkIn
	if !readNotesJSON(w, r, &in) {
		return
	}
	id := r.PathValue("id")
	l, err := c.st.AddNoteLink(r.Context(), c.person, id, in.link(), c.ws, s.o.Now())
	if err != nil {
		s.notesFail(w, "notes_link_add", c, id, err)
		return
	}
	s.notesLog("notes_link_add", c, id, "added")
	writeJSON(w, http.StatusCreated, c.linkOut(l))
}

// PATCH /v1/me/realm/notes/{id}/links/{link_id}: the label or the position.
func (s *Server) handlePatchNoteLink(w http.ResponseWriter, r *http.Request) {
	c, ok := s.notesCaller(w, r)
	if !ok {
		return
	}
	var in struct {
		Label    *string  `json:"label"`
		Position *float64 `json:"position"`
	}
	if !readNotesJSON(w, r, &in) {
		return
	}
	id := r.PathValue("id")
	p := store.NoteLinkPatch{Label: in.Label, Position: in.Position}
	l, err := c.st.PatchNoteLink(r.Context(), c.person, id, r.PathValue("link_id"), p, c.ws, s.o.Now())
	if err != nil {
		s.notesFail(w, "notes_link_patch", c, id, err)
		return
	}
	s.notesLog("notes_link_patch", c, id, "patched")
	writeJSON(w, http.StatusOK, c.linkOut(l))
}

// DELETE /v1/me/realm/notes/{id}/links/{link_id}: 204.
func (s *Server) handleDeleteNoteLink(w http.ResponseWriter, r *http.Request) {
	c, ok := s.notesCaller(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	if err := c.st.DeleteNoteLink(r.Context(), c.person, id, r.PathValue("link_id"), c.ws, s.o.Now()); err != nil {
		s.notesFail(w, "notes_link_delete", c, id, err)
		return
	}
	s.notesLog("notes_link_delete", c, id, "deleted")
	w.WriteHeader(http.StatusNoContent)
}

// ---- routes ------------------------------------------------------------------

// routeRealmNotes registers spec 155's notes routes; routeMe calls it.
func (s *Server) routeRealmNotes(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/me/realm/notes", s.handleListNotes)
	mux.HandleFunc("POST /v1/me/realm/notes", s.handleCreateNote)
	mux.HandleFunc("DELETE /v1/me/realm/notes", s.handleEraseNotes)
	mux.HandleFunc("OPTIONS /v1/me/realm/notes", s.realmPreflight("GET, POST, DELETE"))
	mux.HandleFunc("GET /v1/me/realm/notes/export", s.handleExportNotes)
	mux.HandleFunc("OPTIONS /v1/me/realm/notes/export", s.realmPreflight("GET"))
	mux.HandleFunc("GET /v1/me/realm/notes/{id}", s.handleGetNote)
	mux.HandleFunc("PATCH /v1/me/realm/notes/{id}", s.handlePatchNote)
	mux.HandleFunc("DELETE /v1/me/realm/notes/{id}", s.handleDeleteNote)
	mux.HandleFunc("OPTIONS /v1/me/realm/notes/{id}", s.realmPreflight("GET, PATCH, DELETE"))
	mux.HandleFunc("PUT /v1/me/realm/notes/{id}/items", s.handlePutNoteItems)
	mux.HandleFunc("OPTIONS /v1/me/realm/notes/{id}/items", s.realmPreflight("PUT"))
	mux.HandleFunc("POST /v1/me/realm/notes/{id}/links", s.handleAddNoteLink)
	mux.HandleFunc("OPTIONS /v1/me/realm/notes/{id}/links", s.realmPreflight("POST"))
	mux.HandleFunc("PATCH /v1/me/realm/notes/{id}/links/{link_id}", s.handlePatchNoteLink)
	mux.HandleFunc("DELETE /v1/me/realm/notes/{id}/links/{link_id}", s.handleDeleteNoteLink)
	mux.HandleFunc("OPTIONS /v1/me/realm/notes/{id}/links/{link_id}", s.realmPreflight("PATCH, DELETE"))
}
