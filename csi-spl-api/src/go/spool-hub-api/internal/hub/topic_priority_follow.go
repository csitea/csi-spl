package hub

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The discussion's priority is the source (spec 150 section 3.4 item 4,
// SPL-4813; owner HUM-10, csitea b0f50875, msg ee3d6efc: "the lanes of the
// discussions and the issues and the lanes must be the same", msg f061e485:
// "I want as the user to be able to triage mostly based on discussions").
// An open issue follows the highest (lowest number) priority SET on its
// linked discussions: a stored topic_priorities row, a set 3 too. The
// workspace's default discussion (store.IssueDiscussionDefault) does not
// count: an issue linked there was not born of it. An issue with no set
// discussion keeps its own priority. A lane shows the highest of its issues
// (lanePrio), so it follows with them; a queued ask already reads its
// discussion's priority (askPositions).
//
// A topic lives in one workspace, but an issue may link it from another:
// the fleet files every lane's issue in the operator workspace, linking the
// owner's topic in his own workspace (csitea 269d405d's lane issue is t1's
// SPL-4637). So the operator workspace's issues also read the set
// priorities of the other workspaces' topics.
//
// Two paths apply it: PUT /v1/topics/{task_id}/priority at once, for the
// issues linking that topic, and the agent issue op prio-sync, every issue
// of the workspace, which the 5-min cron calls (do_spl_topic_prio_sync): the
// safety net for a priority set before this rule or a failed apply.
//
// The last prio change wins, both ways (spec 150 3.4 item 4 v1.3, SPL-5223;
// owner HUM-10, t1 20da7236, msgs 76af2576 and 01c1f25e): an issue whose own
// change (issues.priority_set_at, rdb 0273) is as new as every set row of its
// discussions or newer is never moved by them; it sets them instead
// (topic_priority_spread.go), and their other issues follow.

// prioChangeJSON is one issue moved (or, on a dry run, to move): its
// workspace and key, the discussion whose priority it takes, the old and the
// new value.
type prioChangeJSON struct {
	Workspace string `json:"workspace"`
	Key       string `json:"key"`
	Topic     string `json:"topic"`
	From      int    `json:"from"`
	To        int    `json:"to"`
}

// prioFollow is one run's answer: the workspaces swept, the changes, the
// discussions set by a newer issue change (spread) and the open issues that
// link no set discussion (they keep their own priority).
type prioFollow struct {
	Workspaces []string         `json:"workspaces"`
	Changes    []prioChangeJSON `json:"changes"`
	Spread     []prioSpreadJSON `json:"spread"`
	Unset      int              `json:"unset"`
	Applied    bool             `json:"applied"`
}

// prioRun is one apply: the issues of tenant to follow (numbers nil: every
// one), the workspaces whose topics' priorities count besides tenant's own
// (lookIn), who writes, and whether it writes (apply false only computes).
// spread lets an issue's newer own change set its discussions: the update
// path and the sweep, never the follow a spread starts (no loop).
type prioRun struct {
	tenant  string
	numbers []int
	lookIn  []string
	by      string
	apply   bool
	spread  bool
}

// prioView is what one run reads: its issues, their links, the set rows of
// the linked discussions (the newest per topic) and the issues' own stamps.
type prioView struct {
	links  map[int][]store.IssueDiscussion
	set    map[string]store.TopicPriority
	issues []store.Issue
	own    map[int]time.Time
}

// ownNewer: issue n's own change is as new as every set row of its
// discussions or newer, so they never move it (a tie goes to the issue: its
// spread writes the topics at its own time).
func (v prioView) ownNewer(n int) bool {
	at, ok := v.own[n]
	if !ok {
		return false
	}
	for _, l := range v.links[n] {
		if p, set := v.set[strings.ToLower(l.TaskID)]; set && l.OriginTenant == "" && p.SetAt.After(at) {
			return false
		}
	}
	return true
}

// readPrioView reads one run's view.
func (s *Server) readPrioView(ctx context.Context, run prioRun) (prioView, error) {
	var v prioView
	ds, okD := s.o.Store.(store.IssueDiscussions)
	ps, okP := s.o.Store.(store.TopicPriorityStore)
	os, okO := s.o.Store.(store.IssuePrioritySets)
	is, ie := s.issueStore()
	if !okD || !okP || !okO || ie != nil {
		return v, errors.New("this store keeps no issue discussions or topic priorities")
	}
	var err error
	if v.links, err = ds.IssueDiscussionLinks(ctx, run.tenant, run.numbers); err != nil {
		return v, err
	}
	if v.set, err = linkedSetPriorities(ctx, ps, run.tenant, run.lookIn, v.links); err != nil {
		return v, err
	}
	if v.issues, err = followIssues(ctx, is, run.tenant, run.numbers); err != nil {
		return v, err
	}
	v.own, err = os.IssuePrioritySetAt(ctx, run.tenant, run.numbers)
	return v, err
}

// followDiscussionPriority applies the rule to one run: first the spreads
// of the newer issue changes (run.spread), then every other open issue
// follows its discussions.
func (s *Server) followDiscussionPriority(ctx context.Context, run prioRun) (prioFollow, error) {
	tenant, apply := run.tenant, run.apply
	out := prioFollow{Workspaces: []string{tenant}, Changes: []prioChangeJSON{}, Spread: []prioSpreadJSON{}, Applied: apply}
	is, ie := s.issueStore()
	v, err := s.readPrioView(ctx, run)
	if err != nil || ie != nil {
		return out, err
	}
	if run.spread {
		if out.Spread, err = s.spreadNewerIssues(ctx, run, v); err != nil {
			return out, err
		}
		if apply && len(out.Spread) > 0 {
			if v, err = s.readPrioView(ctx, run); err != nil {
				return out, err
			}
		}
	}
	for _, i := range v.issues {
		if issueResolved(i.Status) || v.ownNewer(i.Number) {
			continue
		}
		to, topic := bestSetPriority(v.links[i.Number], v.set)
		if to == 0 {
			out.Unset++
			continue
		}
		if to == i.Priority {
			continue
		}
		if apply {
			if err := s.applyIssuePriority(ctx, is, tenant, i.Number, to, run.by); err != nil {
				return out, err
			}
		}
		out.Changes = append(out.Changes, prioChangeJSON{Workspace: tenant, Key: store.IssueKey(i.Prefix, i.Number), Topic: topic, From: i.Priority, To: to})
	}
	return out, nil
}

// linkedSetPriorities is the set row of every discussion links names, read
// in tenant and in each of lookIn (the newest where two answer: the last
// change wins), the default discussion left out; absent = not set.
func linkedSetPriorities(ctx context.Context, ps store.TopicPriorityStore, tenant string, lookIn []string, links map[int][]store.IssueDiscussion) (map[string]store.TopicPriority, error) {
	def := strings.ToLower(store.IssueDiscussionDefault(tenant))
	seen := map[string]bool{}
	tasks := []string{}
	for _, ls := range links {
		for _, l := range ls {
			k := strings.ToLower(l.TaskID)
			if k != def && !seen[k] && l.OriginTenant == "" {
				seen[k] = true
				tasks = append(tasks, k)
			}
		}
	}
	out := map[string]store.TopicPriority{}
	if len(tasks) == 0 {
		return out, nil
	}
	for _, t := range append([]string{tenant}, lookIn...) {
		got, err := ps.SetTopicPriorityRows(ctx, t, tasks)
		if err != nil {
			return nil, err
		}
		for k, p := range got {
			if q, ok := out[k]; !ok || p.SetAt.After(q.SetAt) {
				out[k] = p
			}
		}
	}
	return out, nil
}

// bestSetPriority is the highest set priority among ls and the discussion
// that sets it (the oldest link of a tie); 0 when none is set.
func bestSetPriority(ls []store.IssueDiscussion, set map[string]store.TopicPriority) (int, string) {
	best, topic := 0, ""
	for _, l := range ls {
		if p, ok := set[strings.ToLower(l.TaskID)]; ok && l.OriginTenant == "" && (best == 0 || p.Priority < best) {
			best, topic = p.Priority, strings.ToLower(l.TaskID)
		}
	}
	return best, topic
}

// followIssues is the live issues the run reads: every one (numbers nil),
// else those of numbers that still exist and are not archived, ascending.
func followIssues(ctx context.Context, is store.Issues, tenant string, numbers []int) ([]store.Issue, error) {
	var out []store.Issue
	if numbers == nil {
		all, err := is.ListIssues(ctx, tenant)
		if err != nil {
			return nil, err
		}
		out = all
	}
	for _, n := range numbers {
		i, err := is.GetIssue(ctx, tenant, n)
		if errors.Is(err, store.ErrNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		out = append(out, i)
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Number < out[b].Number })
	return out, nil
}

// applyIssuePriority writes one issue's new priority as by (its history
// names who set the discussion's) and tells the open tabs.
func (s *Server) applyIssuePriority(ctx context.Context, is store.Issues, tenant string, number, prio int, by string) error {
	i, err := is.UpdateIssue(ctx, tenant, number, store.IssuePatch{Priority: &prio}, by, s.o.Now())
	if err != nil {
		return err
	}
	s.fanoutIssue(ctx, tenant, map[string]any{"type": issueFrame, "op": "update", "issue": toIssueJSON(i, s.storeGetter(ctx, tenant))})
	return nil
}

// followTopicPriority is the PUT's apply, for the issues linking task in
// tenant and in the operator workspace (the fleet's lane issues), whose run
// reads every workspace's topics, as the sweep's does. A failure is logged, never the PUT's:
// the 5-min sweep applies it again.
func (s *Server) followTopicPriority(ctx context.Context, tenant, task, by string) {
	if strings.EqualFold(task, store.IssueDiscussionDefault(tenant)) {
		return
	}
	runs := []prioRun{{tenant: tenant, by: by, apply: true}}
	if op, err := s.operatorTenant(ctx); err == nil && op != "" {
		// the operator run reads what the sweep reads, or the two disagree
		// and the issue's priority flips every 5 min
		lookIn := []string{tenant}
		ws, werr := s.prioSyncWorkspaces(ctx, op)
		if werr != nil {
			s.o.Log.Warn().Err(werr).Str("tenant", op).Str("task", task).Msg("issue priority follow: workspaces not read, this one only")
		} else if len(ws) > 0 {
			lookIn = ws[1:]
		}
		if op == tenant {
			runs[0].lookIn = lookIn
		} else {
			runs = append(runs, prioRun{tenant: op, lookIn: lookIn, by: by, apply: true})
		}
	}
	for _, run := range runs {
		if err := s.followTopicIn(ctx, run, task); err != nil {
			s.o.Log.Error().Err(err).Str("tenant", run.tenant).Str("task", task).Msg("issue priority follow")
		}
	}
}

// followTopicIn applies run to its workspace's issues that link task.
func (s *Server) followTopicIn(ctx context.Context, run prioRun, task string) error {
	is, ie := s.issueStore()
	if ie != nil {
		return nil
	}
	nums, err := is.IssueNumbersByDiscussion(ctx, run.tenant, task)
	if err != nil || len(nums) == 0 {
		return err
	}
	run.numbers = nums
	res, err := s.followDiscussionPriority(ctx, run)
	for _, c := range res.Changes {
		s.o.Log.Info().Str("tenant", run.tenant).Str("task", task).Str("issue", c.Key).Int("from", c.From).Int("to", c.To).Msg("issue priority follows its discussion")
	}
	return err
}

// agentPrioSync is the agent issue op prio-sync: every issue of the
// session's workspace, and from the operator workspace every workspace of
// the hub (the fleet's desks sit there only; each workspace takes only its
// own discussions' priorities, so it moves nothing a member there did not
// set). A dry run unless the query says dry_run=0.
func (s *Server) agentPrioSync(ctx context.Context, tenant, as, query string) (any, *issueErr) {
	q, err := url.ParseQuery(query)
	if err != nil {
		return nil, badIssue("query must be URL query form, e.g. dry_run=0")
	}
	apply := q.Get("dry_run") == "0"
	tenants, err := s.prioSyncWorkspaces(ctx, tenant)
	all := prioFollow{Workspaces: tenants, Changes: []prioChangeJSON{}, Spread: []prioSpreadJSON{}, Applied: apply}
	for _, t := range tenants {
		if err != nil {
			break
		}
		run := prioRun{tenant: t, by: as, apply: apply, spread: true}
		if t == tenant && len(tenants) > 1 { // the operator workspace: every workspace's topics count
			run.lookIn = tenants[1:]
		}
		var res prioFollow
		res, err = s.followDiscussionPriority(ctx, run)
		all.Changes, all.Unset = append(all.Changes, res.Changes...), all.Unset+res.Unset
		all.Spread = append(all.Spread, res.Spread...)
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("issue priority sync")
		return nil, &issueErr{http.StatusServiceUnavailable, "unavailable", "the priorities could not be applied; try again"}
	}
	return all, nil
}

// prioSyncWorkspaces is tenant alone, or every live workspace when tenant
// is the operator workspace (sorted, tenant first).
func (s *Server) prioSyncWorkspaces(ctx context.Context, tenant string) ([]string, error) {
	op, err := s.operatorTenant(ctx)
	ws, ok := s.o.Store.(store.OperatorWorkspaces)
	if err != nil || op != tenant || !ok {
		return []string{tenant}, err
	}
	rows, err := ws.ListWorkspaces(ctx)
	if err != nil {
		return nil, err
	}
	out := []string{tenant}
	for _, w := range rows {
		if w.ID != tenant && w.ArchivedAt.IsZero() {
			out = append(out, w.ID)
		}
	}
	sort.Strings(out[1:])
	return out, nil
}
