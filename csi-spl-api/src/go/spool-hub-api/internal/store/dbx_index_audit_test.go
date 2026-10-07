package store

import (
	"context"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// rdb 0122 (perf edition 20261004, lane DBX): the committed-row prune finds
// its rows through deliveries_sent_acked under the RLS operator scope, the
// GIN the hub could never use is gone, and messages_channel (the channel
// counts' newest-message probe) stays. rdb 0143 (spec 100 S1r) brings
// messages_search back as gin (tenant_id, search_tsv), read only through
// spool_search_candidates: never the single-column form 0122 dropped.
func TestDBXIndexAudit0122(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	exists := func(name string) bool {
		var n int
		if err := pg.pool.QueryRow(ctx, `SELECT count(*) FROM pg_indexes WHERE schemaname = current_schema() AND indexname = $1`, name).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n == 1
	}
	if !exists("deliveries_sent_acked") {
		t.Fatal("deliveries_sent_acked missing after migrate")
	}
	var def string
	if err := pg.pool.QueryRow(ctx, `SELECT COALESCE((SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND indexname = 'messages_search'), '')`).Scan(&def); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(def, "USING gin (tenant_id, search_tsv)") {
		t.Fatalf("messages_search must be rdb 0143's gin (tenant_id, search_tsv), got %q", def)
	}
	if !exists("messages_channel") {
		t.Fatal("messages_channel must stay: channel counts probe it")
	}
	// The prune's inner select, as pruneCommitted runs it: the partial index
	// must match its predicate under the policy (seq scan off only so a tiny
	// test table cannot hide an index the planner may not use).
	var plan []string
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SET LOCAL enable_seqscan = off`); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `EXPLAIN SELECT tenant_id, msg_id, to_box FROM deliveries
			WHERE state = 'sent' AND acked_at < now() - interval '720 hours' LIMIT 5000`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var l string
			if err := rows.Scan(&l); err != nil {
				return err
			}
			plan = append(plan, l)
		}
		return rows.Err()
	})
	if err != nil {
		t.Fatal(err)
	}
	if p := strings.Join(plan, "\n"); !strings.Contains(p, "deliveries_sent_acked") {
		t.Fatalf("prune select does not use deliveries_sent_acked:\n%s", p)
	}
}
