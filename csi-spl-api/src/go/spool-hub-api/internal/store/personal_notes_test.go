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
	owner    *Postgres // the migrate login (C33's raw rows); nil on Memory
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
	return notesFix{st: rt, addHuman: rf.addHuman, owner: pg, plant: func(t *testing.T, person string, n int) {
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
	case got.Priority != want.Priority:
		return "priority"
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
			_, calls["CreateNoteOnAsk"] = st.CreateNoteOnAsk(context.Background(), p, askOf(), time.Now())
			_, calls["NotesOnIssue"] = st.NotesOnIssue(context.Background(), p, "ws-1", "SPL-1")
			for call, err := range calls {
				if !errors.Is(err, ErrNoPerson) {
					t.Errorf("%s %s(%q): %v, want ErrNoPerson", name, call, p, err)
				}
			}
		}
	}
}

// TestNotesPriority (spec 155 2.9, SPL-4652): a note reads 5 until it is set,
// also one that predates the column (plant writes no priority); a set reads
// back and keeps the other fields; outside 1..5 is refused and changes
// nothing; another person's note is ErrNotFound and stays as it was.
func TestNotesPriority(t *testing.T) {
	eachNotesDriver(t, func(t *testing.T, f notesFix) {
		ctx := context.Background()
		now := time.Now().UTC().Truncate(time.Second)
		p1, p2, n := notesPair(t, f, now)
		if n.Priority != NotePriorityDefault {
			t.Errorf("a new note reads %d, want %d", n.Priority, NotePriorityDefault)
		}
		f.plant(t, p2, 1)
		if l, err := f.st.ListNotes(ctx, p2); err != nil || len(l) != 1 || l[0].Priority != NotePriorityDefault {
			t.Errorf("a planted note: %+v, %v; want priority %d", l, err, NotePriorityDefault)
		}
		one := 1
		got, err := f.st.PatchNote(ctx, p1, n.ID, NotePatch{Priority: &one}, []string{"ws-1"}, now)
		if err != nil || got.Priority != 1 || got.Title != n.Title || got.Body != n.Body {
			t.Fatalf("set 1: priority %d title %q body %q, %v", got.Priority, got.Title, got.Body, err)
		}
		if read, err := f.st.NoteOf(ctx, p1, n.ID); err != nil || read.Priority != 1 {
			t.Errorf("read back: %d, %v; want 1", read.Priority, err)
		}
		for _, bad := range []int{0, 6, -1} {
			if _, err := f.st.PatchNote(ctx, p1, n.ID, NotePatch{Priority: &bad}, nil, now); !errors.Is(err, ErrRealmBad) {
				t.Errorf("priority %d: %v, want ErrRealmBad", bad, err)
			}
		}
		three := 3
		if _, err := f.st.PatchNote(ctx, p2, n.ID, NotePatch{Priority: &three}, nil, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("P2 sets P1's priority: %v, want ErrNotFound", err)
		}
		if read, err := f.st.NoteOf(ctx, p1, n.ID); err != nil || read.Priority != 1 {
			t.Errorf("after the refusals: %d, %v; want 1", read.Priority, err)
		}
		other := "untouched"
		if got, err := f.st.PatchNote(ctx, p1, n.ID, NotePatch{Title: &other}, []string{"ws-1"}, now); err != nil || got.Priority != 1 {
			t.Errorf("a patch without priority: %d, %v; want it kept at 1", got.Priority, err)
		}
	})
}

// TestNotesPriorityOrder: within pinned and within the rest, priority 1 comes
// first, then the person's own position; a pinned 5 still beats an unpinned 1.
func TestNotesPriorityOrder(t *testing.T) {
	eachNotesDriver(t, func(t *testing.T, f notesFix) {
		ctx := context.Background()
		now := time.Now().UTC().Truncate(time.Second)
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		ids := map[string]string{}
		// each new note goes on top, so by position alone the two that get a
		// priority come last in their groups: only the priority lifts them.
		for _, title := range []string{"urgent", "older", "newer", "pinned-2", "pinned-5"} {
			n, err := f.st.CreateNote(ctx, p1, Note{Title: title, Pinned: strings.HasPrefix(title, "pinned")}, now)
			if err != nil {
				t.Fatal(err)
			}
			ids[title] = n.ID
		}
		for title, prio := range map[string]int{"urgent": 1, "pinned-2": 2} {
			if _, err := f.st.PatchNote(ctx, p1, ids[title], NotePatch{Priority: &prio}, nil, now); err != nil {
				t.Fatal(err)
			}
		}
		want := "pinned-2 pinned-5 urgent newer older"
		l, err := f.st.ListNotes(ctx, p1)
		if err != nil {
			t.Fatal(err)
		}
		var got []string
		for _, m := range l {
			got = append(got, m.Title)
		}
		if strings.Join(got, " ") != want {
			t.Errorf("ListNotes order %q, want %q", strings.Join(got, " "), want)
		}
		ex, err := f.st.ExportNotes(ctx, p1)
		if err != nil {
			t.Fatal(err)
		}
		got = got[:0]
		for _, m := range ex {
			got = append(got, m.Title)
		}
		if strings.Join(got, " ") != want {
			t.Errorf("ExportNotes order %q, want %q", strings.Join(got, " "), want)
		}
	})
}

// TestNotesOrderTie (SPL-4701, review note N3): two notes at the same
// position order by updated_at, the last changed first, in ListNotes and
// ExportNotes, as the WUI's compareNotes does. Older is created first and
// changed last: by created_at it would come second. CONTROL: with
// created_at DESC back as the last key, both checks FAIL.
func TestNotesOrderTie(t *testing.T) {
	eachNotesDriver(t, func(t *testing.T, f notesFix) {
		ctx := context.Background()
		now := time.Now().UTC().Truncate(time.Second)
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		older, err := f.st.CreateNote(ctx, p1, Note{Title: "older"}, now)
		if err != nil {
			t.Fatal(err)
		}
		newer, err := f.st.CreateNote(ctx, p1, Note{Title: "newer"}, now.Add(time.Second))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.st.PatchNote(ctx, p1, older.ID, NotePatch{Position: &newer.Position}, nil, now.Add(2*time.Second)); err != nil {
			t.Fatal(err)
		}
		want := "older newer"
		l, err := f.st.ListNotes(ctx, p1)
		if err != nil {
			t.Fatal(err)
		}
		var got []string
		for _, m := range l {
			got = append(got, m.Title)
		}
		if strings.Join(got, " ") != want {
			t.Errorf("ListNotes tie %q, want %q", strings.Join(got, " "), want)
		}
		ex, err := f.st.ExportNotes(ctx, p1)
		if err != nil {
			t.Fatal(err)
		}
		got = got[:0]
		for _, m := range ex {
			got = append(got, m.Title)
		}
		if strings.Join(got, " ") != want {
			t.Errorf("ExportNotes tie %q, want %q", strings.Join(got, " "), want)
		}
	})
}

// ---- spec 155 v1.5 B11 (2.11): an agent adds a note on the person's ask ----

const (
	askMsg = "00000000-0000-4000-8000-0000000155a1"
	askWS  = "ws-1"
	askBy  = "a-1@box-a"
)

// askOf is a valid ask with no field set beyond the provenance.
func askOf() NoteOnAsk {
	return NoteOnAsk{Agent: askBy, AskMsgID: askMsg, AskWorkspaceID: askWS}
}

// askFull sets every field the WUI sets on a note (OQ-2).
func askFull() NoteOnAsk {
	in, two := askOf(), 2
	in.Title, in.Body, in.Pinned, in.Priority, in.Archived = "From the ask", "the agent's body", true, &two, true
	in.Items = []NoteItem{{Text: "first", Done: true}, {Text: "second"}}
	in.Links = []NoteLink{{Kind: NoteLinkTopic, Ref: "topic-1", Label: "the topic"},
		{Kind: NoteLinkURL, Ref: "https://example.com/a", Label: "outside"}}
	return in
}

// TestNotesC34OnAsk (C34): CreateNoteOnAsk stores every WUI field and the
// provenance, on top of the person's order, and answers the id and time
// only; a second note on the same ask is a second note (OQ-3); nil priority
// is 5 and Archived false leaves it unarchived. A note the person makes
// carries no provenance.
func TestNotesC34OnAsk(t *testing.T) {
	eachNotesDriver(t, func(t *testing.T, f notesFix) {
		ctx := context.Background()
		now := time.Now().UTC().Truncate(time.Second)
		p1, p2, human := notesPair(t, f, now)
		if human.AddedByAgent != "" || human.AskMsgID != "" || human.AskWorkspaceID != "" {
			t.Errorf("a note the person made carries provenance: %+v", human)
		}
		got, err := f.st.CreateNoteOnAsk(ctx, p1, askFull(), now)
		if err != nil || got.ID == "" || !got.CreatedAt.Equal(now) {
			t.Fatalf("CreateNoteOnAsk: %+v, %v", got, err)
		}
		n, err := f.st.NoteOf(ctx, p1, got.ID)
		if err != nil {
			t.Fatal(err)
		}
		if n.Title != "From the ask" || n.Body != "the agent's body" || !n.Pinned || n.Priority != 2 ||
			n.ArchivedAt == nil || !n.ArchivedAt.Equal(now) {
			t.Errorf("the fields: %+v", n)
		}
		if n.AddedByAgent != askBy || n.AskMsgID != askMsg || n.AskWorkspaceID != askWS {
			t.Errorf("the provenance: %q %q %q", n.AddedByAgent, n.AskMsgID, n.AskWorkspaceID)
		}
		if len(n.Items) != 2 || n.Items[0].Text != "first" || !n.Items[0].Done || n.Items[1].Text != "second" {
			t.Errorf("the checklist: %+v", n.Items)
		}
		if len(n.Links) != 2 || n.Links[0].WorkspaceID != askWS || n.Links[0].Label != "the topic" ||
			n.Links[1].Kind != NoteLinkURL || n.Links[1].WorkspaceID != "" {
			t.Errorf("the links (a topic link takes the ask's workspace): %+v", n.Links)
		}
		if n.Position != human.Position-1 {
			t.Errorf("position %v, want on top of %v", n.Position, human.Position)
		}
		again, err := f.st.CreateNoteOnAsk(ctx, p1, askOf(), now)
		if err != nil || again.ID == got.ID {
			t.Fatalf("a second note on the same ask: %+v, %v", again, err)
		}
		bare, err := f.st.NoteOf(ctx, p1, again.ID)
		if err != nil || bare.Priority != NotePriorityDefault || bare.ArchivedAt != nil || bare.Pinned || bare.AskMsgID != askMsg {
			t.Errorf("the defaults: %+v, %v", bare, err)
		}
		if l, err := f.st.ListNotes(ctx, p1); err != nil || len(l) != 3 {
			t.Errorf("P1 ListNotes: %d rows, %v; want 3", len(l), err)
		}
		if l, err := f.st.ListNotes(ctx, p2); err != nil || len(l) != 0 {
			t.Errorf("P2 ListNotes: %d rows, %v; want 0", len(l), err)
		}
		ex, err := f.st.ExportNotes(ctx, p1)
		if err != nil || len(ex) != 3 {
			t.Fatalf("ExportNotes: %d, %v", len(ex), err)
		}
		for _, e := range ex {
			if (e.ID == got.ID || e.ID == again.ID) != (e.AddedByAgent == askBy) {
				t.Errorf("export provenance of %s: %q", e.Title, e.AddedByAgent)
			}
		}
	})
}

// TestNotesC34OnAskLimits (C34): each limit is ErrRealmBad and stores
// nothing; TWIN: priority 1 and 5, 200 lines and 100 links insert.
func TestNotesC34OnAskLimits(t *testing.T) {
	eachNotesDriver(t, func(t *testing.T, f notesFix) {
		ctx := context.Background()
		now := time.Now()
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		bad := map[string]func(*NoteOnAsk){
			"priority 0":          func(in *NoteOnAsk) { z := 0; in.Priority = &z },
			"priority 6":          func(in *NoteOnAsk) { six := 6; in.Priority = &six },
			"201 checklist lines": func(in *NoteOnAsk) { in.Items = make([]NoteItem, NoteItemsMax+1) },
			"101 links":           func(in *NoteOnAsk) { in.Links = urlLinks(NoteLinksMax + 1) },
			"201-character title": func(in *NoteOnAsk) { in.Title = strings.Repeat("x", NoteTitleMax+1) },
			"javascript: url":     func(in *NoteOnAsk) { in.Links = []NoteLink{{Kind: NoteLinkURL, Ref: "javascript:x"}} },
			"another workspace":   func(in *NoteOnAsk) { in.Links = []NoteLink{{Kind: NoteLinkTopic, WorkspaceID: "ws-2", Ref: "t"}} },
			"no agent":            func(in *NoteOnAsk) { in.Agent = "" },
			"agent with no box":   func(in *NoteOnAsk) { in.Agent = "a-1" },
			"65-character agent":  func(in *NoteOnAsk) { in.Agent = "a-1@" + strings.Repeat("b", 61) },
			"ask not a uuid":      func(in *NoteOnAsk) { in.AskMsgID = "msg-1" },
			"ask in upper case":   func(in *NoteOnAsk) { in.AskMsgID = strings.ToUpper(askMsg) },
			"no ask workspace":    func(in *NoteOnAsk) { in.AskWorkspaceID = "" },
			"NUL in the body":     func(in *NoteOnAsk) { in.Body = "a\x00b" },
		}
		for name, mut := range bad {
			in := askOf()
			mut(&in)
			if _, err := f.st.CreateNoteOnAsk(ctx, p1, in, now); !errors.Is(err, ErrRealmBad) {
				t.Errorf("%s: %v, want ErrRealmBad", name, err)
			}
		}
		if l, err := f.st.ListNotes(ctx, p1); err != nil || len(l) != 0 {
			t.Fatalf("a refused ask stored %d notes, %v", len(l), err)
		}
		for _, prio := range []int{NotePriorityHighest, NotePriorityDefault} {
			in := askOf()
			in.Priority, in.Items, in.Links = &prio, make([]NoteItem, NoteItemsMax), urlLinks(NoteLinksMax)
			if _, err := f.st.CreateNoteOnAsk(ctx, p1, in, now); err != nil {
				t.Errorf("twin: priority %d, %d lines, %d links: %v", prio, NoteItemsMax, NoteLinksMax, err)
			}
		}
		ghost, _ := realmPersons()
		if _, err := f.st.CreateNoteOnAsk(ctx, "HUM-9"+ghost[5:], askOf(), now); !errors.Is(err, ErrNotFound) {
			t.Errorf("an ask of no such human: %v, want ErrNotFound", err)
		}
	})
}

func urlLinks(n int) []NoteLink {
	out := make([]NoteLink, n)
	for i := range out {
		out[i] = NoteLink{Kind: NoteLinkURL, Ref: "https://example.com"}
	}
	return out
}

// TestNotesC34OnAskCap (C34): the 2 001st note, made on an ask, is
// ErrNotesFull; TWIN: the 2 000th inserts on top.
func TestNotesC34OnAskCap(t *testing.T) {
	eachNotesDriver(t, func(t *testing.T, f notesFix) {
		ctx := context.Background()
		p1, _ := realmPersons()
		f.addHuman(t, p1)
		f.plant(t, p1, NotesPerPerson-1)
		in := askOf()
		in.Title = "the 2000th"
		if _, err := f.st.CreateNoteOnAsk(ctx, p1, in, time.Now()); err != nil {
			t.Fatalf("twin: the %dth note: %v", NotesPerPerson, err)
		}
		if _, err := f.st.CreateNoteOnAsk(ctx, p1, askOf(), time.Now()); !errors.Is(err, ErrNotesFull) {
			t.Errorf("the %dth note: %v, want ErrNotesFull", NotesPerPerson+1, err)
		}
		l, err := f.st.ListNotes(ctx, p1)
		if err != nil || len(l) != NotesPerPerson || l[0].Title != "the 2000th" {
			t.Errorf("ListNotes: %d rows, %v; want %d with the ask's note on top", len(l), err, NotesPerPerson)
		}
	})
}

// TestNotesC33AgentAskColumns (C33, Postgres only): rdb 0288's three
// provenance columns exist; a half-filled provenance is a
// notes_agent_ask_all_or_none violation; two notes citing the same ask
// insert next to a human note with NULL provenance (OQ-3: no unique index).
func TestNotesC33AgentAskColumns(t *testing.T) {
	f := pgNotesFix(t)
	ctx := context.Background()
	p1, _ := realmPersons()
	f.addHuman(t, p1)
	ins := func(agent, msg, ws any) error {
		return pgx.BeginFunc(ctx, f.owner.pool, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SELECT set_config('app.person_id', $1, true)`, p1); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO personal.notes (person_id, position, added_by_agent, ask_msg_id, ask_workspace_id)
				VALUES ($1, 0, $2, $3::uuid, $4)`, p1, agent, msg, ws)
			return err
		})
	}
	if err := ins(nil, nil, nil); err != nil {
		t.Fatalf("a human note (NULL provenance): %v", err)
	}
	for _, c := range [][3]any{{askBy, nil, nil}, {nil, askMsg, nil}, {nil, nil, askWS}, {askBy, askMsg, nil}} {
		if err := ins(c[0], c[1], c[2]); err == nil || !strings.Contains(err.Error(), "notes_agent_ask_all_or_none") {
			t.Errorf("half-filled provenance %v: %v, want notes_agent_ask_all_or_none", c, err)
		}
	}
	for i := 0; i < 2; i++ {
		if err := ins(askBy, askMsg, askWS); err != nil {
			t.Errorf("note %d on the same ask: %v", i+1, err)
		}
	}
	if l, err := f.st.ListNotes(ctx, p1); err != nil || len(l) != 3 {
		t.Errorf("ListNotes: %d rows, %v; want 3", len(l), err)
	}
}

// issueLink is an issue link to key in ws at position pos.
func issueLink(ws, key string, pos float64) NoteLink {
	return NoteLink{Kind: NoteLinkIssue, WorkspaceID: ws, Ref: key, Position: pos}
}

// TestNotesOnIssue (spec 155 2.12, SPL-5769): the person's notes that link
// an issue, in list order, archived ones too, each with its first link to
// it; never a note of another person, another workspace or another key.
// TWIN: P2's own note on the same issue is P2's answer, and only P2's.
func TestNotesOnIssue(t *testing.T) {
	eachNotesDriver(t, func(t *testing.T, f notesFix) {
		ctx := context.Background()
		now := time.Now().UTC().Truncate(time.Second)
		p1, p2 := realmPersons()
		f.addHuman(t, p1)
		f.addHuman(t, p2)
		mk := func(person, title string, links ...NoteLink) Note {
			n, err := f.st.CreateNote(ctx, person, Note{Title: title, Links: links}, now)
			if err != nil {
				t.Fatal(err)
			}
			return n
		}
		a := mk(p1, "A", NoteLink{Kind: NoteLinkTopic, WorkspaceID: "ws-1", Ref: "topic-1"},
			issueLink("ws-1", "SPL-1", 3), issueLink("ws-1", "SPL-1", 2))
		mk(p1, "other workspace", issueLink("ws-2", "SPL-1", 0))
		mk(p1, "other key", issueLink("ws-1", "SPL-2", 0), issueLink("ws-1", "SPL-10", 1))
		mk(p1, "no link")
		if got, err := f.st.NotesOnIssue(ctx, p2, "ws-1", "SPL-1"); err != nil || len(got) != 0 {
			t.Fatalf("P2 with no note: %d rows, %v; want 0 (P1's notes leaked)", len(got), err)
		}
		e := mk(p1, "E archived", issueLink("ws-1", "SPL-1", 0))
		yes := true
		if _, err := f.st.PatchNote(ctx, p1, e.ID, NotePatch{Archived: &yes}, []string{"ws-1"}, now); err != nil {
			t.Fatal(err)
		}
		d := mk(p2, "D", issueLink("ws-1", "SPL-1", 0))
		got, err := f.st.NotesOnIssue(ctx, p1, "ws-1", "SPL-1")
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 2 || got[0].ID != e.ID || got[1].ID != a.ID {
			t.Fatalf("P1: %+v; want E then A", got)
		}
		if got[0].ArchivedAt == nil || got[1].ArchivedAt != nil || got[1].Title != "A" {
			t.Errorf("P1 rows: archived %v/%v, title %q", got[0].ArchivedAt, got[1].ArchivedAt, got[1].Title)
		}
		if l := got[1].Link; l.Kind != NoteLinkIssue || l.WorkspaceID != "ws-1" || l.Ref != "SPL-1" || l.Position != 2 || l.ID == "" {
			t.Errorf("A's link: %+v; want the issue link at position 2", l)
		}
		twin, err := f.st.NotesOnIssue(ctx, p2, "ws-1", "SPL-1")
		if err != nil || len(twin) != 1 || twin[0].ID != d.ID {
			t.Errorf("twin: P2: %+v, %v; want D alone", twin, err)
		}
		for name, args := range map[string][2]string{"no workspace": {"", "SPL-1"}, "no key": {"ws-1", ""},
			"long key": {"ws-1", strings.Repeat("K", NoteRefMax+1)}} {
			if _, err := f.st.NotesOnIssue(ctx, p1, args[0], args[1]); !errors.Is(err, ErrRealmBad) {
				t.Errorf("%s: %v, want ErrRealmBad", name, err)
			}
		}
	})
}
