// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
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
