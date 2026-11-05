// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// Spec 169 row T5b, case C3b: the issues of the set, renumbered under <DST>.

type mvIssues struct {
	epic, child, stay Issue
	doc               string
}

func seedMoveIssues(t *testing.T, f mvFix) mvIssues {
	t.Helper()
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Second)
	pg := f.pg
	if _, err := pg.CreateIssueLabel(ctx, IssueLabel{TenantID: f.src, LabelID: "red-one", Name: "Red one", Color: "#ff0000", CreatedBy: f.both}, now); err != nil {
		t.Fatal(err)
	}
	var x mvIssues
	var err error
	x.epic, err = pg.CreateIssue(ctx, Issue{TenantID: f.src, Title: "epic", Kind: IssueKindEpic, TaskID: f.tA, Discussions: []string{f.tA}, CreatedBy: f.both}, now)
	if err != nil {
		t.Fatal(err)
	}
	x.child, err = pg.CreateIssue(ctx, Issue{TenantID: f.src, Title: "child", Parent: x.epic.Number, Labels: []string{"red-one"},
		TaskID: f.thread, Discussions: []string{f.thread}, CreatedBy: f.both}, now)
	if err != nil {
		t.Fatal(err)
	}
	x.stay, err = pg.CreateIssue(ctx, Issue{TenantID: f.src, Title: "stays", TaskID: f.tB, Discussions: []string{f.tB}, CreatedBy: f.both}, now)
	if err != nil {
		t.Fatal(err)
	}
	mvExec(t, pg, `UPDATE issues SET title = 'epic, renamed', updated_by = $3 WHERE tenant_id = $1 AND number = $2`, f.src, x.epic.Number, f.both)
	mvExec(t, pg, `INSERT INTO issue_opens (tenant_id, member_id, number, opened_at) VALUES ($1, $2, $3, $4)`, f.src, f.both, x.epic.Number, now)
	mvExec(t, pg, `INSERT INTO spec_sync_map (tenant_id, spec_path, spec_task_id, issue_number) VALUES ($1, 'csi-spl-doc/specs/001-x/tasks.md', 'T001', $2)`, f.src, x.child.Number)
	mvExec(t, pg, `INSERT INTO fleet_lanes (tenant_id, fleet, agent_id, agent_box, writer_box, state, topic, issue_key) VALUES ($1, 'f', 'c-100', 'box-a', 'box-a', 'live', 't-1', $2)`,
		f.src, planIssueKey(x.child.Prefix, x.child.Number))
	// SPL-4620: a lane placed from the epic names it in origin_issue (row T7g).
	mvExec(t, pg, `INSERT INTO fleet_lanes (tenant_id, fleet, agent_id, agent_box, writer_box, state, topic, issue_key, origin_issue) VALUES ($1, 'f', 'c-101', 'box-a', 'box-a', 'live', 't-2', $2, $3)`,
		f.src, planIssueKey(x.stay.Prefix, x.stay.Number), planIssueKey(x.epic.Prefix, x.epic.Number))
	return x
}

func TestApplyChannelMoveC3bIssues(t *testing.T) {
	f := seedMove(t)
	x := seedMoveIssues(t, f)
	pg := f.pg
	// <DST>'s counter is ahead of <SRC>'s numbers, so the numbers must change.
	mvExec(t, pg, `INSERT INTO issue_counters (tenant_id, prefix, last_number) VALUES ($1, 'DST', 100)
		ON CONFLICT (tenant_id) DO UPDATE SET prefix = 'DST', last_number = 100`, f.dst)
	eventsBefore := mvCount(t, pg, `SELECT count(*) FROM issue_events WHERE tenant_id = $1 AND number = $2`, f.src, x.epic.Number)
	if eventsBefore < 2 {
		t.Fatalf("seed: the epic has %d events, want created and changed", eventsBefore)
	}
	res := f.apply(t, f.req())
	if len(res.Binds.Numbers) != 2 {
		t.Fatalf("the set holds %v, want the epic and its child", res.Binds.Numbers)
	}
	oldEpic, oldChild := planIssueKey(x.epic.Prefix, x.epic.Number), planIssueKey(x.child.Prefix, x.child.Number)
	if res.NewKeys[oldEpic] != "DST-101" || res.NewKeys[oldChild] != "DST-102" {
		t.Fatalf("new keys %v", res.NewKeys)
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM issues WHERE tenant_id = $1 AND number = 102 AND parent_number = 101 AND 'red-one' = ANY(labels)`, f.dst); n != 1 {
		t.Error("the child did not follow its epic, or lost its label")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM issue_labels WHERE tenant_id = $1 AND label_id = 'red-one' AND name = 'Red one'`, f.dst); n != 1 {
		t.Error("the label was not created in <DST>")
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM issue_events WHERE tenant_id = $1 AND number = 101`, f.dst); n != eventsBefore {
		t.Errorf("the epic's history: %d events in <DST>, %d in <SRC> before (the insert trigger's own row must not add one)", n, eventsBefore)
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM issue_events e WHERE e.tenant_id = $1 AND e.number = 101 AND e.new_value = $2
		AND e.id = (SELECT min(id) FROM issue_events WHERE tenant_id = $1 AND number = 101)`, f.dst, "moved from "+oldEpic); n != 1 {
		t.Error("C12: the first event must carry the old key")
	}
	f.checkIssueChildren(t, x, oldChild)
}

func (f mvFix) checkIssueChildren(t *testing.T, x mvIssues, oldChild string) {
	t.Helper()
	pg := f.pg
	for _, c := range []struct {
		name, sql string
		args      []any
		want      int
	}{
		{"opens", `SELECT count(*) FROM issue_opens WHERE tenant_id = $1 AND number = 101`, []any{f.dst}, 1},
		{"discussions", `SELECT count(*) FROM issue_discussions WHERE tenant_id = $1 AND number = 102 AND task_id = $2`, []any{f.dst, f.thread}, 1},
		{"spec sync", `SELECT count(*) FROM spec_sync_map WHERE tenant_id = $1 AND issue_number = 102`, []any{f.dst}, 1},
		{"<SRC> issues", `SELECT count(*) FROM issues WHERE tenant_id = $1 AND number = ANY($2::int[])`, []any{f.src, []int{x.epic.Number, x.child.Number}}, 0},
		{"<SRC> events", `SELECT count(*) FROM issue_events WHERE tenant_id = $1 AND number = ANY($2::int[])`, []any{f.src, []int{x.epic.Number, x.child.Number}}, 0},
		{"<SRC> spec sync", `SELECT count(*) FROM spec_sync_map WHERE tenant_id = $1`, []any{f.src}, 0},
		{"the staying issue", `SELECT count(*) FROM issues WHERE tenant_id = $1 AND number = $2`, []any{f.src, x.stay.Number}, 1},
		{"fleet lane old key", `SELECT count(*) FROM fleet_lanes WHERE tenant_id = $1 AND issue_key = $2`, []any{f.src, oldChild}, 0},
		{"fleet lane new key", `SELECT count(*) FROM fleet_lanes WHERE tenant_id = $1 AND issue_key = 'DST-102'`, []any{f.src}, 1},
		{"fleet lane origin, new key", `SELECT count(*) FROM fleet_lanes WHERE tenant_id = $1 AND agent_id = 'c-101' AND origin_issue = 'DST-101'`, []any{f.src}, 1},
		{"fleet lane of a staying issue", `SELECT count(*) FROM fleet_lanes WHERE tenant_id = $1 AND agent_id = 'c-101' AND issue_key = $2`, []any{f.src, planIssueKey(x.stay.Prefix, x.stay.Number)}, 1},
		{"redirect", `SELECT count(*) FROM channel_move_redirects WHERE src_tenant_id = $1 AND kind = 'issue' AND old_ref = $2 AND new_ref = 'DST-102'`, []any{f.src, oldChild}, 1},
		{"<DST> counter", `SELECT last_number FROM issue_counters WHERE tenant_id = $1`, []any{f.dst}, 102},
	} {
		if n := mvCount(t, pg, c.sql, c.args...); n != c.want {
			t.Errorf("%s: %d, want %d", c.name, n, c.want)
		}
	}
}

// C3b, the shared row: a spec_sync_map row of a moved doc that a staying issue
// also needs makes plan refuse. CONTROL: without the check the move goes on
// and the staying issue has lost its spec link.
func TestApplyChannelMoveC3bSharedSpecSync(t *testing.T) {
	f := seedMove(t)
	x := seedMoveIssues(t, f)
	doc, _, err := f.pg.DocCreate(context.Background(), f.src, "spec doc", "", f.both)
	if err != nil {
		t.Fatal(err)
	}
	mvExec(t, f.pg, `INSERT INTO spec_sync_map (tenant_id, spec_path, spec_task_id, issue_number, qto_doc_id) VALUES ($1, 'csi-spl-doc/specs/001-x/tasks.md', 'T002', $2, $3::uuid)`, f.src, x.stay.Number, doc)
	req := f.req()
	req.RuleDoc = doc
	_, err = f.pg.ApplyChannelMove(context.Background(), req)
	if !errors.Is(err, ErrChannelMoveRefused) || !strings.Contains(err.Error(), "#T002") {
		t.Fatalf("got %v, want a refusal naming the row", err)
	}
	req = f.req()
	req.RuleDoc = doc
	req.noSharedCheck = true
	f.apply(t, req)
	if n := mvCount(t, f.pg, `SELECT count(*) FROM spec_sync_map WHERE tenant_id = ANY($1::text[]) AND spec_task_id = 'T002' AND issue_number = $2`, []string{f.src, f.dst}, x.stay.Number); n != 0 {
		t.Fatalf("CONTROL: the staying issue still has its link (%d), so the check guards nothing", n)
	}
}
