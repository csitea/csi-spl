// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// putMoveRedirect holds one row as P4 writes it: an operator-scope write on
// Postgres, where the tenant scope may only read its own (rdb 0249).
func putMoveRedirect(t *testing.T, s Store, src, task, dst string, expires time.Time) {
	t.Helper()
	if m, ok := s.(*Memory); ok {
		m.PutChannelMoveRedirect(src, task, ChannelMoveRedirect{Dst: dst, NewRef: task, MoveID: uuid4(), ExpiresAt: expires})
		return
	}
	ctx := context.Background()
	err := pgx.BeginFunc(ctx, s.(*Postgres).Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO channel_move_redirects (src_tenant_id, kind, old_ref, dst_tenant_id, new_ref, move_id, created_at, expires_at)
			VALUES ($1, 'task', $2, $3, $2, $4, $5, $6)`, src, task, dst, uuid4(), expires.Add(-time.Hour), expires)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

// The one read of the send path, on both stores: no rows and no row; moved; a
// lapsed row (it still reports, Live says false); a task with rows here is not
// moved whatever the table says; the channel of the earliest row. CONTROL: the
// same task id read from another workspace sees no redirect.
func TestTaskMoveState(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			mr := s.(ChannelMoveRedirects)
			src, dst := uid("mva-"), uid("mvb-")
			for _, tn := range []string{src, dst} {
				if err := s.CreateTenant(ctx, Tenant{ID: tn, RootPubKey: pubkey()}); err != nil {
					t.Fatal(err)
				}
			}
			now := time.Now().UTC().Truncate(time.Second)
			read := func(tenant, task string) TaskMoveState {
				t.Helper()
				st, err := mr.TaskMoveState(ctx, tenant, task)
				if err != nil {
					t.Fatal(err)
				}
				return st
			}
			if st := read(src, uuid4()); st.HasRows || st.FirstChannel != "" || st.Moved() != nil || st.Redirect != nil {
				t.Fatalf("an unknown task: %+v", st)
			}

			live := uuid4()
			putMoveRedirect(t, s, src, live, dst, now.Add(time.Hour))
			red := read(src, live).Moved()
			if red == nil || red.Dst != dst || red.NewRef != live || red.MoveID == "" || !red.Live(now) {
				t.Fatalf("moved: %+v", red)
			}
			if st := read(dst, live); st.Redirect != nil {
				t.Fatalf("control, another workspace: %+v", st.Redirect)
			}

			lapsed := uuid4()
			putMoveRedirect(t, s, src, lapsed, dst, now.Add(-time.Hour))
			if red := read(src, lapsed).Moved(); red == nil || red.Live(now) {
				t.Fatalf("lapsed: %+v", red)
			}

			home := uuid4()
			insertTestMsg := func(id, channel string, at time.Time) {
				t.Helper()
				inner := []byte(`{"v":1,"msg_id":"` + id + `"}`)
				m := Message{TenantID: src, MsgID: id, TaskID: home, Channel: channel, TS: at, IsParent: 1, FromBox: "box-a", FromID: "GRK-03",
					ToBox: "box-b", ToID: "c-120", Kind: "note", Body: "x", Files: []byte(`[]`), Msg: inner, Env: []byte(`{}`), ReceivedAt: at, ExpiresAt: at.Add(time.Hour)}
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			insertTestMsg(uuid4(), "", now.Add(-time.Minute))
			insertTestMsg(uuid4(), "lobby", now)
			putMoveRedirect(t, s, src, home, dst, now.Add(time.Hour))
			st := read(src, home)
			if !st.HasRows || st.Redirect == nil || st.Moved() != nil || st.FirstChannel != "" {
				t.Fatalf("a task with rows: %+v", st)
			}
		})
	}
}

// P7 compares two reads (5.4), so ChannelMoveProofRead is one snapshot: a row
// committed between them is not seen. CONTROL: asOperator's second read sees it.
func TestChannelMoveProofReadIsOneSnapshot(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	count := func(tx pgx.Tx) (n int64) {
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM tenants`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	moved := func(read func(context.Context, func(pgx.Tx) error) error) (first, second int64) {
		if err := read(ctx, func(tx pgx.Tx) error {
			first = count(tx)
			newTenant(t, pg)
			second = count(tx)
			return nil
		}); err != nil {
			t.Fatal(err)
		}
		return first, second
	}
	if a, b := moved(pg.ChannelMoveProofRead); a != b {
		t.Errorf("ChannelMoveProofRead saw a later commit: %d then %d", a, b)
	}
	if a, b := moved(pg.asOperator); a == b {
		t.Errorf("CONTROL: asOperator should see the later commit: %d then %d", a, b)
	}
}

// SPL-5075: the flock of a P4 run is per box and the hub holds no step lock, so
// a second P4, from another box, can pass the gate while the first one
// commits, then reach StartChannelMoveStep. That start must never clear the
// committed done mark: with P4 not done, P2..P4 would run again and P5..P7
// would refuse. Both orders, on a real P4: the late start after the commit,
// and one that waits on the row while the done mark is not committed yet.
// CONTROL: before P4 is done, a start of P4 runs and leaves it not done.
func TestStartChannelMoveStepKeepsCommittedP4(t *testing.T) {
	f := seedMove(t)
	ctx := context.Background()
	req := f.req()
	start := func() error {
		return f.pg.StartChannelMoveStep(ctx, f.dst, req.MoveID, f.ch, "P4", map[string]any{"lanes": []string{}})
	}
	p4Done := func() bool {
		t.Helper()
		return mvCount(t, f.pg, `SELECT count(*) FROM channel_move_steps WHERE tenant_id = $1 AND move_id = $2::uuid AND step = 'P4' AND done_at IS NOT NULL`,
			f.dst, req.MoveID) == 1
	}
	plan, err := f.pg.PlanChannelMove(ctx, req.ChannelMovePlanRequest)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.pg.OpenChannelMove(ctx, ChannelMoveOpen{Dst: f.dst, Src: f.src, Channel: f.ch, GoMsgID: req.GoMsgID,
		StartedBy: req.StartedBy, Binds: plan.Binds, MoveID: req.MoveID}); err != nil {
		t.Fatal(err)
	}
	if err := start(); err != nil {
		t.Fatalf("CONTROL: the first start of P4: %v", err)
	}
	if p4Done() {
		t.Fatal("CONTROL: a started P4 reads as done")
	}
	f.apply(t, req)
	if !p4Done() {
		t.Fatal("P4 committed but its step is not done")
	}
	if err := start(); !errors.Is(err, ErrConflict) {
		t.Errorf("a start of P4 after its commit: %v, want ErrConflict", err)
	}
	if !p4Done() {
		t.Error("a start after the commit cleared P4's done mark")
	}

	// The same race, with the late start waiting on the uncommitted done mark.
	mvExec(t, f.pg, `UPDATE channel_move_steps SET done_at = NULL WHERE tenant_id = $1 AND move_id = $2::uuid AND step = 'P4'`, f.dst, req.MoveID)
	locked, release, committed := make(chan struct{}), make(chan struct{}), make(chan error, 1)
	go func() {
		committed <- f.pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE channel_move_steps SET done_at = clock_timestamp() WHERE tenant_id = $1 AND move_id = $2::uuid AND step = 'P4'`,
				f.dst, req.MoveID)
			close(locked)
			<-release
			return err
		})
	}()
	<-locked
	late := make(chan error, 1)
	go func() { late <- start() }()
	waitForLockWait(t, f.pg)
	close(release)
	if err := <-committed; err != nil {
		t.Fatal(err)
	}
	if err := <-late; !errors.Is(err, ErrConflict) {
		t.Errorf("a start that waited on P4's commit: %v, want ErrConflict", err)
	}
	if !p4Done() {
		t.Fatal("a start that waited on P4's commit cleared its done mark")
	}
}

// waitForLockWait returns once a session of this database waits on a row lock.
func waitForLockWait(t *testing.T, pg *Postgres) {
	t.Helper()
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		var n int
		if err := pg.pool.QueryRow(context.Background(), `SELECT count(*) FROM pg_stat_activity
			WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%channel_move_steps%'`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n > 0 {
			return
		}
	}
	t.Fatal("the late start never waited on the P4 row")
}
