package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

const topicsUsage = `usage: spool topics --as <AGENT> --channel <CHANNEL> [--limit 1-100] [--before CURSOR] [--json]
  The root topics of a channel the agent is seated in on this box, newest activity
  first: one line per topic, "<task_id>  <last activity>  <subject>", no bodies. A
  channel it is not in lists nothing. --before takes the "next" cursor a page ends with.`

// cmdTopics is t1 1457bb6f: an agent lists a channel's topics from the hub.
func cmdTopics(cfg *config.Config, args []string) int {
	fs := flag.NewFlagSet("topics", flag.ContinueOnError)
	fs.Usage = func() { fmt.Fprintln(os.Stderr, topicsUsage) }
	var in action.TopicsArgs
	var raw bool
	fs.StringVar(&in.As, "as", "", "the acting agent id (one this box announced)")
	fs.StringVar(&in.Channel, "channel", "", "the channel, with or without its #")
	fs.IntVar(&in.Limit, "limit", 0, "topics, 1..100 (default 50)")
	fs.StringVar(&in.Before, "before", "", "the previous page's next cursor")
	fs.BoolVar(&raw, "json", false, "print the hub's page object")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := action.Topics(ctx, cfg, in)
	if err != nil {
		return fail(err)
	}
	if raw {
		fmt.Println(string(out))
		return 0
	}
	if err := printTopics(os.Stdout, out); err != nil {
		return fail(err)
	}
	return 0
}

// topicsPage is the hub's topic_list page.
type topicsPage struct {
	Topics []struct {
		TaskID  string `json:"task_id"`
		Subject string `json:"subject"`
		LastTS  string `json:"last_ts"`
	} `json:"topics"`
	Next string `json:"next"`
}

// printTopics writes one line per topic, then the next cursor if any.
func printTopics(w io.Writer, raw []byte) error {
	var p topicsPage
	if err := json.Unmarshal(raw, &p); err != nil {
		return fmt.Errorf("topics reply: %w", err)
	}
	for _, t := range p.Topics {
		at := t.LastTS
		if ts, err := time.Parse(time.RFC3339Nano, t.LastTS); err == nil {
			at = ts.UTC().Format("2006-01-02 15:04Z")
		}
		fmt.Fprintf(w, "%s  %s  %s\n", t.TaskID, at, t.Subject)
	}
	if p.Next != "" {
		fmt.Fprintf(w, "next: %s\n", p.Next)
	}
	return nil
}
