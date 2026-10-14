package store

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// The narrow stamp moves only on a row the channels view reads (rdb 0196,
// perf round 5 P5-10 4.3, SPL-1831). Postgres only. The 0103 stamp moves on
// every case; the narrow one only where want says. The red control: before
// 0196 the t: mark of a topic outside every channel, the issue and the
// message outside a channel each moved it.
func TestChangeStampNarrowChannelRows(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := seedTenantAll(t, pg)
	now := time.Now().UTC().Truncate(time.Microsecond)
	member := "HUM-" + a.tenant

	// A topic with one line in the channel: its t: mark is read by the view.
	chTopic := uuid4()
	line := msgFor(a.tenant, chTopic, "box-a", now, now, "env-"+a.tenant)
	line.Channel = a.channelID
	if _, err := pg.InsertMessage(ctx, line); err != nil {
		t.Fatal(err)
	}
	// A DM line outside every channel, live, to archive below.
	dm := msgFor(a.tenant, uuid4(), "box-a", now, now, "env-"+a.tenant)
	if _, err := pg.InsertMessage(ctx, dm); err != nil {
		t.Fatal(err)
	}
	mark := func(key string) func() error {
		return func() error {
			return pg.SaveReadMarks(ctx, a.tenant, member, map[string]ReadMark{key: {At: time.Now(), MsgID: "m"}}, time.Now())
		}
	}
	exec := func(sql string, args ...any) func() error {
		return func() error {
			return pg.inTenant(ctx, a.tenant, func(tx pgx.Tx) error {
				tag, err := tx.Exec(ctx, sql, args...)
				if err == nil && tag.RowsAffected() == 0 {
					t.Fatalf("%s wrote no row (control)", sql)
				}
				return err
			})
		}
	}
	insert := func(m Message) func() error {
		return func() error { _, err := pg.InsertMessage(ctx, m); return err }
	}
	outside := msgFor(a.tenant, uuid4(), "box-a", now, now, "env-"+a.tenant)
	inside := msgFor(a.tenant, chTopic, "box-a", now, now, "env-"+a.tenant)
	inside.Channel = a.channelID

	cases := []struct {
		name  string
		write func() error
		want  bool // the narrow stamp moves
	}{
		{"t: mark, topic outside every channel", mark("t:" + uuid4()), false},
		{"t: mark, not a uuid", mark("t:lobby"), false},
		{"dm: mark", mark("dm:HUM-2"), false},
		{"issues", exec(`UPDATE issues SET tenant_id = tenant_id WHERE tenant_id = $1`, a.tenant), false},
		{"message outside a channel", insert(outside), false},
		{"ch: mark", mark("ch:" + a.channelID), true},
		{"t: mark, topic with a channel line", mark("t:" + chTopic), true},
		{"message in a channel", insert(inside), true},
		{"archive a line outside a channel", exec(`UPDATE messages SET archived_at = now() WHERE tenant_id = $1 AND msg_id = $2`, a.tenant, dm.MsgID), true},
		{"move a line out of its channel", exec(`UPDATE messages SET channel = NULL WHERE tenant_id = $1 AND msg_id = $2`, a.tenant, inside.MsgID), true},
		{"channel_subscriptions", exec(`UPDATE channel_subscriptions SET tenant_id = tenant_id WHERE tenant_id = $1`, a.tenant), true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			before := stampBoth(t, pg, a.tenant)
			if err := c.write(); err != nil {
				t.Fatal(err)
			}
			after := stampBoth(t, pg, a.tenant)
			if after.Stamp <= before.Stamp {
				t.Fatalf("the 0103 stamp stayed at %d (control)", after.Stamp)
			}
			if moved := after.NoDeliveries > before.NoDeliveries; moved != c.want {
				t.Errorf("narrow stamp moved %v (%d -> %d), want %v", moved, before.NoDeliveries, after.NoDeliveries, c.want)
			}
		})
	}
}
