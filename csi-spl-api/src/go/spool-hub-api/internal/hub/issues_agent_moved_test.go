package hub_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// moveIssueKey holds one kind issue redirect row, as P4's writeRedirects does.
func moveIssueKey(t *testing.T, e *env, src, oldKey, dst, newKey string, age, ttl time.Duration) {
	t.Helper()
	now := time.Now().UTC()
	if m, ok := e.st.(*store.Memory); ok {
		m.PutIssueMove(src, store.IssueMove{OldKey: oldKey, Dst: dst, NewKey: newKey, ExpiresAt: now.Add(ttl - age)})
		return
	}
	err := pgx.BeginFunc(context.Background(), e.st.(*store.Postgres).Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(context.Background(), `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		_, err := tx.Exec(context.Background(), `INSERT INTO channel_move_redirects (src_tenant_id, kind, old_ref, dst_tenant_id, new_ref, move_id, created_at, expires_at)
			VALUES ($1, 'issue', $2, $3, $4, $5, $6, $7)`, src, oldKey, dst, newKey, uuid4(), now.Add(-age), now.Add(ttl-age))
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

// Spec 169 row T7g: `spool issue moved` reads the closer's old key map, the
// kind issue rows whose <SRC> is the box's workspace, on both sides of the
// 30 days, and no other workspace's row (src_read).
func TestAgentIssueMoved(t *testing.T) {
	e := followEnv(t)
	src, _ := e.tenant()
	dst, _ := e.tenant()
	ctx := context.Background()
	a := e.box(src, "box-a", "CLE-07")
	e.pin(src, a)
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	day := 24 * time.Hour
	moveIssueKey(t, e, src, "SPL-4", dst, "ACME-2", 31*day, 30*day) // expired a day ago
	moveIssueKey(t, e, src, "SPL-3", dst, "ACME-1", time.Hour, 30*day)
	moveIssueKey(t, e, dst, "ACME-9", src, "SPL-9", time.Hour, 30*day) // the other way: not src's row

	raw, err := action.Issue(ctx, a.cfg, action.IssueArgs{Op: "moved", As: "CLE-07", Hub: a.c})
	if err != nil {
		t.Fatal(err)
	}
	var whole map[string][]map[string]any
	if err := json.Unmarshal(raw, &whole); err != nil {
		t.Fatalf("reply %s: %v", raw, err)
	}
	got := whole["moved"]
	if len(got) != 2 {
		t.Fatalf("moved: want SPL-3 and SPL-4 only, got %s", raw)
	}
	if got[0]["old_key"] != "SPL-3" || got[0]["new_key"] != "ACME-1" || got[0]["dst"] != dst || got[0]["live"] != true {
		t.Errorf("the live row: %v", got[0])
	}
	if got[1]["old_key"] != "SPL-4" || got[1]["new_key"] != "ACME-2" || got[1]["live"] != false {
		t.Errorf("the expired row: %v", got[1])
	}
	if exp, err := time.Parse(time.RFC3339, got[0]["expires_at"].(string)); err != nil || !exp.After(time.Now()) {
		t.Errorf("expires_at %v: %v", got[0]["expires_at"], err)
	}
}
