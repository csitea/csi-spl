package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// cmdMemory is the agents' door to the shared memory in the hub (spec 102
// v1.0 section 12), over the authenticated hello like `spool lane`:
//
//	memory add --title <t> --text <t|->   add a lesson, or merge it into the one
//	                                      with the same normalised title
//	memory show <title>                   one lesson, its whole text
//	memory index                          every lesson: title and one line (the seed's)
//
// The memory holds how to work in the spool hub (traps, commands,
// conventions), never task state.
func cmdMemory(cfg *config.Config, args []string) int {
	if len(args) == 0 {
		return fail(errors.New("usage: spool memory add --title <t> --text <t|-> | spool memory show <title> | spool memory index"))
	}
	if cfg.HubURL == "" {
		return fail(errors.New("the shared memory needs hub mode ($SPOOL_HUB_URL is not set)"))
	}
	switch args[0] {
	case "add":
		return memoryAdd(cfg, args[1:])
	case "show":
		return memoryShow(cfg, args[1:])
	case "index":
		return memoryIndex(cfg, args[1:])
	}
	return fail(fmt.Errorf("memory: unknown sub-verb %q (add | show | index)", args[0]))
}

// memoryLesson is the hub's lesson object (hub.MemoryLesson).
type memoryLesson struct {
	Title  string `json:"title"`
	Line   string `json:"line"`
	Body   string `json:"body"`
	Merges int    `json:"merges"`
}

// memoryCall sends one memory frame and decodes the answer into out.
func memoryCall(cfg *config.Config, op string, in map[string]string, out any) error {
	var row json.RawMessage
	if in != nil {
		var err error
		if row, err = json.Marshal(in); err != nil {
			return err
		}
	}
	ctx, stop := interruptible()
	defer stop()
	raw, err := hubclient.New(cfg).Lane(ctx, op, "", row)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("memory: the hub's answer does not parse: %w", err)
	}
	return nil
}

func memoryAdd(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("memory add", flag.ContinueOnError)
	title := fs.String("title", "", "the lesson's title; one with the same normalised title is merged into")
	text := fs.String("text", "", "the lesson's text, or - for stdin")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	body := *text
	if body == "-" {
		raw, err := io.ReadAll(io.LimitReader(os.Stdin, 64<<10))
		if err != nil {
			return fail(err)
		}
		body = string(raw)
	}
	if why := store.CheckLesson(*title, body); why != "" {
		return fail(fmt.Errorf("memory add: %s", why))
	}
	var out struct {
		Lesson memoryLesson `json:"lesson"`
		Merged bool         `json:"merged"`
	}
	if err := memoryCall(cfg, "memory_add", map[string]string{"title": *title, "text": body}, &out); err != nil {
		return fail(err)
	}
	if out.Merged {
		fmt.Printf("merged into %q (%d merges)\n", out.Lesson.Title, out.Lesson.Merges)
	} else {
		fmt.Printf("added %q\n", out.Lesson.Title)
	}
	return 0
}

func memoryShow(cfg *config.Config, args []string) int {
	title := strings.Join(args, " ")
	if store.LessonKey(title) == "" {
		return fail(errors.New("usage: spool memory show <title>"))
	}
	var out struct {
		Lesson memoryLesson `json:"lesson"`
	}
	if err := memoryCall(cfg, "memory_show", map[string]string{"title": title}, &out); err != nil {
		return fail(err)
	}
	fmt.Printf("# %s\n\n%s\n", out.Lesson.Title, out.Lesson.Body)
	return 0
}

func memoryIndex(cfg *config.Config, args []string) int {
	if len(args) != 0 {
		return fail(errors.New("usage: spool memory index"))
	}
	var out struct {
		Lessons []memoryLesson `json:"lessons"`
	}
	if err := memoryCall(cfg, "memory_index", nil, &out); err != nil {
		return fail(err)
	}
	fmt.Print(formatMemoryIndex(out.Lessons))
	return 0
}

// formatMemoryIndex is the index a seed carries: one line per lesson, its
// title and its one line. A body is never printed, even if a hub sent one.
func formatMemoryIndex(ls []memoryLesson) string {
	var b strings.Builder
	for _, l := range ls {
		if l.Line == "" {
			fmt.Fprintf(&b, "- %s\n", l.Title)
			continue
		}
		fmt.Fprintf(&b, "- %s: %s\n", l.Title, l.Line)
	}
	return b.String()
}
