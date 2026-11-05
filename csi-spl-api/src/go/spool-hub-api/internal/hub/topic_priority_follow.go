package hub

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"sort"
	"strings"

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

// prioFollow is one run's answer: the workspaces swept, the changes and the
// open issues that link no set discussion (they keep their own priority).
type prioFollow struct {
	Workspaces []string         `json:"workspaces"`
	Changes    []prioChangeJSON `json:"changes"`
	Unset      int              `json:"unset"`
	Applied    bool             `json:"applied"`
}

// prioRun is one apply: the issues of tenant to follow (numbers nil: every
// one), the workspaces whose topics' priorities count besides tenant's own
// (lookIn), who writes, and whether it writes (apply false only computes).
type prioRun struct {
	tenant  string
	numbers []int
	lookIn  []string
	by      string
	apply   bool
}

// followDiscussionPriority applies the rule to one run.
func (s *Server) followDiscussionPriority(ctx context.Context, run prioRun) (prioFollow, error) {
	tenant, apply := run.tenant, run.apply
	out := prioFollow{Workspaces: []string{tenant}, Changes: []prioChangeJSON{}, Applied: apply}
	ds, okD := s.o.Store.(store.IssueDiscussions)
	ps, okP := s.o.Store.(store.TopicPriorityStore)
	is, ie := s.issueStore()
	if !okD || !okP || ie != nil {
		return out, errors.New("this store keeps no issue discussions or topic priorities")
	}
	links, err := ds.IssueDiscussionLinks(ctx, tenant, run.numbers)
	if err != nil {
		return out, err
	}
	set, err := linkedSetPriorities(ctx, ps, tenant, run.lookIn, links)
	if err != nil {
		return out, err
	}
	issues, err := followIssues(ctx, is, tenant, run.numbers)
	if err != nil {
		return out, err
	}
	for _, i := range issues {
		if issueResolved(i.Status) {
			continue
		}
		to, topic := bestSetPriority(links[i.Number], set)
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

// linkedSetPriorities is the set priority of every discussion links names,
// read in tenant and in each of lookIn (the highest where two answer), the
// default discussion left out; absent = not set.
func linkedSetPriorities(ctx context.Context, ps store.TopicPriorityStore, tenant string, lookIn []string, links map[int][]store.IssueDiscussion) (map[string]int, error) {
	def := strings.ToLower(store.IssueDiscussionDefault(tenant))
	seen := map[string]bool{}
	tasks := []string{}
	for _, ls := range links {
		for _, l := range ls {
			k := strings.ToLower(l.TaskID)
			if k != def && !seen[k] {
				seen[k] = true
				tasks = append(tasks, k)
			}
		}
	}
	out := map[string]int{}
	if len(tasks) == 0 {
		return out, nil
	}
	for _, t := range append([]string{tenant}, lookIn...) {
		got, err := ps.SetTopicPriorities(ctx, t, tasks)
		if err != nil {
			return nil, err
		}
		for k, p := range got {
			if q, ok := out[k]; !ok || p < q {
				out[k] = p
			}
		}
	}
	return out, nil
}

// bestSetPriority is the highest set priority among ls and the discussion
// that sets it (the oldest link of a tie); 0 when none is set.
func bestSetPriority(ls []store.IssueDiscussion, set map[string]int) (int, string) {
	best, topic := 0, ""
	for _, l := range ls {
		if p, ok := set[strings.ToLower(l.TaskID)]; ok && (best == 0 || p < best) {
			best, topic = p, strings.ToLower(l.TaskID)
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
		if ws, werr := s.prioSyncWorkspaces(ctx, op); werr == nil && len(ws) > 0 {
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
	all := prioFollow{Workspaces: tenants, Changes: []prioChangeJSON{}, Applied: apply}
	for _, t := range tenants {
		if err != nil {
			break
		}
		run := prioRun{tenant: t, by: as, apply: apply}
		if t == tenant && len(tenants) > 1 { // the operator workspace: every workspace's topics count
			run.lookIn = tenants[1:]
		}
		var res prioFollow
		res, err = s.followDiscussionPriority(ctx, run)
		all.Changes, all.Unset = append(all.Changes, res.Changes...), all.Unset+res.Unset
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
