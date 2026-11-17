package store

import (
	"context"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

// The notes store (spec 155 v1.1 sections 2.4, 4 and 5, build row B3) over
// rdb 0225's three realm tables personal.notes, note_items and note_links.
// A note is its writer's own (D1): every call takes the person it is for,
// and that person comes only from the authenticated human session, as for
// the rest of the realm (personal.go). The Postgres side runs every
// statement in inPerson, so the person_scope policy binds it even where a
// WHERE person_id is forgotten; another person's note id reads as
// ErrNotFound, never as a refusal, so its existence is not revealed (spec
// section 5).
//
// The store stores a link's ref and label and never reads the object it
// points at (2.3). D4: a write to a note takes the person's current
// workspaces, and in the same transaction erases the stored label of each
// of its links into any other workspace (2.4). Telling the reader which
// links are into a workspace the person left is the hub's (B4).

// The limits of spec 2.4, in characters as Postgres's length() counts them.
const (
	NoteTitleMax     = 200
	NoteBodyMax      = 20000
	NoteItemsMax     = 200
	NoteItemTextMax  = 500
	NoteLinksMax     = 100
	NoteLabelMax     = 200
	NoteRefMax       = 2048
	NotesPerPerson   = 2000
	NoteSnippetChars = 200 // the list's first characters of the body (spec 5)
)

// A note's priority (rdb 0254, spec 155 2.9): the scale of the discussions
// and the issues, 1 the highest; a new note and every older one read 5.
const (
	NotePriorityHighest = 1
	NotePriorityDefault = 5
)

// ErrNotesFull: the person already holds NotesPerPerson notes (spec 2.4
// notes_full). A value outside the other limits is ErrRealmBad.
var ErrNotesFull = errors.New("store: the person holds the most notes allowed")

// The link kinds of rdb 0225 (D7, spec 2.3); only url carries no workspace.
const (
	NoteLinkMsg     = "msg"
	NoteLinkTopic   = "topic"
	NoteLinkIssue   = "issue"
	NoteLinkEvent   = "event"
	NoteLinkDoc     = "doc"
	NoteLinkChannel = "channel"
	NoteLinkURL     = "url"
)

var noteLinkKinds = map[string]bool{NoteLinkMsg: true, NoteLinkTopic: true, NoteLinkIssue: true,
	NoteLinkEvent: true, NoteLinkDoc: true, NoteLinkChannel: true, NoteLinkURL: true}

// noteURLRe is rdb 0225's note_links_url_http CHECK.
var noteURLRe = regexp.MustCompile(`^https?://`)

// NoteItem is one checklist line. ID "" = a new line (an id is minted).
type NoteItem struct {
	ID       string
	Text     string
	Done     bool
	Position float64
}

// NoteLink is one typed ref. WorkspaceID "" only for url; Day (YYYY-MM-DD)
// only for event.
type NoteLink struct {
	ID          string
	Kind        string
	WorkspaceID string
	Ref         string
	Day         string
	Label       string
	Position    float64
	CreatedAt   time.Time
}

// Note is one personal.notes row with its checklist and links, each in its
// position order. ArchivedAt nil = not archived. AddedByAgent, AskMsgID and
// AskWorkspaceID are the provenance of a note an agent added on the person's
// ask (rdb 0288, spec 155 2.11): all "" on a note the person made.
type Note struct {
	ID             string
	Title          string
	Body           string
	Pinned         bool
	Priority       int
	Position       float64
	ArchivedAt     *time.Time
	CreatedAt      time.Time
	UpdatedAt      time.Time
	Items          []NoteItem
	Links          []NoteLink
	AddedByAgent   string
	AskMsgID       string
	AskWorkspaceID string
}

// NoteOnAsk is a note an agent adds on a person's ask (spec 155 2.11, build
// row B11): every field the WUI sets on a note (OQ-2), and the provenance.
// Priority nil = NotePriorityDefault; Archived true archives it at once.
// A link of a workspace kind with WorkspaceID "" takes AskWorkspaceID, and
// one naming any other workspace is refused: the agent is authenticated to
// the ask's workspace only.
type NoteOnAsk struct {
	Title          string
	Body           string
	Pinned         bool
	Priority       *int
	Archived       bool
	Items          []NoteItem
	Links          []NoteLink
	Agent          string // the acting agent, <agent>@<box>
	AskMsgID       string // the person's message that asked, a lowercase uuid
	AskWorkspaceID string // the workspace of that message
}

// NoteAdded is all an agent learns of the note it added (2.11): never its
// position, the person's note count or any other note.
type NoteAdded struct {
	ID        string
	CreatedAt time.Time
}

// NoteSummary is one row of the list (spec 5): the body cut to
// NoteSnippetChars, and counts in place of the items and links.
type NoteSummary struct {
	ID         string
	Title      string
	Snippet    string
	Pinned     bool
	Priority   int
	Position   float64
	ArchivedAt *time.Time
	UpdatedAt  time.Time
	ItemsDone  int
	ItemsTotal int
	LinkCount  int
}

// NoteOnIssue is one note of the person that links an issue (spec 155 2.12):
// the note's id, title and archive time, and its first link to that issue.
type NoteOnIssue struct {
	ID         string
	Title      string
	ArchivedAt *time.Time
	UpdatedAt  time.Time
	Link       NoteLink
}

// NotePatch is a PATCH of a note: nil fields are kept. Archived true keeps
// an earlier archive time; false clears it.
type NotePatch struct {
	Title    *string
	Body     *string
	Pinned   *bool
	Archived *bool
	Position *float64
	Priority *int
}

// NoteLinkPatch is a PATCH of a link: nil fields are kept.
type NoteLinkPatch struct {
	Label    *string
	Position *float64
}

// Notes is implemented by Memory and Postgres. person is the session's own
// HUM-*; anything else is ErrNoPerson before any SQL. ErrNotFound: no such
// note (or link) of this person. ws is the person's current workspaces (D4).
type Notes interface {
	// ListNotes is every note of the person, archived ones too: pinned
	// first, then by priority (1 first), then by position, the last changed
	// (updated_at) first on a tie, as the WUI draws it (note-order.mjs).
	ListNotes(ctx context.Context, person string) ([]NoteSummary, error)
	// CreateNote adds n (title, body, pinned, items, links) on top of the
	// person's order, at the default priority. ErrNotesFull at NotesPerPerson; ErrNotFound: no such
	// human.
	CreateNote(ctx context.Context, person string, n Note, now time.Time) (Note, error)
	// NoteOf is one note with its items and links.
	NoteOf(ctx context.Context, person, noteID string) (Note, error)
	// PatchNote changes the fields p sets.
	PatchNote(ctx context.Context, person, noteID string, p NotePatch, ws []string, now time.Time) (Note, error)
	// DeleteNote removes the note; its items and links cascade.
	DeleteNote(ctx context.Context, person, noteID string) error
	// PutNoteItems replaces the checklist; the lines keep the order given.
	PutNoteItems(ctx context.Context, person, noteID string, items []NoteItem, ws []string, now time.Time) (Note, error)
	// AddNoteLink adds l after the note's other links.
	AddNoteLink(ctx context.Context, person, noteID string, l NoteLink, ws []string, now time.Time) (NoteLink, error)
	// PatchNoteLink changes a link's label or position.
	PatchNoteLink(ctx context.Context, person, noteID, linkID string, p NoteLinkPatch, ws []string, now time.Time) (NoteLink, error)
	// DeleteNoteLink removes one link.
	DeleteNoteLink(ctx context.Context, person, noteID, linkID string, ws []string, now time.Time) error
	// ExportNotes is every note whole, archived ones too, in list order.
	ExportNotes(ctx context.Context, person string) ([]Note, error)
	// EraseNotes deletes every note of the person; the notes removed.
	EraseNotes(ctx context.Context, person string) (int, error)
	// CreateNoteOnAsk adds one note an agent made on the person's ask, on
	// top of the person's order (spec 155 2.11). person is m.FromID of an
	// ask the hub has verified before this call, never a name the agent
	// gives; the call opens the person scope only. One ask may back several
	// notes (OQ-3). ErrRealmBad outside the limits, ErrNotesFull at
	// NotesPerPerson.
	CreateNoteOnAsk(ctx context.Context, person string, in NoteOnAsk, now time.Time) (NoteAdded, error)
	// NotesOnIssue is the person's notes, archived ones too, that carry an
	// issue link to key in workspace ws, in list order (spec 155 2.12).
	// Only the person's own notes: the store reads no other person's row.
	// ErrRealmBad: ws or key empty or too long.
	NotesOnIssue(ctx context.Context, person, ws, key string) ([]NoteOnIssue, error)
}

var (
	_ Notes = (*Memory)(nil)
	_ Notes = (*Postgres)(nil)
)

// checkNoteText is a text field within max characters; Postgres text holds
// no NUL, so neither does a note.
func checkNoteText(field, s string, max int) error {
	if utf8.RuneCountInString(s) > max {
		return fmt.Errorf("%w: %s above %d characters", ErrRealmBad, field, max)
	}
	if !utf8.ValidString(s) || strings.ContainsRune(s, 0) {
		return fmt.Errorf("%w: %s is not valid text", ErrRealmBad, field)
	}
	return nil
}

func checkNotePosition(p float64) error {
	if math.IsNaN(p) || math.IsInf(p, 0) {
		return fmt.Errorf("%w: position must be a finite number", ErrRealmBad)
	}
	return nil
}

// checkNoteItems checks a whole checklist and clears an item id that is not
// a uuid or that repeats, so a new id is minted for it.
func checkNoteItems(items []NoteItem) ([]NoteItem, error) {
	if len(items) > NoteItemsMax {
		return nil, fmt.Errorf("%w: more than %d checklist lines", ErrRealmBad, NoteItemsMax)
	}
	out := make([]NoteItem, len(items))
	seen := map[string]bool{}
	for i, it := range items {
		if err := checkNoteText("checklist line", it.Text, NoteItemTextMax); err != nil {
			return nil, err
		}
		it.ID = strings.ToLower(it.ID)
		if !isUUID(it.ID) || seen[it.ID] {
			it.ID = ""
		}
		seen[it.ID] = it.ID != ""
		it.Position = float64(i)
		out[i] = it
	}
	return out, nil
}

// checkNoteLink checks l against rdb 0225's note_links CHECKs.
func checkNoteLink(l NoteLink) error {
	if !noteLinkKinds[l.Kind] {
		return fmt.Errorf("%w: unknown link kind", ErrRealmBad)
	}
	if l.Ref == "" {
		return fmt.Errorf("%w: a link needs its ref", ErrRealmBad)
	}
	if err := checkNoteText("ref", l.Ref, NoteRefMax); err != nil {
		return err
	}
	if err := checkNoteText("label", l.Label, NoteLabelMax); err != nil {
		return err
	}
	if err := checkNotePosition(l.Position); err != nil {
		return err
	}
	if l.Kind == NoteLinkURL {
		if l.WorkspaceID != "" || !noteURLRe.MatchString(l.Ref) {
			return fmt.Errorf("%w: a url link is an http(s) address with no workspace", ErrRealmBad)
		}
	} else if err := checkRealmWorkspace(l.WorkspaceID); err != nil {
		return err
	}
	if (l.Kind == NoteLinkEvent) != (l.Day != "") {
		return fmt.Errorf("%w: a day goes with an event link only", ErrRealmBad)
	}
	if l.Day != "" {
		return checkRealmDay(l.Day)
	}
	return nil
}

// checkNewNote checks a note to create; the links take positions 1..n.
func checkNewNote(n Note) (Note, error) {
	if err := checkNoteText("title", n.Title, NoteTitleMax); err != nil {
		return n, err
	}
	if err := checkNoteText("body", n.Body, NoteBodyMax); err != nil {
		return n, err
	}
	items, err := checkNoteItems(n.Items)
	if err != nil {
		return n, err
	}
	if len(n.Links) > NoteLinksMax {
		return n, fmt.Errorf("%w: more than %d links", ErrRealmBad, NoteLinksMax)
	}
	links := make([]NoteLink, len(n.Links))
	for i, l := range n.Links {
		l.Position = float64(i + 1)
		if err := checkNoteLink(l); err != nil {
			return n, err
		}
		links[i] = l
	}
	n.Items, n.Links = items, links
	return n, nil
}

// noteAgentRe is an agent on a box, <agent>@<box>, at most noteAgentMax
// characters (rdb 0288 notes_added_by_agent_len).
var noteAgentRe = regexp.MustCompile(`^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$`)

const noteAgentMax = 64

func checkNotePriority(p int) error {
	if p < NotePriorityHighest || p > NotePriorityDefault {
		return fmt.Errorf("%w: priority must be %d to %d", ErrRealmBad, NotePriorityHighest, NotePriorityDefault)
	}
	return nil
}

// checkNoteOnAsk checks in as checkNewNote does, plus its priority, its
// provenance and its links' workspace; the note to insert, at its priority.
func checkNoteOnAsk(in NoteOnAsk) (Note, error) {
	if len(in.Agent) > noteAgentMax || !noteAgentRe.MatchString(in.Agent) {
		return Note{}, fmt.Errorf("%w: the agent is <agent>@<box>, at most %d characters", ErrRealmBad, noteAgentMax)
	}
	if !isUUID(in.AskMsgID) || in.AskMsgID != strings.ToLower(in.AskMsgID) {
		return Note{}, fmt.Errorf("%w: the ask is a lowercase message uuid", ErrRealmBad)
	}
	if err := checkRealmWorkspace(in.AskWorkspaceID); err != nil {
		return Note{}, err
	}
	prio := NotePriorityDefault
	if in.Priority != nil {
		prio = *in.Priority
	}
	if err := checkNotePriority(prio); err != nil {
		return Note{}, err
	}
	links := append([]NoteLink(nil), in.Links...)
	for i := range links {
		if links[i].Kind == NoteLinkURL {
			continue
		}
		if links[i].WorkspaceID == "" {
			links[i].WorkspaceID = in.AskWorkspaceID
		}
		if links[i].WorkspaceID != in.AskWorkspaceID {
			return Note{}, fmt.Errorf("%w: a link into another workspace than the ask's", ErrRealmBad)
		}
	}
	n, err := checkNewNote(Note{Title: in.Title, Body: in.Body, Pinned: in.Pinned,
		Items: append([]NoteItem(nil), in.Items...), Links: links})
	n.Priority, n.AddedByAgent, n.AskMsgID, n.AskWorkspaceID = prio, in.Agent, in.AskMsgID, in.AskWorkspaceID
	return n, err
}

// checkNotePatch checks the fields p sets.
func checkNotePatch(p NotePatch) error {
	if p.Title != nil {
		if err := checkNoteText("title", *p.Title, NoteTitleMax); err != nil {
			return err
		}
	}
	if p.Body != nil {
		if err := checkNoteText("body", *p.Body, NoteBodyMax); err != nil {
			return err
		}
	}
	if p.Priority != nil {
		if err := checkNotePriority(*p.Priority); err != nil {
			return err
		}
	}
	if p.Position != nil {
		return checkNotePosition(*p.Position)
	}
	return nil
}

func checkNoteLinkPatch(p NoteLinkPatch) error {
	if p.Label != nil {
		if err := checkNoteText("label", *p.Label, NoteLabelMax); err != nil {
			return err
		}
	}
	if p.Position != nil {
		return checkNotePosition(*p.Position)
	}
	return nil
}

// checkNoteIDs is checkPerson plus every id a uuid: a malformed id is a
// note nobody holds.
func checkNoteIDs(person string, ids ...string) error {
	if err := checkPerson(person); err != nil {
		return err
	}
	for _, id := range ids {
		if !isUUID(id) {
			return ErrNotFound
		}
	}
	return nil
}

// checkNoteIssue is checkPerson plus an issue link's workspace and key.
func checkNoteIssue(person, ws, key string) error {
	if err := checkPerson(person); err != nil {
		return err
	}
	if err := checkRealmWorkspace(ws); err != nil {
		return err
	}
	if key == "" {
		return fmt.Errorf("%w: an issue key is needed", ErrRealmBad)
	}
	return checkNoteText("ref", key, NoteRefMax)
}

// noteSnippet is the first NoteSnippetChars characters of body.
func noteSnippet(body string) string {
	n := 0
	for i := range body {
		if n == NoteSnippetChars {
			return body[:i]
		}
		n++
	}
	return body
}

// noteWorkspaces is ws as a non-nil array: pgx sends a nil slice as NULL,
// and "<> ALL(NULL)" would keep every label.
func noteWorkspaces(ws []string) []string {
	if ws == nil {
		return []string{}
	}
	return ws
}

// ---- Postgres ----

const noteCols = `note_id::text, title, body, pinned, priority, position, archived_at, created_at, updated_at,
	COALESCE(added_by_agent, ''), COALESCE(ask_msg_id::text, ''), COALESCE(ask_workspace_id, '')`

const noteLinkCols = `link_id::text, kind, COALESCE(workspace_id, ''), ref, COALESCE(day::text, ''), label, position, created_at`

func scanNote(r pgx.Row) (Note, error) {
	var n Note
	err := r.Scan(&n.ID, &n.Title, &n.Body, &n.Pinned, &n.Priority, &n.Position, &n.ArchivedAt, &n.CreatedAt, &n.UpdatedAt,
		&n.AddedByAgent, &n.AskMsgID, &n.AskWorkspaceID)
	return n, err
}

func scanNoteLink(r pgx.Row) (NoteLink, error) {
	var l NoteLink
	err := r.Scan(&l.ID, &l.Kind, &l.WorkspaceID, &l.Ref, &l.Day, &l.Label, &l.Position, &l.CreatedAt)
	return l, err
}

// notePGErr is realmPGErr, plus a missing row as ErrNotFound.
func notePGErr(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	return realmPGErr(err)
}

// lockNotes serialises the person's note writes for the caps (spec 4: the
// store checks them in the insert's transaction, not a trigger).
func lockNotes(ctx context.Context, tx pgx.Tx, person string) error {
	_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('personal.notes:' || $1, 0))`, person)
	return err
}

// touchNote stamps the note's updated_at; ErrNotFound when the person holds
// no such note.
func touchNote(ctx context.Context, tx pgx.Tx, person, noteID string, now time.Time) error {
	tag, err := tx.Exec(ctx, `UPDATE personal.notes SET updated_at = $3 WHERE person_id = $1 AND note_id = $2::uuid`,
		person, noteID, now.UTC())
	if err == nil && tag.RowsAffected() == 0 {
		err = ErrNotFound
	}
	return err
}

// clearLeftLabels is D4: the labels of the note's links into a workspace not
// in ws are erased.
func clearLeftLabels(ctx context.Context, tx pgx.Tx, person, noteID string, ws []string) error {
	_, err := tx.Exec(ctx, `UPDATE personal.note_links SET label = ''
		WHERE person_id = $1 AND note_id = $2::uuid AND workspace_id IS NOT NULL AND label <> ''
		  AND workspace_id <> ALL($3::text[])`, person, noteID, noteWorkspaces(ws))
	return err
}

func insertNoteItems(ctx context.Context, tx pgx.Tx, person, noteID string, items []NoteItem) error {
	if len(items) == 0 {
		return nil
	}
	ids, texts, done := make([]string, len(items)), make([]string, len(items)), make([]bool, len(items))
	for i, it := range items {
		ids[i], texts[i], done[i] = it.ID, it.Text, it.Done
	}
	_, err := tx.Exec(ctx, `
		INSERT INTO personal.note_items (person_id, note_id, item_id, text, done, position)
		SELECT $1, $2::uuid, COALESCE(NULLIF(u.id, '')::uuid, gen_random_uuid()), u.text, u.done, u.ord - 1
		FROM unnest($3::text[], $4::text[], $5::boolean[]) WITH ORDINALITY AS u(id, text, done, ord)`,
		person, noteID, ids, texts, done)
	return err
}

func insertNoteLinks(ctx context.Context, tx pgx.Tx, person, noteID string, links []NoteLink, now time.Time) error {
	if len(links) == 0 {
		return nil
	}
	cols := make([][]string, 5)
	pos := make([]float64, len(links))
	for i, l := range links {
		for c, v := range []string{l.Kind, l.WorkspaceID, l.Ref, l.Day, l.Label} {
			cols[c] = append(cols[c], v)
		}
		pos[i] = l.Position
	}
	_, err := tx.Exec(ctx, `
		INSERT INTO personal.note_links (person_id, note_id, kind, workspace_id, ref, day, label, position, created_at)
		SELECT $1, $2::uuid, u.kind, NULLIF(u.ws, ''), u.ref, NULLIF(u.day, '')::date, u.label, u.pos, $9
		FROM unnest($3::text[], $4::text[], $5::text[], $6::text[], $7::text[], $8::float8[])
		     AS u(kind, ws, ref, day, label, pos)`,
		person, noteID, cols[0], cols[1], cols[2], cols[3], cols[4], pos, now.UTC())
	return err
}

// noteTx reads one whole note inside the caller's transaction.
func noteTx(ctx context.Context, tx pgx.Tx, person, noteID string) (Note, error) {
	n, err := scanNote(tx.QueryRow(ctx, `SELECT `+noteCols+` FROM personal.notes
		WHERE person_id = $1 AND note_id = $2::uuid`, person, noteID))
	if err != nil {
		return n, notePGErr(err)
	}
	notes, err := notesWhole(ctx, tx, person, []Note{n}, `AND note_id = $2::uuid`, noteID)
	if err != nil {
		return n, err
	}
	return notes[0], nil
}

// notesWhole fills the items and links of notes, read with the extra filter
// and its argument (none: every note of the person).
func notesWhole(ctx context.Context, tx pgx.Tx, person string, notes []Note, filter string, args ...any) ([]Note, error) {
	at := make(map[string]int, len(notes))
	for i := range notes {
		at[notes[i].ID] = i
	}
	args = append([]any{person}, args...)
	err := eachRow(ctx, tx, `SELECT note_id::text, item_id::text, text, done, position FROM personal.note_items
		WHERE person_id = $1 `+filter+` ORDER BY note_id, position`, args, func(r pgx.Rows) error {
		var id string
		var it NoteItem
		err := r.Scan(&id, &it.ID, &it.Text, &it.Done, &it.Position)
		if i, ok := at[id]; ok {
			notes[i].Items = append(notes[i].Items, it)
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	err = eachRow(ctx, tx, `SELECT note_id::text, `+noteLinkCols+` FROM personal.note_links
		WHERE person_id = $1 `+filter+` ORDER BY note_id, position, created_at`, args, func(r pgx.Rows) error {
		var id string
		var l NoteLink
		err := r.Scan(&id, &l.ID, &l.Kind, &l.WorkspaceID, &l.Ref, &l.Day, &l.Label, &l.Position, &l.CreatedAt)
		if i, ok := at[id]; ok {
			notes[i].Links = append(notes[i].Links, l)
		}
		return err
	})
	return notes, err
}

// ListNotes is Notes.ListNotes.
func (s *Postgres) ListNotes(ctx context.Context, person string) ([]NoteSummary, error) {
	var out []NoteSummary
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `
			SELECT n.note_id::text, n.title, left(n.body, $2), n.pinned, n.priority, n.position, n.archived_at, n.updated_at,
			       (SELECT count(*) FILTER (WHERE i.done) FROM personal.note_items i
			         WHERE i.person_id = n.person_id AND i.note_id = n.note_id),
			       (SELECT count(*) FROM personal.note_items i WHERE i.person_id = n.person_id AND i.note_id = n.note_id),
			       (SELECT count(*) FROM personal.note_links l WHERE l.person_id = n.person_id AND l.note_id = n.note_id)
			FROM personal.notes n WHERE n.person_id = $1
			ORDER BY n.pinned DESC, n.priority, n.position, n.updated_at DESC`, []any{person, NoteSnippetChars}, func(r pgx.Rows) error {
			var m NoteSummary
			err := r.Scan(&m.ID, &m.Title, &m.Snippet, &m.Pinned, &m.Priority, &m.Position, &m.ArchivedAt, &m.UpdatedAt,
				&m.ItemsDone, &m.ItemsTotal, &m.LinkCount)
			out = append(out, m)
			return err
		})
	})
	return out, err
}

// NotesOnIssue is Notes.NotesOnIssue: the person scope, and person_id in
// every WHERE, so no other person's note is read.
func (s *Postgres) NotesOnIssue(ctx context.Context, person, ws, key string) ([]NoteOnIssue, error) {
	if err := checkNoteIssue(person, ws, key); err != nil {
		return nil, err
	}
	var out []NoteOnIssue
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `
			SELECT n.note_id::text, n.title, n.archived_at, n.updated_at,
			       l.link_id, l.kind, l.ws, l.ref, l.day, l.label, l.position, l.created_at
			FROM personal.notes n
			JOIN LATERAL (
				SELECT link_id::text AS link_id, kind, COALESCE(workspace_id, '') AS ws, ref,
				       COALESCE(day::text, '') AS day, label, position, created_at
				FROM personal.note_links k
				WHERE k.person_id = n.person_id AND k.note_id = n.note_id
				  AND k.kind = $2 AND k.workspace_id = $3 AND k.ref = $4
				ORDER BY k.position, k.created_at LIMIT 1) l ON true
			WHERE n.person_id = $1
			ORDER BY n.pinned DESC, n.priority, n.position, n.updated_at DESC`,
			[]any{person, NoteLinkIssue, ws, key}, func(r pgx.Rows) error {
				var m NoteOnIssue
				l := &m.Link
				err := r.Scan(&m.ID, &m.Title, &m.ArchivedAt, &m.UpdatedAt,
					&l.ID, &l.Kind, &l.WorkspaceID, &l.Ref, &l.Day, &l.Label, &l.Position, &l.CreatedAt)
				out = append(out, m)
				return err
			})
	})
	return out, err
}

// CreateNote is Notes.CreateNote.
func (s *Postgres) CreateNote(ctx context.Context, person string, n Note, now time.Time) (Note, error) {
	if err := checkPerson(person); err != nil {
		return Note{}, err
	}
	n, err := checkNewNote(n)
	if err != nil {
		return Note{}, err
	}
	var out Note
	err = s.inPerson(ctx, person, func(tx pgx.Tx) error {
		top, err := noteTop(ctx, tx, person)
		if err != nil {
			return err
		}
		var id string
		if err := tx.QueryRow(ctx, `
			INSERT INTO personal.notes (person_id, title, body, pinned, position, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $6) RETURNING note_id::text`,
			person, n.Title, n.Body, n.Pinned, top, now.UTC()).Scan(&id); err != nil {
			return err
		}
		if err := insertNoteParts(ctx, tx, person, id, n, now); err != nil {
			return err
		}
		out, err = noteTx(ctx, tx, person, id)
		return err
	})
	return out, notePGErr(err)
}

// noteTop takes the person's note lock, refuses the note past the cap and
// is the position on top of the person's order (spec 4: the store checks
// the cap in the insert's transaction, not a trigger).
func noteTop(ctx context.Context, tx pgx.Tx, person string) (float64, error) {
	if err := lockNotes(ctx, tx, person); err != nil {
		return 0, err
	}
	var held int
	var top float64
	if err := tx.QueryRow(ctx, `SELECT count(*), COALESCE(min(position), 1) - 1 FROM personal.notes
		WHERE person_id = $1`, person).Scan(&held, &top); err != nil {
		return 0, err
	}
	if held >= NotesPerPerson {
		return 0, ErrNotesFull
	}
	return top, nil
}

// insertNoteParts writes n's checklist and links under the new note id.
func insertNoteParts(ctx context.Context, tx pgx.Tx, person, id string, n Note, now time.Time) error {
	if err := insertNoteItems(ctx, tx, person, id, n.Items); err != nil {
		return err
	}
	return insertNoteLinks(ctx, tx, person, id, n.Links, now)
}

// CreateNoteOnAsk is Notes.CreateNoteOnAsk. It runs in inPerson alone: the
// hub's workspace checks of the ask have closed before it (spec 155 2.11,
// realmTenantCallers stays empty).
func (s *Postgres) CreateNoteOnAsk(ctx context.Context, person string, in NoteOnAsk, now time.Time) (NoteAdded, error) {
	if err := checkPerson(person); err != nil {
		return NoteAdded{}, err
	}
	n, err := checkNoteOnAsk(in)
	if err != nil {
		return NoteAdded{}, err
	}
	var out NoteAdded
	err = s.inPerson(ctx, person, func(tx pgx.Tx) error {
		top, err := noteTop(ctx, tx, person)
		if err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO personal.notes (person_id, title, body, pinned, priority, position, archived_at,
			       added_by_agent, ask_msg_id, ask_workspace_id, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, CASE WHEN $7::boolean THEN $11::timestamptz END,
			       $8, $9::uuid, $10, $11, $11) RETURNING note_id::text, created_at`,
			person, n.Title, n.Body, n.Pinned, n.Priority, top, in.Archived,
			n.AddedByAgent, n.AskMsgID, n.AskWorkspaceID, now.UTC()).Scan(&out.ID, &out.CreatedAt); err != nil {
			return err
		}
		return insertNoteParts(ctx, tx, person, out.ID, n, now)
	})
	if err != nil {
		return NoteAdded{}, notePGErr(err)
	}
	return out, nil
}

// NoteOf is Notes.NoteOf.
func (s *Postgres) NoteOf(ctx context.Context, person, noteID string) (Note, error) {
	if err := checkNoteIDs(person, noteID); err != nil {
		return Note{}, err
	}
	var out Note
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		var err error
		out, err = noteTx(ctx, tx, person, noteID)
		return err
	})
	return out, err
}

// PatchNote is Notes.PatchNote.
func (s *Postgres) PatchNote(ctx context.Context, person, noteID string, p NotePatch, ws []string, now time.Time) (Note, error) {
	if err := checkNoteIDs(person, noteID); err != nil {
		return Note{}, err
	}
	if err := checkNotePatch(p); err != nil {
		return Note{}, err
	}
	var out Note
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE personal.notes SET title = COALESCE($3, title), body = COALESCE($4, body),
			       pinned = COALESCE($5, pinned), position = COALESCE($6, position),
			       priority = COALESCE($9::smallint, priority),
			       archived_at = CASE WHEN $7::boolean IS NULL THEN archived_at
			                          WHEN $7::boolean THEN COALESCE(archived_at, $8) END,
			       updated_at = $8
			WHERE person_id = $1 AND note_id = $2::uuid`,
			person, noteID, p.Title, p.Body, p.Pinned, p.Position, p.Archived, now.UTC(), p.Priority)
		if err == nil && tag.RowsAffected() == 0 {
			err = ErrNotFound
		}
		if err != nil {
			return err
		}
		if err := clearLeftLabels(ctx, tx, person, noteID, ws); err != nil {
			return err
		}
		out, err = noteTx(ctx, tx, person, noteID)
		return err
	})
	return out, notePGErr(err)
}

// DeleteNote is Notes.DeleteNote.
func (s *Postgres) DeleteNote(ctx context.Context, person, noteID string) error {
	if err := checkNoteIDs(person, noteID); err != nil {
		return err
	}
	return s.inPerson(ctx, person, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM personal.notes WHERE person_id = $1 AND note_id = $2::uuid`, person, noteID)
		if err == nil && tag.RowsAffected() == 0 {
			err = ErrNotFound
		}
		return err
	})
}

// PutNoteItems is Notes.PutNoteItems.
func (s *Postgres) PutNoteItems(ctx context.Context, person, noteID string, items []NoteItem, ws []string, now time.Time) (Note, error) {
	if err := checkNoteIDs(person, noteID); err != nil {
		return Note{}, err
	}
	items, err := checkNoteItems(items)
	if err != nil {
		return Note{}, err
	}
	var out Note
	err = s.inPerson(ctx, person, func(tx pgx.Tx) error {
		if err := touchNote(ctx, tx, person, noteID, now); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM personal.note_items WHERE person_id = $1 AND note_id = $2::uuid`,
			person, noteID); err != nil {
			return err
		}
		if err := insertNoteItems(ctx, tx, person, noteID, items); err != nil {
			return err
		}
		if err := clearLeftLabels(ctx, tx, person, noteID, ws); err != nil {
			return err
		}
		out, err = noteTx(ctx, tx, person, noteID)
		return err
	})
	return out, notePGErr(err)
}

// AddNoteLink is Notes.AddNoteLink.
func (s *Postgres) AddNoteLink(ctx context.Context, person, noteID string, l NoteLink, ws []string, now time.Time) (NoteLink, error) {
	if err := checkNoteIDs(person, noteID); err != nil {
		return NoteLink{}, err
	}
	l.Position = 0
	if err := checkNoteLink(l); err != nil {
		return NoteLink{}, err
	}
	var out NoteLink
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		if err := lockNotes(ctx, tx, person); err != nil {
			return err
		}
		if err := touchNote(ctx, tx, person, noteID, now); err != nil {
			return err
		}
		var held int
		if err := tx.QueryRow(ctx, `SELECT count(*), COALESCE(max(position), 0) + 1 FROM personal.note_links
			WHERE person_id = $1 AND note_id = $2::uuid`, person, noteID).Scan(&held, &l.Position); err != nil {
			return err
		}
		if held >= NoteLinksMax {
			return fmt.Errorf("%w: more than %d links", ErrRealmBad, NoteLinksMax)
		}
		if err := tx.QueryRow(ctx, `
			INSERT INTO personal.note_links (person_id, note_id, kind, workspace_id, ref, day, label, position, created_at)
			VALUES ($1, $2::uuid, $3, NULLIF($4, ''), $5, NULLIF($6, '')::date, $7, $8, $9) RETURNING link_id::text`,
			person, noteID, l.Kind, l.WorkspaceID, l.Ref, l.Day, l.Label, l.Position, now.UTC()).Scan(&l.ID); err != nil {
			return err
		}
		var err error
		out, err = linkAfterWrite(ctx, tx, person, noteID, l.ID, ws)
		return err
	})
	return out, notePGErr(err)
}

// linkAfterWrite is D4 on the note, then the link as stored.
func linkAfterWrite(ctx context.Context, tx pgx.Tx, person, noteID, linkID string, ws []string) (NoteLink, error) {
	if err := clearLeftLabels(ctx, tx, person, noteID, ws); err != nil {
		return NoteLink{}, err
	}
	return scanNoteLink(tx.QueryRow(ctx, `SELECT `+noteLinkCols+` FROM personal.note_links
		WHERE person_id = $1 AND note_id = $2::uuid AND link_id = $3::uuid`, person, noteID, linkID))
}

// PatchNoteLink is Notes.PatchNoteLink.
func (s *Postgres) PatchNoteLink(ctx context.Context, person, noteID, linkID string, p NoteLinkPatch, ws []string, now time.Time) (NoteLink, error) {
	if err := checkNoteIDs(person, noteID, linkID); err != nil {
		return NoteLink{}, err
	}
	if err := checkNoteLinkPatch(p); err != nil {
		return NoteLink{}, err
	}
	var out NoteLink
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		if err := touchNote(ctx, tx, person, noteID, now); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `UPDATE personal.note_links SET label = COALESCE($4, label), position = COALESCE($5, position)
			WHERE person_id = $1 AND note_id = $2::uuid AND link_id = $3::uuid`, person, noteID, linkID, p.Label, p.Position)
		if err == nil && tag.RowsAffected() == 0 {
			err = ErrNotFound
		}
		if err != nil {
			return err
		}
		out, err = linkAfterWrite(ctx, tx, person, noteID, linkID, ws)
		return err
	})
	return out, notePGErr(err)
}

// DeleteNoteLink is Notes.DeleteNoteLink.
func (s *Postgres) DeleteNoteLink(ctx context.Context, person, noteID, linkID string, ws []string, now time.Time) error {
	if err := checkNoteIDs(person, noteID, linkID); err != nil {
		return err
	}
	return s.inPerson(ctx, person, func(tx pgx.Tx) error {
		if err := touchNote(ctx, tx, person, noteID, now); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `DELETE FROM personal.note_links WHERE person_id = $1 AND note_id = $2::uuid AND link_id = $3::uuid`,
			person, noteID, linkID)
		if err == nil && tag.RowsAffected() == 0 {
			err = ErrNotFound
		}
		if err != nil {
			return err
		}
		return clearLeftLabels(ctx, tx, person, noteID, ws)
	})
}

// ExportNotes is Notes.ExportNotes.
func (s *Postgres) ExportNotes(ctx context.Context, person string) ([]Note, error) {
	var out []Note
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		out = nil
		err := eachRow(ctx, tx, `SELECT `+noteCols+` FROM personal.notes WHERE person_id = $1
			ORDER BY pinned DESC, priority, position, updated_at DESC`, []any{person}, func(r pgx.Rows) error {
			n, err := scanNote(r)
			out = append(out, n)
			return err
		})
		if err != nil {
			return err
		}
		out, err = notesWhole(ctx, tx, person, out, "")
		return err
	})
	return out, err
}

// EraseNotes is Notes.EraseNotes.
func (s *Postgres) EraseNotes(ctx context.Context, person string) (int, error) {
	var n int
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM personal.notes WHERE person_id = $1`, person)
		n = int(tag.RowsAffected())
		return err
	})
	return n, err
}
