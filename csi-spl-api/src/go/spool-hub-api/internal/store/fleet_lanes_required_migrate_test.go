package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

// rdb 0264 (SPL-4799; owner HUM-10 t1 0c2d08a2, msgs 80bee509 and
// 937e89a4): fleet_lanes.topic and .issue_key accept no missing value, and
// the rows that had none read 'unknown'. Postgres only.
//
// "Before" is the table as 0221 left it: DEFAULT the empty string on both columns, no
// topic CHECK, the 0221 issue_key CHECK (re-added NOT VALID so the rows
// other tests committed are not scanned). Inside one rolled-back
// transaction:
//   - before (the red control, n=3): an insert that leaves out topic and
//     issue_key is stored with the empty string; so are an explicit empty
//     topic and an empty issue_key.
//   - 0264 applied: those three rows read 'unknown' in both columns (n=3).
//   - after (n=3): the same three inserts are refused: 23502 on the
//     missing columns, 23514 fleet_lanes_topic_set_check on an empty
//     topic, 23514 fleet_lanes_issue_key_check on an empty issue_key.
//   - 0264 applied a second time changes nothing (idempotent).
const lanesRequiredFile = "0264_fleet_lanes_topic_issue_required.sql"

const lanesRequiredBefore = `ALTER TABLE fleet_lanes ALTER COLUMN topic SET DEFAULT '';
ALTER TABLE fleet_lanes ALTER COLUMN issue_key SET DEFAULT '';
ALTER TABLE fleet_lanes DROP CONSTRAINT IF EXISTS fleet_lanes_topic_set_check;
ALTER TABLE fleet_lanes DROP CONSTRAINT IF EXISTS fleet_lanes_issue_key_check;
ALTER TABLE fleet_lanes ADD CONSTRAINT fleet_lanes_issue_key_check
    CHECK (issue_key = '' OR issue_key ~ '^[A-Z][A-Z0-9]{1,9}-[0-9]{1,9}$') NOT VALID`

func TestFleetLanesTopicIssueRequired0264(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), lanesRequiredFile))
	if err != nil {
		t.Fatal(err)
	}
	tenant := newTenant(t, pg)

	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	exec := func(what, q string, args ...any) {
		t.Helper()
		if _, err := tx.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", what, err)
		}
	}
	// try runs one insert under a savepoint: "" stored, else SQLSTATE/constraint.
	try := func(q string) string {
		t.Helper()
		sp, err := tx.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = sp.Exec(ctx, q, tenant); err == nil {
			if err := sp.Commit(ctx); err != nil {
				t.Fatal(err)
			}
			return ""
		}
		sp.Rollback(ctx) //nolint:errcheck
		var pe *pgconn.PgError
		if !errors.As(err, &pe) {
			t.Fatalf("%s: %v", q, err)
		}
		return pe.Code + "/" + pe.ConstraintName
	}
	ins := func(agent, cols, vals string) string {
		return `INSERT INTO fleet_lanes (tenant_id, fleet, agent_id, agent_box, state, writer_box` + cols + `)
			VALUES ($1, 'f260', '` + agent + `', 'box-a', 'live', 'box-a'` + vals + `)`
	}
	writes := []struct{ agent, cols, vals, after string }{
		{"c-261", "", "", "23502/"},
		{"c-262", ", topic, issue_key", ", '', 'SPL-1'", "23514/fleet_lanes_topic_set_check"},
		{"c-263", ", topic, issue_key", ", 't-1', ''", "23514/fleet_lanes_issue_key_check"},
		// R7 c-198 N1: each DROP DEFAULT alone, the other column named.
		{"c-265", ", issue_key", ", 'SPL-5'", "23502/"},
		{"c-266", ", topic", ", 't-6'", "23502/"},
	}
	keptTopic := map[string]string{"c-263": "t-1", "c-266": "t-6"}
	keptIssue := map[string]string{"c-262": "SPL-1", "c-265": "SPL-5"}
	read := func(agent string) (topic, issue string) {
		t.Helper()
		if err := tx.QueryRow(ctx, `SELECT topic, issue_key FROM fleet_lanes WHERE tenant_id = $1 AND fleet = 'f260' AND agent_id = $2`,
			tenant, agent).Scan(&topic, &issue); err != nil {
			t.Fatalf("read %s: %v", agent, err)
		}
		return topic, issue
	}

	exec("operator", `SELECT set_config('app.rls_scope', 'operator', true)`)
	exec("before", lanesRequiredBefore)
	for _, w := range writes {
		if got := try(ins(w.agent, w.cols, w.vals)); got != "" {
			t.Errorf("before %s: insert %s refused %s, want stored", lanesRequiredFile, w.agent, got)
		}
	}

	exec("after", string(raw))
	for _, w := range writes {
		topic, issue := read(w.agent)
		wantTopic, wantIssue := LaneUnknown, LaneUnknown
		if v, ok := keptTopic[w.agent]; ok {
			wantTopic = v
		}
		if v, ok := keptIssue[w.agent]; ok {
			wantIssue = v
		}
		if topic != wantTopic || issue != wantIssue {
			t.Errorf("after %s: %s reads (%q, %q), want (%q, %q)", lanesRequiredFile, w.agent, topic, issue, wantTopic, wantIssue)
		}
		if got := try(ins(strings.Replace(w.agent, "c-26", "c-27", 1), w.cols, w.vals)); got != w.after {
			t.Errorf("after %s: insert %s got %q, want refused %s", lanesRequiredFile, w.agent, got, w.after)
		}
	}
	exec("again", string(raw))
	if got := try(ins("c-264", ", topic, issue_key", ", 't-4', 'SPL-4'")); got != "" {
		t.Errorf("after %s: a linked row refused %s", lanesRequiredFile, got)
	}
}
