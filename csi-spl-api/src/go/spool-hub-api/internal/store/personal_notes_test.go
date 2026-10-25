package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/155 B3 (sections 2.4, 4, 5; cases C7, C8): the notes store. Each
// case runs on Memory and, under hub-pg.tst.sh or hub-live-stack.sh with
// SPOOL_TEST_PG_RUNTIME_DSN, on Postgres as the runtime login (no
// superuser, no BYPASSRLS; the driver logs the role). C9 is
// TestPersonScopeCallers (personal_scope_test.go).

// notesFix is one driver: the store, how to seed a human, and how to plant
// n bare notes for a person without the store (C8).
type notesFix struct {
	st       Notes
	addHuman func(t *testing.T, person string)
	plant    func(t *testing.T, person string, n int)
}

func memNotesFix(*testing.T) notesFix {
	rf := memRealmFix()
	m := rf.st.(*Memory)
	return notesFix{st: m, addHuman: rf.addHuman, plant: func(t *testing.T, person string, n int) {
		for i := 0; i < n; i++ {
			if _, err := m.CreateNote(context.Background(), person, Note{}, time.Now()); err != nil {
				t.Fatal(err)
			}
		}
	}}
}

func pgNotesFix(t *testing.T) notesFix {
	rf, pg, rt := pgRealmFix(t)
	ctx := context.Background()
	var role string
	var super, bypass bool
	if err := rt.pool.QueryRow(ctx, `SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user`).
		Scan(&role, &super, &bypass); err != nil {
		t.Fatal(err)
	}
	t.Logf("postgres runtime role %s: rolsuper %v rolbypassrls %v", role, super, bypass)
	if super || bypass {
		t.Fatalf("the runtime role %s bypasses RLS: it would prove nothing", role)
	}
	return notesFix{st: rt, addHuman: rf.addHuman, plant: func(t *testing.T, person string, n int) {
		err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SELECT set_config('app.person_id', $1, true)`, person); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO personal.notes (person_id, position)
				SELECT $1, g FROM generate_series(1, $2) g`, person, n)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
	}}
}

func eachNotesDriver(t *testing.T, run func(t *testing.T, f notesFix)) {
	for name, mk := range map[string]func(*testing.T) notesFix{"memory": memNotesFix, "postgres": pgNotesFix} {
		t.Run(name, func(t *testing.T) { run(t, mk(t)) })
	}
}

// notesPair is two seeded persons, P1 holding one note with a checklist
// line and a link into ws-1.
func notesPair(t *testing.T, f notesFix, now time.Time) (p1, p2 string, n Note) {
	t.Helper()
	p1, p2 = realmPersons()
	f.addHuman(t, p1)
	f.addHuman(t, p2)
	n, err := f.st.CreateNote(context.Background(), p1, Note{Title: "Plan", Body: "the body",
		Items: []NoteItem{{Text: "buy milk"}},
		Links: []NoteLink{{Kind: NoteLinkTopic, WorkspaceID: "ws-1", Ref: "topic-1", Label: "Plan topic"}}}, now)
	if err != nil {
		t.Fatal(err)
	}
	return p1, p2, n
}

// notesOtherCalls is every call on noteID (and its first link) as person;
// each returns its error.
func notesOtherCalls(st Notes, person string, n Note, now time.Time) map[string]error {
	ctx := context.Background()
	title, label := "taken", "taken"
	ws := []string{"ws-1"}
	link := n.Links[0].ID
	_, e1 := st.NoteOf(ctx, person, n.ID)
	_, e2 := st.PatchNote(ctx, person, n.ID, NotePatch{Title: &title}, ws, now)
	_, e3 := st.PutNoteItems(ctx, person, n.ID, nil, ws, now)
	_, e4 := st.AddNoteLink(ctx, person, n.ID, NoteLink{Kind: NoteLinkURL, Ref: "https://example.com"}, ws, now)
	_, e5 := st.PatchNoteLink(ctx, person, n.ID, link, NoteLinkPatch{Label: &label}, ws, now)
	return map[string]error{
		"NoteOf": e1, "PatchNote": e2, "PutNoteItems": e3, "AddNoteLink": e4, "PatchNoteLink": e5,
		"DeleteNoteLink": st.DeleteNoteLink(ctx, person, n.ID, link, ws, now),
		"DeleteNote":     st.DeleteNote(ctx, person, n.ID),
	}
}

// sameNote is "" when got holds want's stored fields, else what differs.
func sameNote(got, want Note) string {
	switch {
	case got.Title != want.Title || got.Body != want.Body || got.Pinned != want.Pinned:
		return "title, body or pinned"
	case !got.UpdatedAt.Equal(want.UpdatedAt):
		return "updated_at " + got.UpdatedAt.String() + " want " + want.UpdatedAt.String()
	case len(got.Items) != len(want.Items) || len(got.Links) != len(want.Links):
		return "item or link count"
	case len(got.Links) > 0 && got.Links[0].Label != want.Links[0].Label:
		return "link label " + got.Links[0].Label
	}
	return ""
}

// TestNotesC7OtherPerson: P2 lists, reads, patches, deletes P1's note and
// its parts: not found (never a refusal), and nothing of P1's changes.
// TWIN: P1 makes each call and it succeeds.
func TestNotesC7OtherPerson(t *testing.T) {
	eachNotesDriver(t, func(t *testing.T, f notesFix) {
		ctx := context.Background()
		now := time.Now().UTC().Truncate(time.Second)
		p1, p2, n := notesPair(t, f, now)
		if l, err := f.st.ListNotes(ctx, p2); err != nil || len(l) != 0 {
			t.Errorf("P2 ListNotes: %d rows, %v; want 0", len(l), err)
		}
		if got, err := f.st.EraseNotes(ctx, p2); err != nil || got != 0 {
			t.Errorf("P2 EraseNotes: %d, %v; want 0", got, err)
		}
		for call, err := range notesOtherCalls(f.st, p2, n, now.Add(time.Hour)) {
			if !errors.Is(err, ErrNotFound) {
				t.Errorf("P2 %s on P1's note: %v, want ErrNotFound", call, err)
			}
		}
		after, err := f.st.NoteOf(ctx, p1, n.ID)
		if err != nil {
			t.Fatalf("P1's note after P2's calls: %v", err)
		}
		if d := sameNote(after, n); d != "" {
			t.Errorf("P2's calls changed P1's note: %s", d)
		}
		if l, err := f.st.ListNotes(ctx, p1); err != nil || len(l) != 1 {
			t.Errorf("P1 ListNotes: %d rows, %v; want 1", len(l), err)
		}
		for call, err := range notesOtherCalls(f.st, p1, n, now.Add(time.Hour)) {
			if err != nil {
				t.Errorf("twin: P1 %s on its own note: %v", call, err)
			}
		}
		if _, err := f.st.NoteOf(ctx, p1, n.ID); !errors.Is(err, ErrNotFound) {
			t.Errorf("twin: P1's DeleteNote left the note: %v", err)
		}
	})
}

// TestNotesC8Cap: the 2 001st note of P1 is ErrNotesFull and is not stored.
// TWIN: the 2 000th inserts.
func TestNotesC8Cap(t *testing.T) {
	eachNotesDriver(t, func(t *testing.T, f notesFix) {
		ctx := context.Background()
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		f.plant(t, p1, NotesPerPerson-1)
		if _, err := f.st.CreateNote(ctx, p1, Note{Title: "the 2000th"}, time.Now()); err != nil {
			t.Fatalf("twin: the %dth note: %v", NotesPerPerson, err)
		}
		if _, err := f.st.CreateNote(ctx, p1, Note{Title: "one too many"}, time.Now()); !errors.Is(err, ErrNotesFull) {
			t.Errorf("the %dth note: %v, want ErrNotesFull", NotesPerPerson+1, err)
		}
		l, err := f.st.ListNotes(ctx, p1)
		if err != nil || len(l) != NotesPerPerson {
			t.Fatalf("ListNotes: %d rows, %v; want %d", len(l), err, NotesPerPerson)
		}
		if l[0].Title != "the 2000th" {
			t.Errorf("a new note goes on top: first row %q", l[0].Title)
		}
	})
}

// TestNotesListAndPatch: list order (pinned, then the person's order, a new
// note on top), the snippet and counts, archive and its undo.
func TestNotesListAndPatch(t *testing.T) {
	eachNotesDriver(t, func(t *testing.T, f notesFix) {
		ctx := context.Background()
		now := time.Now().UTC().Truncate(time.Second)
		p1, _, a := notesPair(t, f, now)
		body := strings.Repeat("é", NoteSnippetChars+5)
		b, err := f.st.CreateNote(ctx, p1, Note{Title: "B", Body: body,
			Items: []NoteItem{{Text: "one", Done: true}, {Text: "two"}, {Text: ""}}}, now)
		if err != nil {
			t.Fatal(err)
		}
		pin, yes, no := true, true, false
		if _, err := f.st.PatchNote(ctx, p1, a.ID, NotePatch{Pinned: &pin, Archived: &yes}, []string{"ws-1"}, now); err != nil {
			t.Fatal(err)
		}
		l, err := f.st.ListNotes(ctx, p1)
		if err != nil || len(l) != 2 || l[0].ID != a.ID || l[1].ID != b.ID {
			t.Fatalf("ListNotes: %+v, %v; want the pinned A, then B", l, err)
		}
		if l[0].ArchivedAt == nil || l[0].LinkCount != 1 || l[0].ItemsTotal != 1 {
			t.Errorf("A's row: %+v", l[0])
		}
		if l[1].Snippet != strings.Repeat("é", NoteSnippetChars) || l[1].ItemsDone != 1 || l[1].ItemsTotal != 3 {
			t.Errorf("B's row: snippet %d characters, items %d/%d", len([]rune(l[1].Snippet)), l[1].ItemsDone, l[1].ItemsTotal)
		}
		got, err := f.st.PatchNote(ctx, p1, a.ID, NotePatch{Archived: &no}, []string{"ws-1"}, now)
		if err != nil || got.ArchivedAt != nil || !got.Pinned {
			t.Errorf("unarchive: archived %v pinned %v, %v", got.ArchivedAt, got.Pinned, err)
		}
		if got.Links[0].Label != "Plan topic" {
			t.Errorf("a link into a current workspace lost its label: %q", got.Links[0].Label)
		}
	})
}

// TestNotesItemsAndLinks: the checklist is replaced in order, links append,
// change and go; D4: a write erases the label of a link into a workspace
// the person left, and keeps the one into a current workspace.
func TestNotesItemsAndLinks(t *testing.T) {
	eachNotesDriver(t, func(t *testing.T, f notesFix) {
		ctx := context.Background()
		now := time.Now().UTC().Truncate(time.Second)
		p1, _, n := notesPair(t, f, now)
		keep := n.Items[0]
		keep.Done = true
		got, err := f.st.PutNoteItems(ctx, p1, n.ID, []NoteItem{{Text: "first"}, keep}, []string{"ws-1", "ws-2"}, now)
		if err != nil || len(got.Items) != 2 || got.Items[0].Text != "first" || got.Items[1].ID != keep.ID || !got.Items[1].Done {
			t.Fatalf("PutNoteItems: %+v, %v", got.Items, err)
		}
		w2, err := f.st.AddNoteLink(ctx, p1, n.ID, NoteLink{Kind: NoteLinkEvent, WorkspaceID: "ws-2", Ref: "ev-1",
			Day: "2026-10-25", Label: "Standup"}, []string{"ws-1", "ws-2"}, now)
		if err != nil || w2.Position <= n.Links[0].Position || w2.Day != "2026-10-25" {
			t.Fatalf("AddNoteLink: %+v, %v", w2, err)
		}
		label := "Renamed"
		if l, err := f.st.PatchNoteLink(ctx, p1, n.ID, w2.ID, NoteLinkPatch{Label: &label}, []string{"ws-1", "ws-2"}, now); err != nil || l.Label != label {
			t.Errorf("PatchNoteLink: %+v, %v", l, err)
		}
		title := "after the leave"
		left, err := f.st.PatchNote(ctx, p1, n.ID, NotePatch{Title: &title}, []string{"ws-1"}, now)
		if err != nil || len(left.Links) != 2 {
			t.Fatalf("PatchNote after leaving ws-2: %+v, %v", left.Links, err)
		}
		if left.Links[0].Label != "Plan topic" || left.Links[1].Label != "" || left.Links[1].Ref != "ev-1" {
			t.Errorf("D4: ws-1 label %q (want kept), ws-2 label %q ref %q (want erased, ref kept)",
				left.Links[0].Label, left.Links[1].Label, left.Links[1].Ref)
		}
		if err := f.st.DeleteNoteLink(ctx, p1, n.ID, w2.ID, []string{"ws-1"}, now); err != nil {
			t.Fatal(err)
		}
		if err := f.st.DeleteNoteLink(ctx, p1, n.ID, w2.ID, []string{"ws-1"}, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("a second DeleteNoteLink: %v, want ErrNotFound", err)
		}
	})
}

// TestNotesLimits: each limit of spec 2.4 and CHECK of rdb 0225 is refused
// with ErrRealmBad before the store; TWIN: the value at the limit passes.
func TestNotesLimits(t *testing.T) {
	eachNotesDriver(t, func(t *testing.T, f notesFix) {
		ctx := context.Background()
		now := time.Now()
		p1, _, n := notesPair(t, f, now)
		bad := map[string]Note{
			"201-character title": {Title: strings.Repeat("x", NoteTitleMax+1)},
			"201 checklist lines": {Items: make([]NoteItem, NoteItemsMax+1)},
			"javascript: url":     {Links: []NoteLink{{Kind: NoteLinkURL, Ref: "javascript:x"}}},
			"msg with no space":   {Links: []NoteLink{{Kind: NoteLinkMsg, Ref: "m-1"}}},
			"event with no day":   {Links: []NoteLink{{Kind: NoteLinkEvent, WorkspaceID: "ws-1", Ref: "e"}}},
			"unknown kind":        {Links: []NoteLink{{Kind: "file", WorkspaceID: "ws-1", Ref: "f"}}},
			"NUL in the body":     {Body: "a\x00b"},
		}
		for name, b := range bad {
			if _, err := f.st.CreateNote(ctx, p1, b, now); !errors.Is(err, ErrRealmBad) {
				t.Errorf("%s: %v, want ErrRealmBad", name, err)
			}
		}
		if _, err := f.st.CreateNote(ctx, p1, Note{Title: strings.Repeat("é", NoteTitleMax),
			Links: []NoteLink{{Kind: NoteLinkURL, Ref: "https://example.com"}}}, now); err != nil {
			t.Errorf("twin: a %d-character title and an https link: %v", NoteTitleMax, err)
		}
		for i := len(n.Links); i < NoteLinksMax; i++ {
			if _, err := f.st.AddNoteLink(ctx, p1, n.ID, NoteLink{Kind: NoteLinkURL, Ref: "https://example.com"}, nil, now); err != nil {
				t.Fatalf("twin: link %d: %v", i+1, err)
			}
		}
		if _, err := f.st.AddNoteLink(ctx, p1, n.ID, NoteLink{Kind: NoteLinkURL, Ref: "https://example.com"}, nil, now); !errors.Is(err, ErrRealmBad) {
			t.Errorf("the %dst link: %v, want ErrRealmBad", NoteLinksMax+1, err)
		}
		if _, err := f.st.NoteOf(ctx, p1, "not-a-uuid"); !errors.Is(err, ErrNotFound) {
			t.Errorf("a malformed note id: %v, want ErrNotFound", err)
		}
		ghost, _ := realmPersons()
		if _, err := f.st.CreateNote(ctx, "HUM-9"+ghost[5:], Note{}, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("a note of no such human: %v, want ErrNotFound", err)
		}
	})
}

// TestNotesExportErase: the export holds every note, archived ones too,
// whole; erase leaves 0 and touches no other person.
func TestNotesExportErase(t *testing.T) {
	eachNotesDriver(t, func(t *testing.T, f notesFix) {
		ctx := context.Background()
		now := time.Now()
		p1, p2, n := notesPair(t, f, now)
		yes := true
		if _, err := f.st.PatchNote(ctx, p1, n.ID, NotePatch{Archived: &yes}, nil, now); err != nil {
			t.Fatal(err)
		}
		if _, err := f.st.CreateNote(ctx, p1, Note{Title: "second"}, now); err != nil {
			t.Fatal(err)
		}
		if _, err := f.st.CreateNote(ctx, p2, Note{Title: "P2's"}, now); err != nil {
			t.Fatal(err)
		}
		ex, err := f.st.ExportNotes(ctx, p1)
		if err != nil || len(ex) != 2 {
			t.Fatalf("ExportNotes: %d notes, %v; want 2", len(ex), err)
		}
		var archived *Note
		for i := range ex {
			if ex[i].ID == n.ID {
				archived = &ex[i]
			}
		}
		if archived == nil || archived.ArchivedAt == nil || len(archived.Items) != 1 || len(archived.Links) != 1 {
			t.Errorf("the archived note in the export: %+v", archived)
		}
		if got, err := f.st.EraseNotes(ctx, p1); err != nil || got != 2 {
			t.Errorf("EraseNotes: %d, %v; want 2", got, err)
		}
		if l, _ := f.st.ListNotes(ctx, p1); len(l) != 0 {
			t.Errorf("after the erase P1 holds %d notes", len(l))
		}
		if l, _ := f.st.ListNotes(ctx, p2); len(l) != 1 {
			t.Errorf("P1's erase reached P2: %d notes left", len(l))
		}
	})
}

// TestNotesRefuseBeforeSQL: every notes method refuses "", an agent id and
// an injection with ErrNoPerson before any SQL (the Postgres has no pool:
// a statement would panic), as TestInPersonRefusesBeforeSQL for the realm.
func TestNotesRefuseBeforeSQL(t *testing.T) {
	n := Note{ID: "00000000-0000-4000-8000-000000000155", Links: []NoteLink{{ID: "00000000-0000-4000-8000-000000000156"}}}
	for name, st := range map[string]Notes{"postgres": &Postgres{}, "memory": NewMemory()} {
		for _, p := range refusedPersons {
			calls := notesOtherCalls(st, p, n, time.Now())
			_, calls["ListNotes"] = st.ListNotes(context.Background(), p)
			_, calls["CreateNote"] = st.CreateNote(context.Background(), p, Note{}, time.Now())
			_, calls["ExportNotes"] = st.ExportNotes(context.Background(), p)
			_, calls["EraseNotes"] = st.EraseNotes(context.Background(), p)
			for call, err := range calls {
				if !errors.Is(err, ErrNoPerson) {
					t.Errorf("%s %s(%q): %v, want ErrNoPerson", name, call, p, err)
				}
			}
		}
	}
}
