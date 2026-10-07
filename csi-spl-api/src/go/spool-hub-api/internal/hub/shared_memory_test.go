package hub_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// spec 102 T020: two machines' boxes share one memory through the hub. A
// lesson added on one box under a title another box already used is merged
// into that one lesson; the index carries titles and one line, never the
// bodies; show reads one by any spelling of its title. Control: a different
// title is a second lesson.

type memoryOut struct {
	Lesson  hub.MemoryLesson   `json:"lesson"`
	Lessons []hub.MemoryLesson `json:"lessons"`
	Merged  bool               `json:"merged"`
}

func memoryCall(t *testing.T, b *box, op string, in map[string]string) (memoryOut, error) {
	t.Helper()
	var row json.RawMessage
	if in != nil {
		row, _ = json.Marshal(in)
	}
	raw, err := b.c.Lane(context.Background(), op, "", row)
	var out memoryOut
	if err == nil {
		if err := json.Unmarshal(raw, &out); err != nil {
			t.Fatalf("answer %s: %v", raw, err)
		}
	}
	return out, err
}

func TestBoxSharedMemory(t *testing.T) {
	_, _, _, _, home, sat := boxArchiveRig(t)

	if got, err := memoryCall(t, home, "memory_index", nil); err != nil || len(got.Lessons) != 0 {
		t.Fatalf("empty index: %+v %v", got, err)
	}
	got, err := memoryCall(t, home, "memory_add", map[string]string{"title": "Push race", "text": "fetch, rebase, push\nthen check merge-base"})
	if err != nil || got.Merged || got.Lesson.WriterBox != "box-b" {
		t.Fatalf("first add: %+v %v", got, err)
	}
	got, err = memoryCall(t, sat, "memory_add", map[string]string{"title": "push RACE.", "text": "the hook re-runs the gate"})
	if err != nil || !got.Merged || got.Lesson.Merges != 1 || got.Lesson.WriterBox != "box-c" ||
		!strings.HasSuffix(got.Lesson.Body, "\n\nthe hook re-runs the gate") {
		t.Fatalf("add twice with the same title must merge: %+v %v", got, err)
	}
	// control: a different title is a second lesson
	if got, err = memoryCall(t, sat, "memory_add", map[string]string{"title": "Disk full", "text": "report df -h"}); err != nil || got.Merged {
		t.Fatalf("second title: %+v %v", got, err)
	}

	idx, err := memoryCall(t, sat, "memory_index", nil)
	if err != nil || len(idx.Lessons) != 2 || idx.Lessons[0].Title != "Disk full" || idx.Lessons[1].Title != "Push race" {
		t.Fatalf("index: %+v %v", idx, err)
	}
	for _, l := range idx.Lessons {
		if l.Body != "" || strings.Contains(l.Line, "merge-base") || strings.Contains(l.Line, "hook") {
			t.Fatalf("the index carries a body: %+v", l)
		}
	}
	if idx.Lessons[1].Line != "fetch, rebase, push" {
		t.Fatalf("index line: %q", idx.Lessons[1].Line)
	}

	show, err := memoryCall(t, home, "memory_show", map[string]string{"title": " PUSH race "})
	if err != nil || !strings.Contains(show.Lesson.Body, "merge-base") || !strings.Contains(show.Lesson.Body, "hook") {
		t.Fatalf("show: %+v %v", show, err)
	}

	// refusals: the hub checks the frame before the store
	for _, c := range []struct {
		op string
		in map[string]string
	}{
		{"memory_show", map[string]string{"title": "no such lesson"}},
		{"memory_add", map[string]string{"title": "", "text": "x"}},
		{"memory_add", map[string]string{"title": "t", "text": ""}},
		{"memory_add", map[string]string{"title": "two\nlines", "text": "x"}},
		{"memory_nosuch", map[string]string{"title": "t"}},
	} {
		if _, err := memoryCall(t, home, c.op, c.in); err == nil {
			t.Errorf("%s %v accepted", c.op, c.in)
		}
	}
}
