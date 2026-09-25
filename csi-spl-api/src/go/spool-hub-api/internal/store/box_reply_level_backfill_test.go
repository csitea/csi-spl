package store

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestBoxReplyLevelBackfill (rdb 0043, CLE-34978): a box line stored after
// the root of a channel topic becomes a reply (is_parent 0), as hub.boxLevel
// now stores it. Controls: the root, a box line under a DM topic, a browser
// row, a box line on the legacy lobby task and another tenant all keep 1.
func TestBoxReplyLevelBackfill(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0043_messages_box_reply_level_backfill.sql"))
	if err != nil {
		t.Fatal(err)
	}
	a, b := newTenant(t, pg), newTenant(t, pg)
	now := time.Now().UTC().Truncate(time.Microsecond)
	at := func(i int) time.Time { return now.Add(time.Duration(i) * time.Second) }

	insert := func(tenant, task, fromBox, channel string, when time.Time) string {
		t.Helper()
		m := msgFor(tenant, task, "box-b", when, when, uuid4())
		m.FromBox, m.Channel, m.IsParent = fromBox, channel, 1
		if ins, err := pg.InsertMessage(ctx, m); err != nil || !ins {
			t.Fatalf("insert: %v %v", ins, err)
		}
		return m.MsgID
	}
	const lobbyTask = "00000000-0000-4000-8000-000000000001"
	topic, dm := uuid4(), uuid4()
	root := insert(a, topic, "box-wui", "lobby", at(0))
	boxReply := insert(a, topic, "box-a", "lobby", at(1))
	wuiRow := insert(a, topic, "box-wui", "lobby", at(2))
	insert(a, dm, "box-wui", "", at(0))
	dmReply := insert(a, dm, "box-a", "", at(1))
	insert(a, lobbyTask, "box-wui", "lobby", at(0))
	lobbyLine := insert(a, lobbyTask, "box-a", "lobby", at(1))
	insert(b, topic, "box-wui", "", at(0))
	otherTenant := insert(b, topic, "box-a", "", at(1))

	if err := pgx.BeginFunc(ctx, pg.Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, pgScopeOperator); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, string(raw))
		return err
	}); err != nil {
		t.Fatal(err)
	}

	level := func(tenant, msgID string) int {
		t.Helper()
		var n int
		if err := pg.queryRowTenant(ctx, tenant, `SELECT is_parent FROM messages WHERE tenant_id = $1 AND msg_id = $2`,
			[]any{tenant, msgID}, &n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	for _, c := range []struct {
		what, tenant, msgID string
		want                int
	}{
		{"box reply under a channel topic", a, boxReply, 0},
		{"the root", a, root, 1},
		{"a browser row", a, wuiRow, 1},
		{"box reply under a DM topic", a, dmReply, 1},
		{"box line on the lobby task", a, lobbyLine, 1},
		{"other tenant's DM topic", b, otherTenant, 1},
	} {
		if got := level(c.tenant, c.msgID); got != c.want {
			t.Errorf("%s: is_parent %d, want %d", c.what, got, c.want)
		}
	}
}
