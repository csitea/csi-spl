package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

const flowUsage = `usage: spool flow --as <AGENT> [--kind mention|blocked|ready|release] [--limit 1-50] [--before CURSOR] [--json]
  What is happening for the agent (spec 130): one line per topic per UTC day of the
  lines that name it (<id>@<this box>), blocked and ready included, and one line per
  UTC day of releases. --before takes the "next" cursor a page ends with.`

// cmdFlow is spec 130 section 5: an agent reads its Flow from the hub.
func cmdFlow(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("flow", flag.ContinueOnError)
	fs.Usage = func() { fmt.Fprintln(os.Stderr, flowUsage) }
	var in action.FlowArgs
	var raw bool
	fs.StringVar(&in.As, "as", "", "the acting agent id (one this box announced)")
	fs.StringVar(&in.Kind, "kind", "", "mention | blocked | ready | release")
	fs.IntVar(&in.Limit, "limit", 0, "topic lines, 1..50 (default 30)")
	fs.StringVar(&in.Before, "before", "", "the previous page's next cursor")
	fs.BoolVar(&raw, "json", false, "print the hub's page object")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := action.Flow(ctx, cfg, in)
	if err != nil {
		return fail(err)
	}
	if raw {
		fmt.Println(string(out))
		return 0
	}
	if err := printFlow(os.Stdout, out); err != nil {
		return fail(err)
	}
	return 0
}

// flowPage is the part of the hub's folded page `spool flow` prints.
type flowPage struct {
	Lines []struct {
		Kind        string   `json:"kind"`
		Day         string   `json:"day"`
		Count       int      `json:"count"`
		At          string   `json:"at"`
		Unread      bool     `json:"unread"`
		Link        string   `json:"link"`
		Title       string   `json:"title"`
		IDs         []string `json:"ids"`
		IDsMore     int      `json:"ids_more"`
		VersionFrom string   `json:"version_from"`
		VersionTo   string   `json:"version_to"`
		Versions    int      `json:"versions"`
	} `json:"lines"`
	Next string `json:"next"`
}

// printFlow writes one line per Flow line, as the WUI words it:
// `* blocked 4 in "Flow v2" · c-002 +2 · 16:40Z  /t/<task>#<msg>` (* = unread).
func printFlow(w io.Writer, raw []byte) error {
	var p flowPage
	if err := json.Unmarshal(raw, &p); err != nil {
		return fmt.Errorf("flow reply: %w", err)
	}
	for _, l := range p.Lines {
		dot := " "
		if l.Unread {
			dot = "*"
		}
		if l.Kind == "release" {
			span := l.VersionTo
			if l.VersionFrom != l.VersionTo {
				span = l.VersionFrom + " .. " + l.VersionTo
			}
			fmt.Fprintf(w, "%s release %s (%d versions) · %s  %s\n", dot, span, l.Versions, l.Day, l.Link)
			continue
		}
		who := strings.Join(l.IDs, ", ")
		if l.IDsMore > 0 {
			who += fmt.Sprintf(" +%d", l.IDsMore)
		}
		at := l.At
		if t, err := time.Parse(time.RFC3339Nano, l.At); err == nil {
			at = t.UTC().Format("2006-01-02 15:04Z")
		}
		fmt.Fprintf(w, "%s %s %d in %q · %s · %s  %s\n", dot, l.Kind, l.Count, l.Title, who, at, l.Link)
	}
	if p.Next != "" {
		fmt.Fprintf(w, "next: %s\n", p.Next)
	}
	return nil
}
