package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

const issueUsage = `usage: spool issue <list|get|create|update|comment|label> --as <AGENT> [flags]
  list    [--epic SPL-1,..] [--kind epic|issue] [--status s,..] [--priority n,..] [--level n,..] [--assignee id|me|none,..] [--label l,..]
          [--deadline-before T] [--deadline-after T] [--sort priority|level|deadline|updated|created]
  get     --ref SPL-3
  create  --title T  --epic SPL-1 | --parent SPL-3 (subtask) | --kind epic|feature  [--description D | --description-file F] [--status S]
          [--priority 1-5] [--level 0-5] [--assignee ID] [--labels a,b] [--deadline 2026-10-01T15:00:00Z]
  update  --ref SPL-3 [any create flag; only the flags given change; "" clears]
  comment --ref SPL-3 --body TEXT | --body-file F
  label   --name N [--color #rrggbb]`

// cmdIssue is specs/039 FR-008: an agent files and advances its work as
// issues. The answer object is printed as JSON.
func cmdIssue(cfg *config.Config, args []string) int {
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		fmt.Fprintln(os.Stderr, issueUsage)
		return 1
	}
	op := args[0]
	fs := flag.NewFlagSet("issue "+op, flag.ContinueOnError)
	as := fs.String("as", "", "the acting agent id (one this box announced)")
	ref := fs.String("ref", "", "issue key, e.g. SPL-3")
	title := fs.String("title", "", "title")
	desc := fs.String("description", "", "description (markdown)")
	descFile := fs.String("description-file", "", "read the description from this file")
	status := fs.String("status", "", "eval|todo|wip|diss|qas|done (01-eval .. 09-done; list: comma list)")
	priority := fs.String("priority", "", "prio 1 (highest) .. 5 (lowest) (list: comma list)")
	level := fs.String("level", "", "0 none, 1 XS .. 5 XL (list: comma list)")
	assignee := fs.String("assignee", "", "member HUM-* or agent id; list also takes me and none")
	labels := fs.String("labels", "", "label ids, comma separated")
	label := fs.String("label", "", "list: label ids, comma separated")
	deadline := fs.String("deadline", "", "RFC 3339 with a zone; empty clears on update")
	parent := fs.String("parent", "", "the parent: an epic / feature, or a level-2 issue (the new one is its subtask); list: comma list")
	epic := fs.String("epic", "", "the parent epic's key (SPL-18: every issue has one); list: comma list")
	kind := fs.String("kind", "", "epic | feature | issue (create / update); list: epic,feature,issue,subtask")
	before := fs.String("deadline-before", "", "list: RFC 3339")
	after := fs.String("deadline-after", "", "list: RFC 3339")
	sortBy := fs.String("sort", "", "list: priority|level|deadline|updated|created")
	body := fs.String("body", "", "comment text")
	bodyFile := fs.String("body-file", "", "read the comment from this file")
	name := fs.String("name", "", "label name")
	color := fs.String("color", "", "label colour #rrggbb")
	if err := fs.Parse(args[1:]); err != nil {
		return 1
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	in := action.IssueArgs{Op: op, As: *as, Ref: *ref}
	switch op {
	case "list":
		q := url.Values{}
		for k, v := range map[string]string{"status": *status, "priority": *priority, "level": *level, "assignee": *assignee,
			"label": *label, "deadline_before": *before, "deadline_after": *after, "sort": *sortBy, "epic": *epic, "kind": *kind, "parent": *parent} {
			if v != "" {
				q.Set(k, v)
			}
		}
		in.Query = q.Encode()
	case "create", "update":
		obj := map[string]any{}
		if set["description-file"] {
			b, err := os.ReadFile(*descFile)
			if err != nil {
				return fail(err)
			}
			*desc, set["description"] = string(b), true
		}
		for flagName, key := range map[string]string{"title": "title", "description": "description", "status": "status",
			"assignee": "assignee", "deadline": "deadline", "parent": "parent", "epic": "epic", "kind": "kind"} {
			if set[flagName] {
				obj[key] = map[string]string{"title": *title, "description": *desc, "status": *status,
					"assignee": *assignee, "deadline": *deadline, "parent": *parent, "epic": *epic, "kind": *kind}[flagName]
			}
		}
		for flagName, v := range map[string]string{"priority": *priority, "level": *level} {
			if set[flagName] {
				n, err := strconv.Atoi(v)
				if err != nil {
					return fail(fmt.Errorf("--%s must be a number", flagName))
				}
				obj[flagName] = n
			}
		}
		if set["labels"] {
			ls := []string{}
			for _, l := range strings.Split(*labels, ",") {
				if l = strings.TrimSpace(l); l != "" {
					ls = append(ls, l)
				}
			}
			obj["labels"] = ls
		}
		in.Issue, _ = json.Marshal(obj)
	case "comment":
		in.Body = *body
		if set["body-file"] {
			b, err := os.ReadFile(*bodyFile)
			if err != nil {
				return fail(err)
			}
			in.Body = string(b)
		}
	case "label":
		in.Issue, _ = json.Marshal(map[string]string{"name": *name, "color": *color})
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	out, err := action.Issue(ctx, cfg, in)
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}
