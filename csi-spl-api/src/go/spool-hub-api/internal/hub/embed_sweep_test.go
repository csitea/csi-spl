package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/121 T105: the embed token sweep (embed_sweep.go).

// visitorRow is (ip_hash set, token_hash) of the visitor owning channel ch.
func visitorRow(t *testing.T, pg *store.Postgres, tid, ch string) (bool, []byte) {
	t.Helper()
	ctx := context.Background()
	tx, err := pg.Pool().Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tid); err != nil {
		t.Fatal(err)
	}
	var hasIP bool
	var hash []byte
	if err := tx.QueryRow(ctx, `SELECT ip_hash IS NOT NULL, token_hash FROM embed_visitors
		WHERE tenant_id = $1 AND channel_id = $2`, tid, ch).Scan(&hasIP, &hash); err != nil {
		t.Fatal(err)
	}
	return hasIP, hash
}

// reviveVisitor moves the expiry of channel ch's visitor a year ahead, as a
// bug might: a swept token must stay dead anyway.
func reviveVisitor(t *testing.T, pg *store.Postgres, tid, ch string, at time.Time) {
	t.Helper()
	ctx := context.Background()
	tx, err := pg.Pool().Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tid); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `UPDATE embed_visitors SET expires_at = $3 WHERE tenant_id = $1 AND channel_id = $2`,
		tid, ch, at.Add(365*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
}

// TestEmbedSweepRetiresExpiredTokens: the sweep retires a token that has
// expired (its stored hash changes and its ip_hash is cleared), so even with
// its expiry moved ahead it opens nothing; the channel and its line stay.
// CONTROL: a live visitor swept at the same time keeps its hash, its
// ip_hash and its access; and the expired one, unswept, would revive (the
// sweep is what kills it).
func TestEmbedSweepRetiresExpiredTokens(t *testing.T) {
	clock := newClock()
	e, pg := abuseEnv(t, hub.EmbedLimits{PowBits: 8}, clock)
	tid, _ := e.tenant()
	embed := seedEmbed(t, pg, tid, true)
	old, oldCh := mint(t, e, tid, embed)
	unswept, unsweptCh := mint(t, e, tid, embed)
	if code, raw := embedCall(t, e, tid, http.MethodPost, "/v1/embed/"+embed+"/messages", old, solvedPost(t, e, tid, embed, old, "hello")); code != http.StatusCreated {
		t.Fatalf("post: %d %s", code, raw)
	}
	clock.add(embedLife.Sliding + time.Hour)
	reviveVisitor(t, pg, tid, unsweptCh, clock.now())
	if code, raw := embedCall(t, e, tid, http.MethodGet, "/v1/embed/"+embed+"/messages", unswept, ""); code != http.StatusOK {
		t.Fatalf("CONTROL: an expired token revived without a sweep: %d %s, want 200 (else the sweep proves nothing)", code, raw)
	}
	live, liveCh := mint(t, e, tid, embed)
	_, beforeHash := visitorRow(t, pg, tid, oldCh)
	_, liveHash := visitorRow(t, pg, tid, liveCh)

	e.srv.SweepEmbed(context.Background())

	hasIP, afterHash := visitorRow(t, pg, tid, oldCh)
	if hasIP || string(afterHash) == string(beforeHash) {
		t.Fatalf("swept: ip_hash set=%v, hash changed=%v; want cleared and changed", hasIP, string(afterHash) != string(beforeHash))
	}
	reviveVisitor(t, pg, tid, oldCh, clock.now())
	if code, raw := embedCall(t, e, tid, http.MethodGet, "/v1/embed/"+embed+"/messages", old, ""); code != http.StatusUnauthorized {
		t.Errorf("a swept token, its expiry moved ahead: %d %s, want 401", code, raw)
	}
	if _, m := embedCounts(t, pg, tid, embed); m != 1 {
		t.Errorf("the sweep touched the channel: %d messages, want 1", m)
	}
	liveIP, liveAfter := visitorRow(t, pg, tid, liveCh)
	if !liveIP || string(liveAfter) != string(liveHash) {
		t.Errorf("CONTROL: the live visitor: ip_hash set=%v, hash kept=%v", liveIP, string(liveAfter) == string(liveHash))
	}
	if code, raw := embedCall(t, e, tid, http.MethodGet, "/v1/embed/"+embed+"/messages", live, ""); code != http.StatusOK {
		t.Errorf("CONTROL: the live visitor after the sweep: %d %s", code, raw)
	}
}
