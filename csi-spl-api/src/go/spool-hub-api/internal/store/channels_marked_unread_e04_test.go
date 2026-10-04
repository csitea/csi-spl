package store

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestMarkedUnreadRangesFromTheMark pins the shape measured on prd t1 (perf
// edition 20261004, E04). Without a received_at range, each mark scans its
// whole channel. Planting the old predicate fails this test.
func TestMarkedUnreadRangesFromTheMark(t *testing.T) {
	sql := newChannelStats("t1").markedUnreadRead(nil, time.Now(), "HUM-1", "00000000-0000-4000-8000-000000000001").sql
	if !strings.Contains(sql, "m.received_at >= mk.at") {
		t.Fatal("marked unread has no received_at range, so each mark scans the whole channel")
	}
}

// markedUnreadLines is one channel, almost all of it already read.
// markedUnreadBufferBudget is the shared-buffer ceiling of counting the tail.
// On an analyzed postgres:16 of this seed the range scan touched 46 shared
// buffers and used messages_channel. The planted predicate with no
// received_at range did not use that index and touched 243 (n=1).
const (
	markedUnreadLines        = 5000
	markedUnreadTail         = 20
	markedUnreadBufferBudget = 200
)

// TestMarkedUnreadBufferBudget (Postgres): the count after a mark near the
// end of a long channel uses messages_channel and stays within
// markedUnreadBufferBudget. The tail is markedUnreadTail lines.
func TestMarkedUnreadBufferBudget(t *testing.T) {
	pg := perfStore(t, "")
	ctx := context.Background()
	tid := perfTenant(t, pg)
	t.Cleanup(func() {
		_ = pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, tid)
			return err
		})
	})
	base := time.Now().UTC().Add(-3 * time.Hour).Truncate(time.Second)
	markN := markedUnreadLines - markedUnreadTail
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id,
			to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
			SELECT $1,
				('20000000-0000-4000-8000-' || lpad(to_hex(g), 12, '0'))::uuid,
				('20000000-0000-4000-8000-' || lpad(to_hex(g), 12, '0'))::uuid,
				'bulk', $2::timestamptz, 'box-a', 'CLE-01', 'box-b', 'HUM-2', 'note', 'b', '{"v":1}', 'sig',
				convert_to('x', 'UTF8'), $2::timestamptz + (g || ' seconds')::interval, $3::timestamptz
			FROM generate_series(1, $4) g`, tid, base, base.Add(30*24*time.Hour), markedUnreadLines)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.pool.Exec(ctx, `ANALYZE messages`); err != nil {
		t.Fatal(err)
	}
	markID := fmt.Sprintf("20000000-0000-4000-8000-%012x", markN)
	reads := map[string]ReadMark{"bulk": {At: base.Add(time.Duration(markN) * time.Second), MsgID: markID}}
	cs := newChannelStats(tid)
	r := cs.markedUnreadRead(reads, time.Now().UTC(), "HUM-1", "00000000-0000-4000-8000-0000000000aa")
	var sum int
	if err := pg.queryTenant(ctx, tid, r.sql, r.args, func(rows pgx.Rows) error {
		var ch string
		var n int
		if err := rows.Scan(&ch, &n); err != nil {
			return err
		}
		if ch == "bulk" {
			sum = n
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if sum != markedUnreadTail {
		t.Fatalf("unread after the mark = %d, want %d", sum, markedUnreadTail)
	}
	indexes, buffers, ms := explainUnread(t, pg, tid, r.sql, r.args)
	ranged := false
	for _, name := range indexes {
		if name == "messages_channel" {
			ranged = true
		}
	}
	t.Logf("PERF marked unread: lines=%d tail=%d shared buffers=%d exec=%.2f ms indexes=%v", markedUnreadLines, markedUnreadTail, buffers, ms, indexes)
	if !ranged {
		t.Fatalf("plan did not range-scan messages_channel (indexes %v)", indexes)
	}
	if buffers > markedUnreadBufferBudget {
		t.Fatalf("marked unread touched %d shared buffers, budget %d", buffers, markedUnreadBufferBudget)
	}
}
