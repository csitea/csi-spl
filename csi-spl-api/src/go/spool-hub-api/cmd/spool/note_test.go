package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// parseNoteAdd: every flag lands in NoteAddArgs, checklist lines keep their
// order with their done bit, --link and one --kind/--ref pair both add a link.
func TestParseNoteAdd(t *testing.T) {
	in, raw, ok := parseNoteAdd([]string{
		"--as", "c-100", "--ask-msg", "0b9e4c1a-1111-4aaa-8bbb-000000000001",
		"--title", "T", "--body", "B", "--priority", "2", "--pinned", "--archived",
		"--item", "one", "--done-item", "two", "--item", "three",
		"--link", `{"kind":"topic","ref":"0b9e4c1a-1111-4aaa-8bbb-000000000002","label":"L"}`,
		"--kind", "event", "--ref", "e1", "--day", "2026-11-16", "--label", "E", "--json",
	})
	if !ok || !raw {
		t.Fatalf("ok=%v raw=%v, want both true", ok, raw)
	}
	if in.As != "c-100" || in.AskMsgID != "0b9e4c1a-1111-4aaa-8bbb-000000000001" || in.Title != "T" ||
		in.Body != "B" || in.Priority != 2 || !in.Pinned || !in.Archived {
		t.Fatalf("scalars: %+v", in)
	}
	wantItems := []action.NoteItemArg{{Text: "one"}, {Text: "two", Done: true}, {Text: "three"}}
	if len(in.Items) != 3 || in.Items[0] != wantItems[0] || in.Items[1] != wantItems[1] || in.Items[2] != wantItems[2] {
		t.Fatalf("items %+v, want %+v", in.Items, wantItems)
	}
	if len(in.Links) != 2 || in.Links[0].Kind != "topic" || in.Links[0].Label != "L" ||
		in.Links[1].Kind != "event" || in.Links[1].Ref != "e1" || in.Links[1].Day != "2026-11-16" || in.Links[1].Label != "E" {
		t.Fatalf("links %+v", in.Links)
	}
	if (noteItems{}).String() != "" || (noteLinks{}).String() != "" {
		t.Fatal("flag String() should be empty")
	}
}

// parseNoteAdd refusals: a bad --link, an unknown flag, --body with
// --body-file, and a --body-file that does not exist are usage errors.
func TestParseNoteAddRefusals(t *testing.T) {
	for name, args := range map[string][]string{
		"CONTROL bad link":     {"--link", "not json"},
		"CONTROL unknown flag": {"--nope"},
		"CONTROL body + file":  {"--body", "B", "--body-file", "x"},
		"CONTROL missing file": {"--body-file", filepath.Join(t.TempDir(), "absent")},
	} {
		if _, _, ok := parseNoteAdd(args); ok {
			t.Errorf("%s: ok, want a usage error", name)
		}
	}
	in, _, ok := parseNoteAdd([]string{"--as", "c-100"})
	if !ok || in.Links != nil || in.Items != nil || in.Body != "" {
		t.Fatalf("plain: ok=%v %+v", ok, in)
	}
}

// --body-file reads a file, and - reads stdin.
func TestParseNoteAddBodyFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "body.md")
	if err := os.WriteFile(p, []byte("from file"), 0o600); err != nil {
		t.Fatal(err)
	}
	in, _, ok := parseNoteAdd([]string{"--body-file", p})
	if !ok || in.Body != "from file" {
		t.Fatalf("file: ok=%v body=%q", ok, in.Body)
	}
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdin
	os.Stdin = r
	t.Cleanup(func() { os.Stdin = old })
	if _, err := w.WriteString("from stdin"); err != nil {
		t.Fatal(err)
	}
	_ = w.Close()
	in, _, ok = parseNoteAdd([]string{"--body-file", "-"})
	if !ok || in.Body != "from stdin" {
		t.Fatalf("stdin: ok=%v body=%q", ok, in.Body)
	}
}

// printNoteAdded: "note <id> added <created_at>"; a reply that is not JSON
// is an error.
func TestPrintNoteAdded(t *testing.T) {
	var b bytes.Buffer
	if err := printNoteAdded(&b, []byte(`{"msg_id":"m","id":"n1","created_at":"2026-11-16T19:00:00Z"}`)); err != nil {
		t.Fatal(err)
	}
	if b.String() != "note n1 added 2026-11-16T19:00:00Z\n" {
		t.Fatalf("got %q", b.String())
	}
	if err := printNoteAdded(&b, []byte(`not json`)); err == nil {
		t.Fatal("CONTROL bad reply: want an error")
	}
}

// cmdNote: no subverb or another subverb prints the usage (1); a usage
// error is 1; with no hub the action refuses before any network call.
func TestCmdNoteRefusals(t *testing.T) {
	cfg := &config.Config{}
	for name, args := range map[string][]string{
		"CONTROL no subverb":    nil,
		"CONTROL other subverb": {"list"},
		"CONTROL usage error":   {"add", "--nope"},
	} {
		if rc := cmdNote(cfg, args); rc != 1 {
			t.Errorf("%s: rc %d, want 1", name, rc)
		}
	}
	if rc := cmdNote(cfg, []string{"add", "--as", "c-100", "--ask-msg", "x"}); rc == 0 {
		t.Fatal("CONTROL no hub: rc 0, want a refusal")
	}
}
