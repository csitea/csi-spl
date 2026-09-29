package store

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// rdb 0049 (SPL-18) on rows that break the epic rule, inserted raw as the
// operator (the store would refuse them): an orphan, an issue under a
// non-epic, an epic with a parent, a tenant with no "random" epic and one
// that has it. The file's SQL runs again in the operator scope - it is
// idempotent in effect - and every issue ends up under an epic.
func TestMigration0049EpicBackfill(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0049_issue_epics.sql"))
	if err != nil {
		t.Fatal(err)
	}
	a, b := uid("m49a-"), uid("m49b-")
	for _, tn := range []string{a, b} {
		if err := pg.CreateTenant(ctx, Tenant{ID: tn, RootPubKey: pubkey()}); err != nil {
			t.Fatal(err)
		}
	}
	seed := func(tn string, n int, title string, labels []string, parent any) {
		t.Helper()
		if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `INSERT INTO issue_counters (tenant_id, last_number) VALUES ($1, $2)
				ON CONFLICT (tenant_id) DO UPDATE SET last_number = GREATEST(issue_counters.last_number, $2)`, tn, n); err != nil {
				return err
			}
			if len(labels) > 0 {
				if _, err := tx.Exec(ctx, `INSERT INTO issue_labels (tenant_id, label_id, name) VALUES ($1, 'epic', 'epic') ON CONFLICT DO NOTHING`, tn); err != nil {
					return err
				}
			}
			_, err := tx.Exec(ctx, `INSERT INTO issues (tenant_id, number, title, labels, parent_number, task_id, created_by, updated_by)
				VALUES ($1, $2, $3, $4, $5, $6, 'HUM-1', 'HUM-1')`, tn, n, title, labels, parent, uuid4())
			return err
		}); err != nil {
			t.Fatal(err)
		}
	}
	// a: no epic at all; 1 orphan, 2 under the non-epic 1.
	seed(a, 1, "orphan", []string{}, nil)
	seed(a, 2, "under a non-epic", []string{}, 1)
	// b: an epic "Random" with a parent, a "random" epic, an orphan, one fine.
	seed(b, 1, "other epic", []string{"epic"}, nil)
	seed(b, 2, "Random", []string{"epic"}, nil)
	seed(b, 3, "orphan", []string{}, nil)
	seed(b, 4, "fine", []string{}, 1)
	seed(b, 5, "epic with a parent", []string{"epic"}, 1)
	// Before 0049 such a row stays editable: an update that touches neither
	// the parent nor the labels skips the epic rule; one that does meets it.
	if _, err := pg.UpdateIssue(ctx, a, 1, IssuePatch{Title: ptr("orphan, still editable")}, "HUM-1", time.Now()); err != nil {
		t.Fatalf("title edit on a pre-rule orphan: %v", err)
	}
	// Since W16 (spec 047) row 1 is a lone level-2 issue, so row 2 under it
	// is a valid subtask and the rule lets the edit through.
	if got, err := pg.UpdateIssue(ctx, a, 2, IssuePatch{Labels: &[]string{}}, "HUM-1", time.Now()); err != nil || got.Level != 3 {
		t.Fatalf("label edit on a row under a lone issue: %+v %v", got, err)
	}
	run := func() {
		t.Helper()
		if err := pg.asOperator(ctx, func(tx pgx.Tx) error { _, err := tx.Exec(ctx, string(raw)); return err }); err != nil {
			t.Fatalf("0049: %v", err)
		}
		// rdb 0053 ran after 0049 on every database: its data step makes the
		// labelled epics kind epic.
		if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE issues SET kind = 'epic' WHERE 'epic' = ANY (labels)`)
			return err
		}); err != nil {
			t.Fatalf("0053 data step: %v", err)
		}
	}
	run()
	run() // CONTROL: a second pass changes nothing
	rows := map[string]map[int]Issue{}
	for _, tn := range []string{a, b} {
		list, err := pg.ListIssues(ctx, tn)
		if err != nil {
			t.Fatal(err)
		}
		rows[tn] = map[int]Issue{}
		for _, i := range list {
			rows[tn][i.Number] = i
		}
	}
	// a: a new "random" epic (3) holds 1 and 2; nothing else created.
	if len(rows[a]) != 3 || !rows[a][3].IsEpic() || rows[a][3].Title != "random" || rows[a][1].Parent != 3 || rows[a][2].Parent != 3 {
		t.Fatalf("tenant a: %+v", rows[a])
	}
	// b: the existing "Random" (2) takes the orphan; 4 stays under 1; the
	// epic 5 loses its parent; no epic was created.
	if len(rows[b]) != 5 || rows[b][3].Parent != 2 || rows[b][4].Parent != 1 || rows[b][5].Parent != 0 || rows[b][2].Parent != 0 {
		t.Fatalf("tenant b: %+v", rows[b])
	}
	for tn, list := range rows {
		for n, i := range list {
			if !i.IsEpic() && (i.Parent == 0 || !list[i.Parent].IsEpic()) {
				t.Errorf("%s SPL-%d has no epic parent after 0049", tn, n)
			}
		}
	}
	if ls, _ := pg.ListIssueLabels(ctx, a); len(ls) != 1 || ls[0].LabelID != "epic" {
		t.Fatalf("tenant a labels: %+v", ls)
	}
}
