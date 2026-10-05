package store

import (
	"context"
	"errors"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Change stamp (rdb 0103, DB payload round 2 R2-5). Postgres only: the
// stamp is the triggers. A missed bump is a stale screen (hub/view_stamp.go
// answers 304 from it), so every table the covered views read has a test
// here that fails when its trigger is gone, and the main writers are each
// driven through the store API.

// stampTables are exactly the tenant tables 0103 puts change_stamp on.
var stampTables = []string{
	"box_operators", "channel_humans", "channel_subscriptions", "channels", "deliveries", "issues",
	"member_clones", "message_kind_changes", "message_moderation", "message_reactions", "message_revisions", "messages",
	"rbac_roles", "read_marks", "tenant_memberships",
}

// stampGlobalTables have no tenant_id: a write moves every tenant's stamp.
var stampGlobalTables = []string{"rbac_permissions", "rbac_role_permissions"}

func stampNow(t *testing.T, pg *Postgres, tenant string) int64 {
	t.Helper()
	now := time.Now()
	c, err := pg.ChangeStamp(context.Background(), tenant, now, now)
	if err != nil {
		t.Fatal(err)
	}
	return c.Stamp
}

// TestChangeStampTriggerCatalogue: the triggers in the database are the
// list above, no more and no fewer.
func TestChangeStampTriggerCatalogue(t *testing.T) {
	pg := rlsStore(t)
	var got []string
	err := pg.asOperatorQuery(context.Background(), `SELECT c.relname FROM pg_trigger g
		JOIN pg_class c ON c.oid = g.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE g.tgname = 'change_stamp' AND n.nspname = current_schema() ORDER BY 1`, nil,
		func(rows pgx.Rows) error {
			var s string
			err := rows.Scan(&s)
			got = append(got, s)
			return err
		})
	if err != nil {
		t.Fatal(err)
	}
	want := append(append([]string{}, stampTables...), stampGlobalTables...)
	sort.Strings(want)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("change_stamp triggers on %v, want %v", got, want)
	}
}

// TestChangeStampEveryTable: a committed write to any covered table moves
// its tenant's stamp and no other tenant's; a rolled-back one moves nothing.
func TestChangeStampEveryTable(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := seedTenantAll(t, pg), seedTenantAll(t, pg)
	for _, tb := range stampTables {
		t.Run(tb, func(t *testing.T) {
			id := pgx.Identifier{tb}.Sanitize()
			touch := func(tx pgx.Tx) (int64, error) {
				tag, err := tx.Exec(ctx, `UPDATE `+id+` SET tenant_id = tenant_id WHERE tenant_id = $1`, a.tenant)
				return tag.RowsAffected(), err
			}
			beforeA, beforeB := stampNow(t, pg, a.tenant), stampNow(t, pg, b.tenant)
			rolledBack := errors.New("rollback")
			if err := pg.inTenant(ctx, a.tenant, func(tx pgx.Tx) error {
				if _, err := touch(tx); err != nil {
					return err
				}
				return rolledBack
			}); !errors.Is(err, rolledBack) {
				t.Fatal(err)
			}
			if got := stampNow(t, pg, a.tenant); got != beforeA {
				t.Fatalf("a rolled-back write moved the stamp %d -> %d", beforeA, got)
			}
			var n int64
			if err := pg.inTenant(ctx, a.tenant, func(tx pgx.Tx) (err error) {
				n, err = touch(tx)
				return err
			}); err != nil {
				t.Fatal(err)
			}
			if n == 0 {
				t.Fatalf("seedTenantAll wrote no %s row for A (control)", tb)
			}
			if got := stampNow(t, pg, a.tenant); got <= beforeA {
				t.Errorf("a write to %d %s row(s) left A's stamp at %d: the change_stamp trigger is missing", n, tb, got)
			}
			if got := stampNow(t, pg, b.tenant); got != beforeB {
				t.Errorf("A's %s write moved B's stamp %d -> %d", tb, beforeB, got)
			}
		})
	}
	t.Run("global rbac", func(t *testing.T) {
		beforeA, beforeB := stampNow(t, pg, a.tenant), stampNow(t, pg, b.tenant)
		if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE rbac_permissions SET description = description WHERE permission_id = 'threads.read'`)
			return err
		}); err != nil {
			t.Fatal(err)
		}
		if stampNow(t, pg, a.tenant) <= beforeA || stampNow(t, pg, b.tenant) <= beforeB {
			t.Errorf("an rbac_permissions write moved not every tenant's stamp")
		}
	})
}

// TestChangeStampWriters drives the writers of the covered views through the
// store API, each on its own seeded tenant: send, delivery, edit, kind,
// reaction add and remove, archive and unarchive, move, topic delete,
// channel create / agent invite / human add / archive, role change, read
// marks, retention.
func TestChangeStampWriters(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	at := func() time.Time { return time.Now().UTC().Add(time.Minute) }
	type seeded struct {
		crossSeed
		msg, other string
	}
	type writer struct {
		name string
		do   func(s seeded) error
		prep func(s *seeded) error // before the stamp is read
	}
	writers := []writer{
		{name: "send", do: func(s seeded) error {
			_, err := pg.InsertMessage(ctx, msgFor(s.tenant, uuid4(), "box-a", at(), at(), "env-new"))
			return err
		}},
		{name: "enqueue", do: func(s seeded) error {
			m := msgFor(s.tenant, uuid4(), "box-a", at(), at(), "env-q")
			if _, err := pg.InsertMessage(ctx, m); err != nil {
				return err
			}
			return pg.Enqueue(ctx, s.tenant, m.MsgID, "box-b", at(), at().Add(time.Hour), 0)
		}},
		{name: "edit", do: func(s seeded) error {
			_, err := pg.ApplyEdit(ctx, s.tenant, s.msg, Edit{Body: "edited again", Msg: []byte(`{"v":1}`), Env: []byte(`{}`), EditedBy: "CLE-01", EditedAt: at()})
			return err
		}},
		{name: "kind", do: func(s seeded) error {
			_, err := pg.SetKind(ctx, s.tenant, s.msg, "msg", "CLE-01", at())
			return err
		}},
		{name: "reaction add", do: func(s seeded) error { return pg.AddReaction(ctx, s.tenant, s.msg, "HUM-2", "👀", at()) }},
		{name: "reaction remove", do: func(s seeded) error { return pg.RemoveReaction(ctx, s.tenant, s.msg, "HUM-1", "👍", at()) }},
		{name: "archive", do: func(s seeded) error {
			_, err := pg.SetArchived(ctx, s.tenant, s.msg, "CLE-01", at(), true)
			return err
		}},
		{name: "move", do: func(s seeded) error {
			_, err := pg.MoveMessage(ctx, s.tenant, s.msg, uuid4(), s.channelID, "CLE-01", at(), time.Time{})
			return err
		}},
		{name: "topic delete", do: func(s seeded) error {
			_, err := pg.DeleteTopic(ctx, s.tenant, s.msg, s.taskID)
			return err
		}},
		{name: "channel create", do: func(s seeded) error {
			return pg.CreateChannel(ctx, Channel{TenantID: s.tenant, ChannelID: uid("ch-"), Name: uid("n"), CreatedBy: "CLE-01", CreatedAt: at()})
		}},
		{name: "channel agent invite", do: func(s seeded) error {
			return pg.InviteChannelAgent(ctx, s.tenant, s.channelID, "box-b", "CLE-03", at())
		}},
		{name: "channel archive", do: func(s seeded) error { return pg.ArchiveChannel(ctx, s.tenant, s.other, s.humanID, at()) },
			prep: func(s *seeded) error {
				s.other = uid("ch-")
				return pg.CreateChannel(ctx, Channel{TenantID: s.tenant, ChannelID: s.other, Name: uid("n"), CreatedBy: s.humanID, CreatedAt: at()})
			}},
		{name: "member admit (the seeded invite)", do: func(s seeded) error {
			_, err := pg.Admit(ctx, Identity{Provider: "google", Subject: uid("sub-"), Email: "inv-" + s.tenant + "@example.com", Name: "FirstName LastName"},
				s.tenant, AdmitPolicy{}, at())
			return err
		}},
		{name: "role change", do: func(s seeded) error { return pg.SetMemberRole(ctx, s.tenant, s.humanID, "developer", "") },
			prep: func(s *seeded) error { // a second owner (the seeded invite), so the first may be demoted
				hum, err := pg.Admit(ctx, Identity{Provider: "google", Subject: uid("sub-"), Email: "inv-" + s.tenant + "@example.com", Name: "FirstName LastName"},
					s.tenant, AdmitPolicy{}, at())
				if err == nil {
					err = pg.SetMemberRole(ctx, s.tenant, hum, RoleTenantOwner, "")
				}
				return err
			}},
		{name: "read marks", do: func(s seeded) error {
			return pg.SaveReadMarks(ctx, s.tenant, s.humanID, map[string]ReadMark{"ch:lobby": {At: at().Add(time.Hour), MsgID: "m2"}}, at())
		}},
	}
	for _, w := range writers {
		t.Run(w.name, func(t *testing.T) {
			s := seeded{crossSeed: seedTenantAll(t, pg)}
			s.msg = s.msgID
			if w.prep != nil {
				if err := w.prep(&s); err != nil {
					t.Fatal(err)
				}
			}
			before := stampNow(t, pg, s.tenant)
			if err := w.do(s); err != nil {
				t.Fatal(err)
			}
			if got := stampNow(t, pg, s.tenant); got <= before {
				t.Errorf("%s left the stamp at %d", w.name, got)
			}
		})
	}
	t.Run("retention", func(t *testing.T) {
		s := seedTenantAll(t, pg)
		now := time.Now().UTC()
		m := msgFor(s.tenant, uuid4(), "box-a", now, now, "env-old")
		m.ExpiresAt = now.Add(-time.Minute)
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		before := stampNow(t, pg, s.tenant)
		r, err := pg.Sweep(ctx, now)
		if err != nil {
			t.Fatal(err)
		}
		if r.Purged == 0 {
			t.Fatal("the sweep purged nothing (control)")
		}
		if got := stampNow(t, pg, s.tenant); got <= before {
			t.Errorf("a retention purge left the stamp at %d", got)
		}
	})
}

// TestChangeStampOncePerTxConcurrent: concurrent sends of one tenant each
// add exactly 1 (one bump per transaction, none lost, no deadlock), and a
// statement writing several rows adds 1.
func TestChangeStampOncePerTxConcurrent(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tenant := newTenant(t, pg)
	before := stampNow(t, pg, tenant)
	const n = 24
	var wg sync.WaitGroup
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			now := time.Now().UTC()
			_, err := pg.InsertMessage(ctx, msgFor(tenant, uuid4(), "box-a", now, now, "env"))
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if got := stampNow(t, pg, tenant); got != before+n {
		t.Fatalf("%d concurrent sends moved the stamp %d -> %d, want +%d", n, before, got, n)
	}
	before += n
	if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE messages SET body = body WHERE tenant_id = $1`, tenant)
		if err == nil && tag.RowsAffected() != n {
			t.Errorf("updated %d rows, want %d", tag.RowsAffected(), n)
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if got := stampNow(t, pg, tenant); got != before+1 {
		t.Fatalf("one %d-row statement moved the stamp %d -> %d, want +1", n, before, got)
	}
}

// TestChangeStampExpiryAndSettle: Expired sees a message leave the live
// window in (since, now]; Settled is false right after a write and true
// once the last change is older than ChangeStampSettle.
func TestChangeStampExpiryAndSettle(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tenant := newTenant(t, pg)
	now := time.Now().UTC()
	m := msgFor(tenant, uuid4(), "box-a", now, now, "env")
	m.ExpiresAt = now.Add(time.Minute)
	if _, err := pg.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	c, err := pg.ChangeStamp(ctx, tenant, now, now.Add(2*time.Minute))
	if err != nil || !c.Expired {
		t.Fatalf("expiry inside (since, now]: %+v %v", c, err)
	}
	if c.Settled {
		t.Fatalf("settled right after a write: %+v", c)
	}
	if c, err = pg.ChangeStamp(ctx, tenant, now.Add(2*time.Minute), now.Add(3*time.Minute)); err != nil || c.Expired {
		t.Fatalf("no expiry inside (since, now]: %+v %v", c, err)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE tenant_change_stamps SET changed_at = changed_at - interval '1 minute' WHERE tenant_id = $1`, tenant)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if c, err = pg.ChangeStamp(ctx, tenant, now, now); err != nil || !c.Settled {
		t.Fatalf("a change a minute old is not settled: %+v %v", c, err)
	}
}
