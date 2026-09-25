package store

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestReplyChannelBackfill (rdb 0042, CLE-34978): the file gives every
// untagged reply stored before hub 0.5.4 the channel TopicChannel would give
// it now - its task's earliest is_parent 1 row. Controls: a reply under a DM
// topic stays NULL, a reply that names another channel keeps it, a topic
// root is never touched, and another tenant's same task_id does not leak.
func TestReplyChannelBackfill(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0042_messages_reply_channel_backfill.sql"))
	if err != nil {
		t.Fatal(err)
	}
	a, b := newTenant(t, pg), newTenant(t, pg)
	now := time.Now().UTC().Truncate(time.Microsecond)
	at := func(i int) time.Time { return now.Add(time.Duration(i) * time.Second) }

	insert := func(tenant, task, channel string, isParent int, when time.Time) string {
		t.Helper()
		m := msgFor(tenant, task, "box-b", when, when, uuid4())
		m.Channel, m.IsParent = channel, isParent
		if ins, err := pg.InsertMessage(ctx, m); err != nil || !ins {
			t.Fatalf("insert: %v %v", ins, err)
		}
		return m.MsgID
	}
	lobby, dm, tasks, late := uuid4(), uuid4(), uuid4(), uuid4()
	lobbyRoot := insert(a, lobby, "lobby", 1, at(0))
	lobbyReply := insert(a, lobby, "", 0, at(1))
	insert(a, dm, "", 1, at(0))
	dmReply := insert(a, dm, "", 0, at(1))
	insert(a, tasks, "tasks", 1, at(0))
	taggedReply := insert(a, tasks, "lobby", 0, at(1))
	// A later is_parent 1 row on the same task is not the root.
	insert(a, late, "tasks", 1, at(0))
	insert(a, late, "lobby", 1, at(2))
	lateReply := insert(a, late, "", 0, at(3))
	// Tenant b reuses the lobby task_id with a DM root: its reply stays NULL.
	insert(b, lobby, "", 1, at(0))
	otherTenantReply := insert(b, lobby, "", 0, at(1))

	if err := pgx.BeginFunc(ctx, pg.Pool(), func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, pgScopeOperator); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, string(raw))
		return err
	}); err != nil {
		t.Fatal(err)
	}

	channel := func(tenant, msgID string) string {
		t.Helper()
		var c string
		if err := pg.queryRowTenant(ctx, tenant, `SELECT COALESCE(channel, '') FROM messages WHERE tenant_id = $1 AND msg_id = $2`,
			[]any{tenant, msgID}, &c); err != nil {
			t.Fatal(err)
		}
		return c
	}
	for _, c := range []struct {
		what, tenant, msgID, want string
	}{
		{"lobby reply inherits", a, lobbyReply, "lobby"},
		{"root untouched", a, lobbyRoot, "lobby"},
		{"DM reply stays NULL", a, dmReply, ""},
		{"tagged reply keeps its tag", a, taggedReply, "lobby"},
		{"earliest root wins", a, lateReply, "tasks"},
		{"other tenant's DM reply stays NULL", b, otherTenantReply, ""},
	} {
		if got := channel(c.tenant, c.msgID); got != c.want {
			t.Errorf("%s: channel %q, want %q", c.what, got, c.want)
		}
	}
	for _, task := range []string{lobby, late} {
		got, err := pg.TopicChannel(ctx, a, task)
		if err != nil {
			t.Fatal(err)
		}
		var reply string
		if task == lobby {
			reply = channel(a, lobbyReply)
		} else {
			reply = channel(a, lateReply)
		}
		if got != reply {
			t.Errorf("task %s: TopicChannel %q but the backfilled reply says %q", task, got, reply)
		}
	}
}
