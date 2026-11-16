package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

const noteUsage = `usage: spool note add --as <AGENT> --ask-msg <UUID> [--title T] [--body B | --body-file F]
         [--priority 1-5] [--pinned] [--archived] [--item TEXT]... [--done-item TEXT]...
         [--link JSON]... [--kind K --ref R [--day YYYY-MM-DD] [--label L]] [--json]
  Adds one note to the Notes of the person who asked for it (spec 155 2.11). --ask-msg
  is the msg_id of that person's message, in a topic the agent reads: the note goes to
  its author, never to a person the agent names. Checklist lines keep their order.
  A link is --link '{"kind":"topic","ref":"<uuid>","label":"..."}' or one --kind/--ref
  pair; kind msg|topic|issue|event|doc|channel takes the ask's workspace, url none.`

// noteItems is the checklist flags in the order given: --item adds an open
// line, --done-item a done one.
type noteItems struct {
	items *[]action.NoteItemArg
	done  bool
}

func (n noteItems) String() string { return "" }
func (n noteItems) Set(v string) error {
	*n.items = append(*n.items, action.NoteItemArg{Text: v, Done: n.done})
	return nil
}

// noteLinks is the --link flags, each one link object.
type noteLinks struct{ links *[]action.NoteLinkArg }

func (n noteLinks) String() string { return "" }
func (n noteLinks) Set(v string) error {
	var l action.NoteLinkArg
	if err := json.Unmarshal([]byte(v), &l); err != nil {
		return fmt.Errorf("--link takes one JSON object {kind, ref, workspace_id, day, label}: %w", err)
	}
	*n.links = append(*n.links, l)
	return nil
}

// cmdNote is spec 155 2.11: `spool note add`, an agent adds a note on a
// person's ask. add is the one subverb: an agent reads, edits and deletes
// no note.
func cmdNote(cfg *config.Config, args []string) int {
	if len(args) == 0 || args[0] != "add" {
		fmt.Fprintln(os.Stderr, noteUsage)
		return 1
	}
	in, raw, ok := parseNoteAdd(args[1:])
	if !ok {
		return 1
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := action.NoteAdd(ctx, cfg, in)
	if err != nil {
		return fail(err)
	}
	if raw {
		fmt.Println(string(out))
		return 0
	}
	if err := printNoteAdded(os.Stdout, out); err != nil {
		return fail(err)
	}
	return 0
}

// parseNoteAdd reads the add flags; ok false = a usage error, printed.
func parseNoteAdd(args []string) (action.NoteAddArgs, bool, bool) {
	fs := flag.NewFlagSet("note add", flag.ContinueOnError)
	fs.Usage = func() { fmt.Fprintln(os.Stderr, noteUsage) }
	var in action.NoteAddArgs
	var raw bool
	var bodyFile string
	var one action.NoteLinkArg
	fs.StringVar(&in.As, "as", "", "the acting agent id (one this box announced)")
	fs.StringVar(&in.AskMsgID, "ask-msg", "", "the msg_id of the person's message that asked for the note")
	fs.StringVar(&in.Title, "title", "", "the title, at most 200 characters")
	fs.StringVar(&in.Body, "body", "", "the text, at most 20 000 characters")
	fs.StringVar(&bodyFile, "body-file", "", "read the text from this file (- = stdin)")
	fs.IntVar(&in.Priority, "priority", 0, "1 (highest) .. 5 (default 5)")
	fs.BoolVar(&in.Pinned, "pinned", false, "pin the note")
	fs.BoolVar(&in.Archived, "archived", false, "archive the note at once")
	fs.Var(noteItems{items: &in.Items}, "item", "an open checklist line (repeat)")
	fs.Var(noteItems{items: &in.Items, done: true}, "done-item", "a done checklist line (repeat)")
	fs.Var(noteLinks{links: &in.Links}, "link", "one link as JSON (repeat)")
	fs.StringVar(&one.Kind, "kind", "", "one link's kind: msg|topic|issue|event|doc|channel|url")
	fs.StringVar(&one.Ref, "ref", "", "one link's ref: a uuid, an issue key, a path, a channel or an https:// address")
	fs.StringVar(&one.Day, "day", "", "an event link's day, YYYY-MM-DD")
	fs.StringVar(&one.Label, "label", "", "one link's label")
	fs.BoolVar(&raw, "json", false, "print the hub's answer object")
	if err := fs.Parse(args); err != nil {
		return in, false, false
	}
	if bodyFile != "" {
		if in.Body != "" {
			fmt.Fprintln(os.Stderr, "spool: --body and --body-file are exclusive")
			return in, false, false
		}
		b, err := readBodyFile(bodyFile)
		if err != nil {
			fmt.Fprintln(os.Stderr, "spool: --body-file: "+err.Error())
			return in, false, false
		}
		in.Body = b
	}
	if one.Kind != "" || one.Ref != "" {
		in.Links = append(in.Links, one)
	}
	return in, raw, true
}

func readBodyFile(path string) (string, error) {
	if path == "-" {
		b, err := io.ReadAll(os.Stdin)
		return string(b), err
	}
	b, err := os.ReadFile(path) //nolint:gosec // the agent's own file, named on its command line
	return string(b), err
}

// printNoteAdded writes "note <id> added <created_at>".
func printNoteAdded(w io.Writer, raw []byte) error {
	var a struct {
		ID        string `json:"id"`
		CreatedAt string `json:"created_at"`
	}
	if err := json.Unmarshal(raw, &a); err != nil {
		return fmt.Errorf("note reply: %w", err)
	}
	fmt.Fprintf(w, "note %s added %s\n", a.ID, a.CreatedAt)
	return nil
}
