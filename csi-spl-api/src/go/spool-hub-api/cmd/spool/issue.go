package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

const issueUsage = `usage: spool issue <list|get|create|update|comment|label|delete> --as <AGENT> [flags]
  list    [--epic SPL-1,..] [--kind epic|issue] [--status s,..] [--priority n,..] [--level n,..] [--assignee id|me|none,..] [--label l,..]
          [--deadline-before T] [--deadline-after T] [--sort priority|level|deadline|updated|created]
  get     --ref SPL-3
  create  --title T  --epic SPL-1 | --parent SPL-3 (subtask) | --kind epic|feature  [--description D | --description-file F] [--status S]
          [--priority 1-5] [--level 1-3] [--assignee ID] [--labels a,b] [--deadline 2026-10-01T15:00:00Z]
  update  --ref SPL-3 [any create flag; only the flags given change; "" clears]
  comment --ref SPL-3 --body TEXT | --body-file F
  label   --name N [--color #rrggbb]
  delete  --ref SPL-3 (only its creator; a soft delete)`

// cmdIssue is specs/039 FR-008: an agent files and advances its work as
// issues. The answer object is printed as JSON.
func cmdIssue(cfg *config.Config, args []string) int {
	if len(args) == 0 || strings.HasPrefix(args[0], "-") {
		fmt.Fprintln(os.Stderr, issueUsage)
		return 1
	}
	in, err := parseIssueArgs(args[0], args[1:])
	if err == errIssueFlags {
		return 1
	}
	if err != nil {
		return fail(err)
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := action.Issue(ctx, cfg, in)
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(out))
	return 0
}

var errIssueFlags = errors.New("bad flags")

// issueFlags are every flag of every issue op; each op reads its own.
type issueFlags struct {
	as, ref, title, desc, descFile, status, priority, level, assignee, labels, label string
	deadline, parent, epic, kind, before, after, sortBy, body, bodyFile, name, color string
	set                                                                              map[string]bool // the flags given
}

func newIssueFlagSet(op string, f *issueFlags) *flag.FlagSet {
	fs := flag.NewFlagSet("issue "+op, flag.ContinueOnError)
	for _, d := range []struct {
		p          *string
		name, help string
	}{
		{&f.as, "as", "the acting agent id (one this box announced)"},
		{&f.ref, "ref", "issue key, e.g. SPL-3"},
		{&f.title, "title", "title"},
		{&f.desc, "description", "description (markdown)"},
		{&f.descFile, "description-file", "read the description from this file"},
		{&f.status, "status", "eval|todo|wip|diss|blocked|onhold|qas|done (01-eval .. 09-done; list: comma list)"},
		{&f.priority, "priority", "prio 1 (highest) .. 5 (lowest) (list: comma list)"},
		{&f.level, "level", "1 epic or feature, 2 issue, 3 subtask: derived from the tree, only checked (list: comma list)"},
		{&f.assignee, "assignee", "member HUM-* or agent id; list also takes me and none"},
		{&f.labels, "labels", "label ids, comma separated"},
		{&f.label, "label", "list: label ids, comma separated"},
		{&f.deadline, "deadline", "RFC 3339 with a zone; empty clears on update"},
		{&f.parent, "parent", "the parent: an epic / feature, or a level-2 issue (the new one is its subtask); list: comma list"},
		{&f.epic, "epic", "the parent epic's key (optional since W16: an issue may stand alone); list: comma list"},
		{&f.kind, "kind", "epic | feature | issue (create / update); list: epic,feature,issue,subtask"},
		{&f.before, "deadline-before", "list: RFC 3339"},
		{&f.after, "deadline-after", "list: RFC 3339"},
		{&f.sortBy, "sort", "list: priority|level|deadline|updated|created"},
		{&f.body, "body", "comment text"},
		{&f.bodyFile, "body-file", "read the comment from this file"},
		{&f.name, "name", "label name"},
		{&f.color, "color", "label colour #rrggbb"},
	} {
		fs.StringVar(d.p, d.name, "", d.help)
	}
	return fs
}

// parseIssueArgs turns `spool issue <op> [flags]` into the request for the
// hub; errIssueFlags when the flags do not parse (the flag package has
// already said why).
func parseIssueArgs(op string, args []string) (action.IssueArgs, error) {
	f := &issueFlags{set: map[string]bool{}}
	fs := newIssueFlagSet(op, f)
	if err := fs.Parse(args); err != nil {
		return action.IssueArgs{}, errIssueFlags
	}
	fs.Visit(func(fl *flag.Flag) { f.set[fl.Name] = true })
	in := action.IssueArgs{Op: op, As: f.as, Ref: f.ref}
	var err error
	switch op {
	case "list":
		in.Query = f.listQuery()
	case "create", "update":
		in.Issue, err = f.issueObject()
	case "comment":
		in.Body, err = f.commentBody()
	case "label":
		in.Issue, _ = json.Marshal(map[string]string{"name": f.name, "color": f.color})
	}
	if err != nil {
		return action.IssueArgs{}, err
	}
	return in, nil
}

// listQuery is the list filter as a query string; empty flags are left out.
func (f *issueFlags) listQuery() string {
	q := url.Values{}
	for k, v := range map[string]string{"status": f.status, "priority": f.priority, "level": f.level, "assignee": f.assignee,
		"label": f.label, "deadline_before": f.before, "deadline_after": f.after, "sort": f.sortBy, "epic": f.epic, "kind": f.kind, "parent": f.parent} {
		if v != "" {
			q.Set(k, v)
		}
	}
	return q.Encode()
}

// issueObject is the create / update body: only the flags given, so an
// update changes those and "" clears.
func (f *issueFlags) issueObject() (json.RawMessage, error) {
	obj := map[string]any{}
	if f.set["description-file"] {
		b, err := os.ReadFile(f.descFile)
		if err != nil {
			return nil, err
		}
		f.desc, f.set["description"] = string(b), true
	}
	for key, v := range map[string]string{"title": f.title, "description": f.desc, "status": f.status,
		"assignee": f.assignee, "deadline": f.deadline, "parent": f.parent, "epic": f.epic, "kind": f.kind} {
		if f.set[key] {
			obj[key] = v
		}
	}
	for key, v := range map[string]string{"priority": f.priority, "level": f.level} {
		if f.set[key] {
			n, err := strconv.Atoi(v)
			if err != nil {
				return nil, fmt.Errorf("--%s must be a number", key)
			}
			obj[key] = n
		}
	}
	if f.set["labels"] {
		ls := []string{}
		for _, l := range strings.Split(f.labels, ",") {
			if l = strings.TrimSpace(l); l != "" {
				ls = append(ls, l)
			}
		}
		obj["labels"] = ls
	}
	return json.Marshal(obj)
}

// commentBody is --body, or the --body-file contents when that is given.
func (f *issueFlags) commentBody() (string, error) {
	if !f.set["body-file"] {
		return f.body, nil
	}
	b, err := os.ReadFile(f.bodyFile)
	return string(b), err
}
