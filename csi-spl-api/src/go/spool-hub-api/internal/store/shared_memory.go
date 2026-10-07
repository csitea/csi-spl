package store

import (
	"context"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// The shared memory of the agents (spec 102 v1.0 section 12, rdb 0146): one
// per workspace, scoped to how to work in the spool hub. A lesson is keyed by
// its normalised title; adding under a title that already exists merges the
// text into that lesson instead of piling up a second one. Seeds read the
// index (titles and one line each), never the bodies.

// Lesson is one row of shared_memory_lessons.
type Lesson struct {
	Key       string // LessonKey(Title): the merge key
	Title     string // as its first writer spelled it
	Body      string // every distinct text added under Key, oldest first
	Merges    int    // adds merged into the first one
	WriterBox string // the box that last changed it
	CreatedAt time.Time
	UpdatedAt time.Time
}

// Lesson bounds (0146's CHECKs carry the same numbers, in characters).
const (
	LessonTitleMax = 120
	LessonTextMax  = 4000  // one add
	LessonBodyMax  = 16000 // the merged body
	LessonLineMax  = 100   // the index line
)

// lessonSep is what a merge puts between two texts.
const lessonSep = "\n\n"

// ErrLessonFull is a merge that would grow the body past LessonBodyMax.
var ErrLessonFull = errors.New("lesson is full")

// SharedMemory is the shared-memory half of the store contract. A driver
// that does not implement it keeps no shared memory (the hub answers 501).
type SharedMemory interface {
	// AddLesson adds text under title: a new lesson, or merged into the
	// lesson whose key is LessonKey(title) (merged = true). A text the body
	// already holds changes nothing. ErrLessonFull when the merge would pass
	// LessonBodyMax. The caller has run CheckLesson.
	AddLesson(ctx context.Context, tenantID, title, text, box string, now time.Time) (l Lesson, merged bool, err error)
	// GetLesson reads the lesson of LessonKey(title); ok = false when none.
	GetLesson(ctx context.Context, tenantID, title string) (l Lesson, ok bool, err error)
	// ListLessons reads every lesson of the tenant, in key order.
	ListLessons(ctx context.Context, tenantID string) ([]Lesson, error)
}

// LessonKey is a title's merge key: lower case, every run of white space as
// one space, trailing punctuation dropped. "Push race!" and " push   RACE"
// are one lesson.
func LessonKey(title string) string {
	k := strings.Join(strings.Fields(strings.ToLower(title)), " ")
	return strings.TrimSpace(strings.TrimRight(k, ".,:;!?"))
}

// CheckLesson names the first thing an add may not carry ("" = fine): the
// client and the hub refuse the same shapes 0146's CHECKs would.
func CheckLesson(title, text string) string {
	switch {
	case LessonKey(title) == "":
		return "title must name the lesson"
	case utf8.RuneCountInString(strings.TrimSpace(title)) > LessonTitleMax || hasControl(title):
		return "title must be one line of up to 120 characters"
	case strings.TrimSpace(text) == "":
		return "text must not be empty"
	case utf8.RuneCountInString(strings.TrimSpace(text)) > LessonTextMax || hasBodyControl(text):
		return "text must be up to 4000 characters of text"
	}
	return ""
}

// hasBodyControl is hasControl allowing the line breaks and tabs of a text.
func hasBodyControl(s string) bool {
	for _, r := range s {
		if (r < 0x20 && r != '\n' && r != '\t' && r != '\r') || r == 0x7f {
			return true
		}
	}
	return false
}

// mergeLessonBody appends add to body unless body already holds it; changed
// reports whether it did. Both drivers merge through it.
func mergeLessonBody(body, add string) (out string, changed bool, err error) {
	add = strings.TrimSpace(add)
	if strings.Contains(body, add) {
		return body, false, nil
	}
	out = body + lessonSep + add
	if utf8.RuneCountInString(out) > LessonBodyMax {
		return body, false, ErrLessonFull
	}
	return out, true, nil
}

// LessonLine is the index's one line of a lesson: the body's first non-empty
// line, cut at LessonLineMax characters. Never more of the body.
func LessonLine(body string) string {
	for _, ln := range strings.Split(body, "\n") {
		if ln = strings.TrimSpace(ln); ln != "" {
			if r := []rune(ln); len(r) > LessonLineMax {
				return string(r[:LessonLineMax-3]) + "..."
			}
			return ln
		}
	}
	return ""
}

// The Memory driver keeps its lessons beside the store rather than in it
// (memory.go is shared by every lane): one map per *Memory, under its own
// lock, keyed tenant -> key.
var (
	memLessonsMu sync.Mutex
	memLessons   = map[*Memory]map[string]map[string]Lesson{}
)

func (s *Memory) lessons(tenant string) map[string]Lesson {
	byTenant := memLessons[s]
	if byTenant == nil {
		byTenant = map[string]map[string]Lesson{}
		memLessons[s] = byTenant
	}
	if byTenant[tenant] == nil {
		byTenant[tenant] = map[string]Lesson{}
	}
	return byTenant[tenant]
}

func (s *Memory) AddLesson(_ context.Context, tenant, title, text, box string, now time.Time) (Lesson, bool, error) {
	memLessonsMu.Lock()
	defer memLessonsMu.Unlock()
	ls, key := s.lessons(tenant), LessonKey(title)
	l, ok := ls[key]
	if !ok {
		l = Lesson{Key: key, Title: strings.TrimSpace(title), Body: strings.TrimSpace(text), WriterBox: box,
			CreatedAt: now, UpdatedAt: now}
		ls[key] = l
		return l, false, nil
	}
	body, changed, err := mergeLessonBody(l.Body, text)
	if err != nil || !changed {
		return l, true, err
	}
	l.Body, l.Merges, l.WriterBox, l.UpdatedAt = body, l.Merges+1, box, now
	ls[key] = l
	return l, true, nil
}

func (s *Memory) GetLesson(_ context.Context, tenant, title string) (Lesson, bool, error) {
	memLessonsMu.Lock()
	defer memLessonsMu.Unlock()
	l, ok := s.lessons(tenant)[LessonKey(title)]
	return l, ok, nil
}

func (s *Memory) ListLessons(_ context.Context, tenant string) ([]Lesson, error) {
	memLessonsMu.Lock()
	defer memLessonsMu.Unlock()
	out := []Lesson{}
	for _, l := range s.lessons(tenant) {
		out = append(out, l)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}
