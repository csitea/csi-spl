package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// spec 102 T020 (rdb 0146): the shared memory. Two adds under one title -
// spelled differently - are one lesson with both texts; the same text again
// changes nothing; another tenant sees none of it. Control: a different
// title is a second lesson. Run on Memory and Postgres.
func TestSharedMemoryAddMerge(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			sm, ok := st.(SharedMemory)
			if !ok {
				t.Fatalf("%s keeps no shared memory", name)
			}
			tid := newTenant(t, st)
			other := newTenant(t, st)

			l, merged, err := sm.AddLesson(ctx, tid, "Push race", "fetch, rebase, then push", "box-a", t0)
			if err != nil || merged || l.Key != "push race" || l.Title != "Push race" || l.Merges != 0 || l.WriterBox != "box-a" {
				t.Fatalf("first add: %+v merged=%v %v", l, merged, err)
			}
			// the same lesson, spelled another way, from another box: merged
			l, merged, err = sm.AddLesson(ctx, tid, "  push   RACE! ", "the hook re-runs the gate", "box-b", t0.Add(time.Minute))
			if err != nil || !merged || l.Merges != 1 || l.Title != "Push race" || l.WriterBox != "box-b" ||
				l.Body != "fetch, rebase, then push\n\nthe hook re-runs the gate" {
				t.Fatalf("merge: %+v merged=%v %v", l, merged, err)
			}
			// a text the body already holds changes nothing
			if l, merged, err = sm.AddLesson(ctx, tid, "push race", "the hook re-runs the gate", "box-c", t0.Add(2*time.Minute)); err != nil ||
				!merged || l.Merges != 1 || l.WriterBox != "box-b" {
				t.Fatalf("repeat: %+v merged=%v %v", l, merged, err)
			}
			ls, err := sm.ListLessons(ctx, tid)
			if err != nil || len(ls) != 1 {
				t.Fatalf("two adds under one title must be one lesson: %+v %v", ls, err)
			}

			// control: a different title is a second lesson
			if _, merged, err = sm.AddLesson(ctx, tid, "Disk full", "report df -h", "box-a", t0); err != nil || merged {
				t.Fatalf("second title: merged=%v %v", merged, err)
			}
			if ls, _ = sm.ListLessons(ctx, tid); len(ls) != 2 || ls[0].Key != "disk full" || ls[1].Key != "push race" {
				t.Fatalf("a different title must be a second lesson, in key order: %+v", ls)
			}

			got, ok, err := sm.GetLesson(ctx, tid, "PUSH RACE.")
			if err != nil || !ok || got.Merges != 1 || !strings.Contains(got.Body, "hook") {
				t.Fatalf("show by any spelling: %+v %v %v", got, ok, err)
			}
			if _, ok, err = sm.GetLesson(ctx, tid, "no such lesson"); err != nil || ok {
				t.Fatalf("missing lesson: ok=%v %v", ok, err)
			}
			// another tenant's memory is separate
			if ls, _ = sm.ListLessons(ctx, other); len(ls) != 0 {
				t.Fatalf("other tenant sees lessons: %+v", ls)
			}
			if _, ok, _ = sm.GetLesson(ctx, other, "push race"); ok {
				t.Fatal("other tenant reads a lesson")
			}
		})
	}
}

// A merge never grows the body past LessonBodyMax; the refused add leaves the
// lesson as it was.
func TestSharedMemoryFull(t *testing.T) {
	ctx := context.Background()
	t0 := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			sm := st.(SharedMemory)
			tid := newTenant(t, st)
			for i := 0; i < 4; i++ {
				if _, _, err := sm.AddLesson(ctx, tid, "big", strings.Repeat(string(rune('a'+i)), 3900), "box-a", t0); err != nil {
					t.Fatalf("add %d: %v", i, err)
				}
			}
			if _, _, err := sm.AddLesson(ctx, tid, "big", strings.Repeat("e", 3900), "box-a", t0); !errors.Is(err, ErrLessonFull) {
				t.Fatalf("fifth add: %v, want ErrLessonFull", err)
			}
			if l, _, _ := sm.GetLesson(ctx, tid, "big"); l.Merges != 3 || strings.Contains(l.Body, "e") {
				t.Fatalf("the refused add changed the lesson: merges=%d", l.Merges)
			}
		})
	}
}

func TestLessonKeyCheckLine(t *testing.T) {
	for in, want := range map[string]string{"Push race": "push race", "  push\tRACE!? ": "push race", "a.b": "a.b", "...": ""} {
		if got := LessonKey(in); got != want {
			t.Errorf("LessonKey(%q) = %q, want %q", in, got, want)
		}
	}
	if why := CheckLesson("t", "x"); why != "" {
		t.Fatalf("a good lesson refused: %s", why)
	}
	for _, c := range [][2]string{{"", "x"}, {"!!", "x"}, {"a\nb", "x"}, {strings.Repeat("t", 121), "x"},
		{"t", " "}, {"t", strings.Repeat("x", 4001)}, {"t", "a\x00b"}} {
		if CheckLesson(c[0], c[1]) == "" {
			t.Errorf("CheckLesson(%q, %q) accepted", c[0], c[1])
		}
	}
	if got := LessonLine("\n first line \nsecond"); got != "first line" {
		t.Errorf("LessonLine: %q", got)
	}
	if got := LessonLine(strings.Repeat("x", 150)); len(got) != LessonLineMax || !strings.HasSuffix(got, "...") {
		t.Errorf("LessonLine cut: %d %q", len(got), got)
	}
}
