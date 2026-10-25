package store

import (
	"context"
	"fmt"
	"runtime"
	"sort"
	"sync"
	"time"
	"weak"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Memory's notes (personal_notes.go), the same contract as the Postgres
// side. They sit in a side table keyed by a weak pointer to the Memory, so
// this row (spec 155 B3) adds no field to memory.go; a Memory's entry goes
// with it. The notes themselves are guarded by Memory.mu like the rest of
// the realm (personal_memory.go).

// memNotes is person -> note id -> note.
type memNotes struct {
	byPerson map[string]map[string]*Note
}

var memNotesOf = struct {
	sync.Mutex
	m map[weak.Pointer[Memory]]*memNotes
}{m: map[weak.Pointer[Memory]]*memNotes{}}

// notesLocked is s's notes; s.mu is held.
func (s *Memory) notesLocked() *memNotes {
	k := weak.Make(s)
	memNotesOf.Lock()
	defer memNotesOf.Unlock()
	n, ok := memNotesOf.m[k]
	if !ok {
		n = &memNotes{byPerson: map[string]map[string]*Note{}}
		memNotesOf.m[k] = n
		runtime.AddCleanup(s, func(k weak.Pointer[Memory]) {
			memNotesOf.Lock()
			defer memNotesOf.Unlock()
			delete(memNotesOf.m, k)
		}, k)
	}
	return n
}

// noteLocked is the person's note, or ErrNotFound; s.mu is held.
func (s *Memory) noteLocked(person, noteID string) (*Note, error) {
	if err := checkNoteIDs(person, noteID); err != nil {
		return nil, err
	}
	n, ok := s.notesLocked().byPerson[person][noteID]
	if !ok {
		return nil, ErrNotFound
	}
	return n, nil
}

// copyNote is a deep copy, so a caller never holds the stored slices.
func copyNote(n *Note) Note {
	c := *n
	c.Items = append([]NoteItem(nil), n.Items...)
	c.Links = append([]NoteLink(nil), n.Links...)
	if n.ArchivedAt != nil {
		at := *n.ArchivedAt
		c.ArchivedAt = &at
	}
	return c
}

// sortedNotes is the person's notes in list order.
func (s *Memory) sortedNotes(person string) []*Note {
	var out []*Note
	for _, n := range s.notesLocked().byPerson[person] {
		out = append(out, n)
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.Pinned != b.Pinned {
			return a.Pinned
		}
		if a.Position != b.Position {
			return a.Position < b.Position
		}
		return a.CreatedAt.After(b.CreatedAt)
	})
	return out
}

// clearLeftLabelsMem is clearLeftLabels on n.
func clearLeftLabelsMem(n *Note, ws []string) {
	in := map[string]bool{}
	for _, w := range ws {
		in[w] = true
	}
	for i, l := range n.Links {
		if l.WorkspaceID != "" && !in[l.WorkspaceID] {
			n.Links[i].Label = ""
		}
	}
}

func sortNoteLinks(links []NoteLink) {
	sort.SliceStable(links, func(i, j int) bool {
		if links[i].Position != links[j].Position {
			return links[i].Position < links[j].Position
		}
		return links[i].CreatedAt.Before(links[j].CreatedAt)
	})
}

// mintNoteItems gives each line without an id a new one.
func mintNoteItems(items []NoteItem) []NoteItem {
	for i := range items {
		if items[i].ID == "" {
			items[i].ID = uuid.New()
		}
	}
	return items
}

// ListNotes is Notes.ListNotes.
func (s *Memory) ListNotes(_ context.Context, person string) ([]NoteSummary, error) {
	if err := checkPerson(person); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []NoteSummary
	for _, n := range s.sortedNotes(person) {
		m := NoteSummary{ID: n.ID, Title: n.Title, Snippet: noteSnippet(n.Body), Pinned: n.Pinned,
			Position: n.Position, ArchivedAt: copyNote(n).ArchivedAt, UpdatedAt: n.UpdatedAt,
			ItemsTotal: len(n.Items), LinkCount: len(n.Links)}
		for _, it := range n.Items {
			if it.Done {
				m.ItemsDone++
			}
		}
		out = append(out, m)
	}
	return out, nil
}

// CreateNote is Notes.CreateNote.
func (s *Memory) CreateNote(_ context.Context, person string, n Note, now time.Time) (Note, error) {
	if err := checkPerson(person); err != nil {
		return Note{}, err
	}
	n, err := checkNewNote(n)
	if err != nil {
		return Note{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.realmLocked(person, true); err != nil {
		return Note{}, err
	}
	held := s.notesLocked().byPerson[person]
	if len(held) >= NotesPerPerson {
		return Note{}, ErrNotesFull
	}
	top := 1.0
	for _, h := range held {
		top = min(top, h.Position)
	}
	now = now.UTC()
	n.ID, n.Position, n.ArchivedAt, n.CreatedAt, n.UpdatedAt = uuid.New(), top-1, nil, now, now
	n.Items = mintNoteItems(n.Items)
	for i := range n.Links {
		n.Links[i].ID, n.Links[i].CreatedAt = uuid.New(), now
	}
	if held == nil {
		held = map[string]*Note{}
		s.notesLocked().byPerson[person] = held
	}
	held[n.ID] = &n
	return copyNote(&n), nil
}

// NoteOf is Notes.NoteOf.
func (s *Memory) NoteOf(_ context.Context, person, noteID string) (Note, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	n, err := s.noteLocked(person, noteID)
	if err != nil {
		return Note{}, err
	}
	return copyNote(n), nil
}

// PatchNote is Notes.PatchNote.
func (s *Memory) PatchNote(_ context.Context, person, noteID string, p NotePatch, ws []string, now time.Time) (Note, error) {
	if err := checkNoteIDs(person, noteID); err != nil {
		return Note{}, err
	}
	if err := checkNotePatch(p); err != nil {
		return Note{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	n, err := s.noteLocked(person, noteID)
	if err != nil {
		return Note{}, err
	}
	now = now.UTC()
	if p.Title != nil {
		n.Title = *p.Title
	}
	if p.Body != nil {
		n.Body = *p.Body
	}
	if p.Pinned != nil {
		n.Pinned = *p.Pinned
	}
	if p.Position != nil {
		n.Position = *p.Position
	}
	switch {
	case p.Archived != nil && !*p.Archived:
		n.ArchivedAt = nil
	case p.Archived != nil && n.ArchivedAt == nil:
		n.ArchivedAt = &now
	}
	n.UpdatedAt = now
	clearLeftLabelsMem(n, ws)
	return copyNote(n), nil
}

// DeleteNote is Notes.DeleteNote.
func (s *Memory) DeleteNote(_ context.Context, person, noteID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.noteLocked(person, noteID); err != nil {
		return err
	}
	delete(s.notesLocked().byPerson[person], noteID)
	return nil
}

// PutNoteItems is Notes.PutNoteItems.
func (s *Memory) PutNoteItems(_ context.Context, person, noteID string, items []NoteItem, ws []string, now time.Time) (Note, error) {
	if err := checkNoteIDs(person, noteID); err != nil {
		return Note{}, err
	}
	items, err := checkNoteItems(items)
	if err != nil {
		return Note{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	n, err := s.noteLocked(person, noteID)
	if err != nil {
		return Note{}, err
	}
	n.Items, n.UpdatedAt = mintNoteItems(items), now.UTC()
	clearLeftLabelsMem(n, ws)
	return copyNote(n), nil
}

// AddNoteLink is Notes.AddNoteLink.
func (s *Memory) AddNoteLink(_ context.Context, person, noteID string, l NoteLink, ws []string, now time.Time) (NoteLink, error) {
	if err := checkNoteIDs(person, noteID); err != nil {
		return NoteLink{}, err
	}
	l.Position = 0
	if err := checkNoteLink(l); err != nil {
		return NoteLink{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	n, err := s.noteLocked(person, noteID)
	if err != nil {
		return NoteLink{}, err
	}
	if len(n.Links) >= NoteLinksMax {
		return NoteLink{}, fmt.Errorf("%w: more than %d links", ErrRealmBad, NoteLinksMax)
	}
	l.Position = 1
	for _, h := range n.Links {
		l.Position = max(l.Position, h.Position+1)
	}
	now = now.UTC()
	l.ID, l.CreatedAt, n.UpdatedAt = uuid.New(), now, now
	n.Links = append(n.Links, l)
	clearLeftLabelsMem(n, ws)
	return n.Links[len(n.Links)-1], nil
}

// PatchNoteLink is Notes.PatchNoteLink.
func (s *Memory) PatchNoteLink(_ context.Context, person, noteID, linkID string, p NoteLinkPatch, ws []string, now time.Time) (NoteLink, error) {
	if err := checkNoteIDs(person, noteID, linkID); err != nil {
		return NoteLink{}, err
	}
	if err := checkNoteLinkPatch(p); err != nil {
		return NoteLink{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	n, err := s.noteLocked(person, noteID)
	if err != nil {
		return NoteLink{}, err
	}
	for i := range n.Links {
		if n.Links[i].ID != linkID {
			continue
		}
		if p.Label != nil {
			n.Links[i].Label = *p.Label
		}
		if p.Position != nil {
			n.Links[i].Position = *p.Position
		}
		n.UpdatedAt = now.UTC()
		clearLeftLabelsMem(n, ws)
		out := n.Links[i]
		sortNoteLinks(n.Links)
		return out, nil
	}
	return NoteLink{}, ErrNotFound
}

// DeleteNoteLink is Notes.DeleteNoteLink.
func (s *Memory) DeleteNoteLink(_ context.Context, person, noteID, linkID string, ws []string, now time.Time) error {
	if err := checkNoteIDs(person, noteID, linkID); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	n, err := s.noteLocked(person, noteID)
	if err != nil {
		return err
	}
	for i := range n.Links {
		if n.Links[i].ID == linkID {
			n.Links = append(n.Links[:i:i], n.Links[i+1:]...)
			n.UpdatedAt = now.UTC()
			clearLeftLabelsMem(n, ws)
			return nil
		}
	}
	return ErrNotFound
}

// ExportNotes is Notes.ExportNotes.
func (s *Memory) ExportNotes(_ context.Context, person string) ([]Note, error) {
	if err := checkPerson(person); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Note
	for _, n := range s.sortedNotes(person) {
		out = append(out, copyNote(n))
	}
	return out, nil
}

// EraseNotes is Notes.EraseNotes.
func (s *Memory) EraseNotes(_ context.Context, person string) (int, error) {
	if err := checkPerson(person); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	nn := s.notesLocked()
	n := len(nn.byPerson[person])
	delete(nn.byPerson, person)
	return n, nil
}
