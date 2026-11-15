package store

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// SPL-5628: one sweep published 2 posts on a Facebook Page capped at 1. The
// claim was `UPDATE ... WHERE post_id IN (SELECT ... LIMIT $4 FOR UPDATE
// SKIP LOCKED)`; once marketing_posts grew, the planner could run that
// subquery on the inner side of a Nested Loop Semi Join, once per outer
// row, and each run skipped the rows the UPDATE had already changed and
// returned the next due post. The test pins that plan shape with planner
// settings (metaRescanGUCs), so the red is deterministic, not 1 in N.

// metaRescanGUCs leave the planner only the nested loop with the claim's
// subquery rescanned inside it (no hash, merge, materialize, sort or index
// path is cheaper).
var metaRescanGUCs = map[string]string{"enable_hashagg": "off", "enable_material": "off", "enable_hashjoin": "off",
	"enable_mergejoin": "off", "enable_indexscan": "off", "enable_bitmapscan": "off", "enable_sort": "off"}

// metaRescanStore opens a second Postgres store on SPOOL_TEST_PG_DSN whose
// sessions run with metaRescanGUCs (startup runtime parameters).
func metaRescanStore(t *testing.T) *Postgres {
	t.Helper()
	rlsStore(t) // skips without SPOOL_TEST_PG_DSN; migrates
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if u, err := url.Parse(dsn); err == nil && u.Scheme != "" {
		q := u.Query()
		for k, v := range metaRescanGUCs {
			q.Set(k, v)
		}
		u.RawQuery = q.Encode()
		dsn = u.String()
	} else {
		for k, v := range metaRescanGUCs {
			dsn += " " + k + "=" + v
		}
	}
	pg, err := OpenPostgres(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	return pg
}

// metaRescanPlanLive proves the settings still force the bad shape: the
// pre-fix claim (kept here only as the control) plans a Nested Loop Semi
// Join and takes more rows than its LIMIT. Rolled back.
func metaRescanPlanLive(t *testing.T, pg *Postgres, tn, channel string, now time.Time) {
	t.Helper()
	old := `UPDATE marketing_posts SET status = 'dispatching', attempts = attempts + 1, claimed_at = $3, updated_at = $3
		WHERE post_id IN (SELECT post_id FROM marketing_posts WHERE tenant_id = $1 AND channel_id = $2::uuid
			AND status = 'scheduled' AND (next_attempt_at IS NULL OR next_attempt_at <= $3)
			ORDER BY created_at LIMIT $4 FOR UPDATE SKIP LOCKED)`
	var plan []string
	errRollback := fmt.Errorf("rollback")
	err := pg.inTenant(context.Background(), tn, func(tx pgx.Tx) error {
		rows, err := tx.Query(context.Background(), "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) "+old, tn, channel, now, 1)
		if err != nil {
			return err
		}
		if err := scanRows(rows, func(r pgx.Rows) error {
			var l string
			err := r.Scan(&l)
			plan = append(plan, l)
			return err
		}); err != nil {
			return err
		}
		return errRollback
	})
	p := strings.Join(plan, "\n")
	if err != errRollback || !strings.Contains(p, "Nested Loop Semi Join") || strings.Contains(p, "Update on marketing_posts (actual rows=1 ") {
		t.Fatalf("the control is not live (the settings no longer force the rescan): %v\n%s", err, p)
	}
}

func TestMarketingMetaClaimNeverOverRoom(t *testing.T) {
	pg := metaRescanStore(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	for _, limit := range []int{1, 2} {
		tn := mktTenant(t, pg) // one Page per tenant (account_ref is unique)
		ch := mktCapChannel(t, pg, tn, MarketingPlatformFacebook, false)
		refs := []string{}
		for i := 0; i < 3; i++ { // oldest first: created a minute apart
			ref := fmt.Sprintf("2026-11-02-%d-%d", limit, i)
			mktCapPost(t, pg, ch, ref, now.Add(time.Duration(i-3)*time.Minute))
			refs = append(refs, ref)
		}
		metaRescanPlanLive(t, pg, tn, ch.ID, now)
		got, err := pg.ClaimMetaMarketingPosts(ctx, MetaClaim{Tenant: tn, ChannelID: ch.ID, Limit: limit, Window: 24 * time.Hour, Now: now})
		if err != nil || len(got.Posts) != limit || !got.Held {
			t.Fatalf("limit %d: claim = %d posts %+v, %v; want %d, the rest held", limit, len(got.Posts), got, err, limit)
		}
		for i, ref := range refs {
			p, err := pg.MarketingPostByRef(ctx, tn, ch.ID, MarketingSourceBlog, ref)
			claimed := i < limit
			if err != nil || (p.Status == MarketingDispatching) != claimed || p.Attempts != map[bool]int{true: 1}[claimed] {
				t.Errorf("limit %d: post %s = %s, %d attempts, %v; want claimed=%v (oldest first)", limit, ref, p.Status, p.Attempts, err, claimed)
			}
		}
	}
}
