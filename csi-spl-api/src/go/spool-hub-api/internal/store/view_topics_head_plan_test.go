package store

import (
	"context"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 099 T009 follow-up (t1 5901e226): after the flip prd's head read took
// 18 ms p50 (walk_all_head, n=20; walk_dm_head 10 ms). The planner rated the
// NoIssues probe `(SELECT .. FROM issues ..) IS NULL` at its 0.5% default,
// expected 2 rows instead of 690, and ran the issues and roots probes for
// every candidate topic (872 each) before the sort and LIMIT. The head walk
// now sorts the candidates in an inner subquery (OFFSET 0 keeps it apart) and
// runs the probes in key order, so LIMIT stops them after about one page.
// (Without OFFSET 0 the planner kept the subquery apart too on Postgres 16;
// the fence makes that a rule, not a planner choice.)

// headPlanLines runs sql under the head header (prefix "EXPLAIN ..." or "")
// and returns the first column of every row: the plan lines, or the task ids.
func headPlanLines(t *testing.T, pg *Postgres, prefix, sql string, args []any, tenant string) []string {
	t.Helper()
	ctx := context.Background()
	b := &pgx.Batch{}
	b.Queue(pgScopeTenantHeads, tenant)
	b.Queue(prefix+sql, args...)
	br := pg.pool.SendBatch(ctx, b)
	defer br.Close()
	if _, err := br.Exec(); err != nil {
		t.Fatal(err)
	}
	rows, err := br.Query()
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	if err := scanRows(rows, func(r pgx.Rows) error {
		v, err := r.Values()
		if err != nil {
			return err
		}
		out = append(out, v[0].(string))
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return out
}

var planLoopsRe = regexp.MustCompile(`loops=(\d+)\)`)

// probeLoops is the most loops of any plan node on table alias (e.g.
// "issues i"): how many candidate topics that probe ran for.
func probeLoops(plan []string, alias string) int {
	most := 0
	for _, ln := range plan {
		if !strings.Contains(ln, " on "+alias+" ") {
			continue
		}
		if m := planLoopsRe.FindStringSubmatch(ln); m != nil {
			if n, _ := strconv.Atoi(m[1]); n > most {
				most = n
			}
		}
	}
	return most
}

// TestTopicHeadProbesAfterSort seeds 1 500 topics (9 000 messages) and asks
// the lobby's question (read door, Roots, NoIssues, limit 51) on all and on
// DM: the roots and issues probes must run for about one page of topics, not
// for every candidate. CONTROL: the form before the fix (headWalkSQL, probes
// beside the door) must probe every candidate again; both forms must give the
// same answer.
func TestTopicHeadProbesAfterSort(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	tn := newTenant(t, pg)
	seedTopics(t, pg, tn, 9000, 1500, now, 0.21)
	for _, tb := range []string{"topic_heads", "topic_head_parts", "issues"} {
		if _, err := pg.pool.Exec(ctx, "ANALYZE "+tb); err != nil {
			t.Fatal(err)
		}
	}
	const limit = 51
	q := TopicQuery{Roots: true, NoIssues: true, Reader: "HUM-1", ReaderChannels: []string{"c1", "c2"}, Limit: limit, Now: now}
	dm := q
	dm.DM, dm.Viewer = true, "HUM-1"
	const explain = "EXPLAIN (ANALYZE) "
	for name, sq := range map[string]TopicQuery{"all": q, "dm": dm} {
		sql, args := viewTopicsHeadSQL(tn, sq)
		old, oldArgs := headWalkSQL(tn, sq, false)
		plan := headPlanLines(t, pg, explain, sql, args, tn)
		for _, alias := range []string{"issues i", "messages f"} {
			if n := probeLoops(plan, alias); n == 0 || n > 2*limit {
				t.Errorf("%s: the %s probe ran %d times, want 1..%d:\n%s", name, alias, n, 2*limit, strings.Join(plan, "\n"))
			}
		}
		ctl := headPlanLines(t, pg, explain, old, oldArgs, tn)
		if n := probeLoops(ctl, "issues i"); n <= 2*limit {
			t.Errorf("%s: CONTROL the old form ran the issues probe %d times, want > %d (the test cannot see the old plan):\n%s",
				name, n, 2*limit, strings.Join(ctl, "\n"))
		}
		got, want := headPlanLines(t, pg, "", sql, args, tn), headPlanLines(t, pg, "", old, oldArgs, tn)
		if len(got) != limit || strings.Join(got, ",") != strings.Join(want, ",") {
			t.Errorf("%s: %d rows %v, the old form %d rows %v", name, len(got), got, len(want), want)
		}
	}
}
