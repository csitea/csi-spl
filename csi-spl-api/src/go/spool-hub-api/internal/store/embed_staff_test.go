package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// specs/121 T106: the staff side of the visitor channels (embed_staff.go,
// rdb 0172). Postgres only (hub-pg.tst.sh).

// exportHidden is how many of tenant's rows of tb rdb 0172 keeps from the
// export role: the visitor channels, their messages, the channel_guest
// memberships. Counted as the operator, from embed_visitors.
func exportHidden(t *testing.T, pg *Postgres, tb, tenant string) int {
	t.Helper()
	q := map[string]string{
		"channels": `SELECT count(*) FROM channels c WHERE c.tenant_id = $1
			AND EXISTS (SELECT 1 FROM embed_visitors v WHERE v.tenant_id = c.tenant_id AND v.channel_id = c.channel_id)`,
		"messages": `SELECT count(*) FROM messages m WHERE m.tenant_id = $1
			AND EXISTS (SELECT 1 FROM embed_visitors v WHERE v.tenant_id = m.tenant_id AND v.channel_id = m.channel)`,
		"tenant_memberships": `SELECT count(*) FROM tenant_memberships WHERE tenant_id = $1 AND role = 'channel_guest'`,
	}[tb]
	if q == "" {
		return 0
	}
	var n int
	if err := pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), q, tenant).Scan(&n)
	}); err != nil {
		t.Fatal(err)
	}
	return n
}

// seedRoleMember is one member of tenant with role.
func seedRoleMember(t *testing.T, pg *Postgres, tenant, role string, now time.Time) string {
	t.Helper()
	var hum string
	err := pg.inTenant(context.Background(), tenant, func(tx pgx.Tx) error {
		if err := tx.QueryRow(context.Background(), `INSERT INTO humans (email, display_name, created_at)
			VALUES ($1, 'Staff', $2) RETURNING human_id`, uid("staff-")+"@example.com", now).Scan(&hum); err != nil {
			return err
		}
		_, err := tx.Exec(context.Background(), `INSERT INTO tenant_memberships (tenant_id, human_id, role, created_at, admitted_by)
			VALUES ($1, $2, $3, $4, 'invite')`, tenant, hum, role, now)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return hum
}

// seatsOf is the human ids seated in tenant's channel ch.
func seatsOf(t *testing.T, pg *Postgres, tenant, ch string) map[string]bool {
	t.Helper()
	out := map[string]bool{}
	if err := pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		return eachRow(context.Background(), tx, `SELECT human_id FROM channel_humans WHERE tenant_id = $1 AND channel_id = $2`,
			[]any{tenant, ch}, func(r pgx.Rows) error {
				var h string
				err := r.Scan(&h)
				out[h] = true
				return err
			})
	}); err != nil {
		t.Fatal(err)
	}
	return out
}

// exportSees counts, as the export role in workspace, the rows of tb whose
// col is val.
func exportSees(ctx context.Context, t *testing.T, tx pgx.Tx, tb, col, val string) int {
	t.Helper()
	var n int
	q := `SELECT count(*) FROM ` + pgx.Identifier{tb}.Sanitize() + ` WHERE ` + pgx.Identifier{col}.Sanitize() + `::text = $1`
	if err := tx.QueryRow(ctx, q, val).Scan(&n); err != nil {
		t.Fatalf("%s: %v", tb, err)
	}
	return n
}

// TestPublicExportExcludesVisitorChannels (the T106 done line, spec 4.3):
// a visitor message planted in the exported workspace is absent for the
// export role, and so are its channel and the visitor's channel_guest
// membership, with the tenant setting on and with the operator scope.
// CONTROLS: a staff channel's message of the same workspace is present (not
// a vacuous zero); the hub's own tenant scope still reads the visitor
// message; and dropping rdb 0172's three policies (in a savepoint) shows
// all three rows to the export role, so those policies are what hold.
func TestPublicExportExcludesVisitorChannels(t *testing.T) {
	pg := rlsStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	a := newTenant(t, pg)
	v, _ := mintVisitor(t, pg, a, seedEmbedCustomer(t, pg, a, true), now)
	planted := visitorPost(v, "visitor: my phone number is in here", now)
	if err := pg.PostEmbedVisitorMessage(ctx, v, planted); err != nil {
		t.Fatal(err)
	}
	staff := uid("s-")
	if err := pg.CreateChannel(ctx, Channel{TenantID: a, ChannelID: staff, Name: staff, CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	ctl := channelRow(v, staff, "HUM-1", "a staff line", now)
	if _, err := pg.InsertMessage(ctx, ctl); err != nil {
		t.Fatal(err)
	}
	if err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		if n := exportSees(ctx, t, tx, "messages", "msg_id", planted.MsgID); n != 1 {
			t.Errorf("CONTROL: the hub's tenant scope reads %d of the visitor message, want 1", n)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	hidden := []struct{ tb, col, val string }{
		{"messages", "msg_id", planted.MsgID}, {"channels", "channel_id", v.ChannelID}, {"tenant_memberships", "human_id", v.HumanID},
	}
	asExportRole(t, pg, a, func(ctx context.Context, tx pgx.Tx) {
		for _, scope := range []string{"", "operator"} {
			setScope(ctx, t, tx, a, scope)
			for _, h := range hidden {
				if n := exportSees(ctx, t, tx, h.tb, h.col, h.val); n != 0 {
					t.Errorf("scope=%q: the export role sees %d %s row(s) of the visitor (%s)", scope, n, h.tb, h.val)
				}
			}
			if n := exportSees(ctx, t, tx, "messages", "msg_id", ctl.MsgID); n != 1 {
				t.Errorf("CONTROL scope=%q: the export role sees %d of the staff line, want 1", scope, n)
			}
		}
	})
	exportNoVisitorsDropControl(t, pg, a, hidden)
}

// exportNoVisitorsDropControl: without rdb 0172's policies the export role
// reads every hidden row. Its own rolled-back transaction locks the three
// tables FIRST, as exportScopeDropControl does and for its reason (an ANALYZE
// waiting on the GRANT's pg_class rows deadlocks a later DROP POLICY).
func exportNoVisitorsDropControl(t *testing.T, pg *Postgres, a string, hidden []struct{ tb, col, val string }) {
	t.Helper()
	lock := []string{`LOCK TABLE messages, channels, tenant_memberships IN ACCESS EXCLUSIVE MODE`}
	asExportRoleAfter(t, pg, a, lock, func(ctx context.Context, tx pgx.Tx) {
		for _, q := range []string{`RESET ROLE`, `DROP POLICY public_export_no_visitors ON messages`,
			`DROP POLICY public_export_no_visitors ON channels`, `DROP POLICY public_export_no_visitors ON tenant_memberships`,
			`SET LOCAL ROLE spool_public_export`} {
			if _, err := tx.Exec(ctx, q); err != nil {
				t.Fatalf("%s: %v", q, err)
			}
		}
		setScope(ctx, t, tx, a, "")
		for _, h := range hidden {
			if n := exportSees(ctx, t, tx, h.tb, h.col, h.val); n != 1 {
				t.Errorf("control is void: without public_export_no_visitors the export role sees %d %s row(s), want 1", n, h.tb)
			}
		}
	})
}

// TestEmbedStaffLeadBlockList: staff mark visitor A a lead and block
// visitor B. The list shows A a lead and live, B blocked and not live; B's
// token stops resolving while its channel and message stay. Clearing the
// lead clears it; a second block keeps the first time. A channel that is no
// visitor channel of the workspace (a staff channel, another workspace's
// visitor) is ErrNotFound and changes nothing. CONTROL: B's token resolved
// before the block.
func TestEmbedStaffLeadBlockList(t *testing.T) {
	pg := rlsStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	a, other := newTenant(t, pg), newTenant(t, pg)
	embed := seedEmbedCustomer(t, pg, a, true)
	va, _ := mintVisitor(t, pg, a, embed, now)
	vb, hb := mintVisitor(t, pg, a, embed, now)
	vo, _ := mintVisitor(t, pg, other, seedEmbedCustomer(t, pg, other, true), now)
	if err := pg.PostEmbedVisitorMessage(ctx, vb, visitorPost(vb, "spam", now)); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.EmbedVisitorByToken(ctx, embed, hb, now); err != nil {
		t.Fatalf("CONTROL: B's token before the block: %v", err)
	}
	if err := pg.SetEmbedLead(ctx, a, va.ChannelID, true, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.BlockEmbedVisitor(ctx, a, vb.ChannelID, now); err != nil {
		t.Fatal(err)
	}
	if err := pg.BlockEmbedVisitor(ctx, a, vb.ChannelID, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.EmbedVisitorByToken(ctx, embed, hb, now.Add(time.Second)); !errors.Is(err, ErrNotFound) {
		t.Errorf("B's token after the block: %v, want ErrNotFound", err)
	}
	if _, err := pg.Channel(ctx, a, vb.ChannelID); err != nil {
		t.Errorf("B's channel after the block: %v, want kept", err)
	}
	got := map[string]EmbedVisitorChannel{}
	list, err := pg.EmbedVisitorChannels(ctx, a, now.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range list {
		got[c.ChannelID] = c
	}
	if c := got[va.ChannelID]; len(list) != 2 || !c.LeadAt.Equal(now) || !c.BlockedAt.IsZero() || !c.Live {
		t.Errorf("A in the list: %+v (of %d), want a live lead", c, len(list))
	}
	if c := got[vb.ChannelID]; !c.BlockedAt.Equal(now) || c.Live || !c.LeadAt.IsZero() || !c.LastAt.Equal(now) {
		t.Errorf("B in the list: %+v, want blocked at the first block, not live, last message now", c)
	}
	if err := pg.SetEmbedLead(ctx, a, va.ChannelID, false, now); err != nil {
		t.Fatal(err)
	}
	if list, _ := pg.EmbedVisitorChannels(ctx, a, now); len(list) == 0 || (list[0].ChannelID == va.ChannelID && !list[0].LeadAt.IsZero()) ||
		(len(list) > 1 && list[1].ChannelID == va.ChannelID && !list[1].LeadAt.IsZero()) {
		t.Errorf("after clearing A's lead: %+v", list)
	}
	staff := uid("s-")
	if err := pg.CreateChannel(ctx, Channel{TenantID: a, ChannelID: staff, Name: staff, CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	for what, ch := range map[string]string{"a staff channel": staff, "another workspace's visitor": vo.ChannelID, "lobby": "lobby"} {
		if err := pg.SetEmbedLead(ctx, a, ch, true, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("lead on %s: %v, want ErrNotFound", what, err)
		}
		if err := pg.BlockEmbedVisitor(ctx, a, ch, now); !errors.Is(err, ErrNotFound) {
			t.Errorf("block on %s: %v, want ErrNotFound", what, err)
		}
	}
	if list, _ := pg.EmbedVisitorChannels(ctx, other, now); len(list) != 1 || !list[0].LeadAt.IsZero() || !list[0].Live {
		t.Errorf("the other workspace's visitor after A's staff writes: %+v", list)
	}
}

// TestEmbedTriageSeatsAndQuiet: the first triage of a workspace makes the
// private #sales channel with its staff (biz_owner, admin) seated, never a
// developer; a new visitor channel seats the same staff; a later line (not
// new) seats nobody in the visitor channel again. EmbedQuiet is true only
// for a channel made before the quiet line with no other message since.
// CONTROL: the developer exists in the workspace (seated nowhere by role
// alone), so leaving them out is the role filter's doing.
func TestEmbedTriageSeatsAndQuiet(t *testing.T) {
	pg := rlsStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	a := newTenant(t, pg)
	owner, admin := seedRoleMember(t, pg, a, rbac.BizOwner, now), seedRoleMember(t, pg, a, rbac.Admin, now)
	dev := seedRoleMember(t, pg, a, rbac.Developer, now)
	embed := seedEmbedCustomer(t, pg, a, true)
	old, _ := mintVisitor(t, pg, a, embed, now.Add(-2*day))
	if err := pg.EmbedTriageSeats(ctx, a, old.ChannelID, true, now); err != nil {
		t.Fatal(err)
	}
	if c, err := pg.Channel(ctx, a, EmbedSalesChannel); err != nil || c.CreatedBy != "hub" {
		t.Fatalf("#sales after the first triage: %+v %v", c, err)
	}
	for _, ch := range []string{EmbedSalesChannel, old.ChannelID} {
		s := seatsOf(t, pg, a, ch)
		if !s[owner] || !s[admin] || s[dev] {
			t.Errorf("seats of %s: %v, want owner %s and admin %s, not developer %s", ch, s, owner, admin, dev)
		}
	}
	if role, err := pg.MemberRole(ctx, dev, a); err != nil || role != rbac.Developer {
		t.Fatalf("CONTROL: the developer's role: %q %v", role, err)
	}
	if err := pg.RemoveChannelHuman(ctx, a, old.ChannelID, admin); err != nil {
		t.Fatal(err)
	}
	if err := pg.EmbedTriageSeats(ctx, a, old.ChannelID, false, now); err != nil {
		t.Fatal(err)
	}
	if s := seatsOf(t, pg, a, old.ChannelID); s[admin] {
		t.Error("a later triage line re-seated the admin who left the visitor channel")
	}
	if err := pg.EmbedTriageSeats(ctx, a, "lobby", true, now); !errors.Is(err, ErrNotFound) {
		t.Errorf("triage seats for lobby: %v, want ErrNotFound", err)
	}

	since := now.Add(-day)
	first := visitorPost(old, "back again", now)
	if err := pg.PostEmbedVisitorMessage(ctx, old, first); err != nil {
		t.Fatal(err)
	}
	if q, err := pg.EmbedQuiet(ctx, a, old.ChannelID, first.MsgID, since); err != nil || !q {
		t.Errorf("the first post in a 2-day-old silent channel: quiet=%v %v, want true", q, err)
	}
	second := visitorPost(old, "and again", now.Add(time.Minute))
	if err := pg.PostEmbedVisitorMessage(ctx, old, second); err != nil {
		t.Fatal(err)
	}
	if q, _ := pg.EmbedQuiet(ctx, a, old.ChannelID, second.MsgID, since); q {
		t.Error("the second post of the day: quiet, want not (the first one is newer than the quiet line)")
	}
	fresh, _ := mintVisitor(t, pg, a, embed, now)
	p := visitorPost(fresh, "hi", now)
	if err := pg.PostEmbedVisitorMessage(ctx, fresh, p); err != nil {
		t.Fatal(err)
	}
	if q, _ := pg.EmbedQuiet(ctx, a, fresh.ChannelID, p.MsgID, since); q {
		t.Error("the first post of a channel made today: quiet, want not (its mint had the line)")
	}
}

// TestEmbedRetention (spec 4.4): due at now-30d are the visitors made before
// it with no message since and no lead mark; retiring one removes its
// channel, messages, visitor row and HUM. A lead, a channel with a message
// inside the 30 days and a channel made inside them are kept. Retire
// re-checks: a visitor that posted after the read is kept (false).
// CONTROL: the old visitor's message existed before the sweep.
func TestEmbedRetention(t *testing.T) {
	pg := rlsStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	a := newTenant(t, pg)
	embed := seedEmbedCustomer(t, pg, a, true)
	gone, _ := mintVisitor(t, pg, a, embed, now.Add(-40*day))
	lead, _ := mintVisitor(t, pg, a, embed, now.Add(-40*day))
	busy, _ := mintVisitor(t, pg, a, embed, now.Add(-40*day))
	young, _ := mintVisitor(t, pg, a, embed, now.Add(-day))
	if err := pg.PostEmbedVisitorMessage(ctx, gone, visitorPost(gone, "old question", now.Add(-35*day))); err != nil {
		t.Fatal(err)
	}
	if err := pg.PostEmbedVisitorMessage(ctx, busy, visitorPost(busy, "recent question", now.Add(-day))); err != nil {
		t.Fatal(err)
	}
	if err := pg.SetEmbedLead(ctx, a, lead.ChannelID, true, now); err != nil {
		t.Fatal(err)
	}
	before := now.Add(-30 * day)
	if n := countOf(t, pg, "messages", a); n != 2 {
		t.Fatalf("CONTROL: %d messages before the sweep, want 2", n)
	}
	due, err := pg.EmbedRetentionDue(ctx, before, 1000)
	if err != nil {
		t.Fatal(err)
	}
	mine := map[string]EmbedVisitor{}
	for _, v := range due {
		if v.TenantID == a {
			mine[v.ChannelID] = v
		}
	}
	if _, ok := mine[gone.ChannelID]; len(mine) != 1 || !ok {
		t.Fatalf("due: %+v, want only %s", mine, gone.ChannelID)
	}
	if ok, err := pg.RetireEmbedVisitor(ctx, busy, before); err != nil || ok {
		t.Errorf("retire a visitor that posted inside the 30 days: %v %v, want kept", ok, err)
	}
	if ok, err := pg.RetireEmbedVisitor(ctx, gone, before); err != nil || !ok {
		t.Fatalf("retire the due visitor: %v %v", ok, err)
	}
	if ok, err := pg.RetireEmbedVisitor(ctx, gone, before); err != nil || ok {
		t.Errorf("retire twice: %v %v, want false", ok, err)
	}
	if _, err := pg.Channel(ctx, a, gone.ChannelID); !errors.Is(err, ErrNotFound) {
		t.Errorf("the retired channel: %v, want ErrNotFound", err)
	}
	if n := countOf(t, pg, "messages", a); n != 1 {
		t.Errorf("%d messages after the sweep, want 1 (busy's)", n)
	}
	var humans int
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM humans WHERE human_id = $1`, gone.HumanID).Scan(&humans)
	}); err != nil || humans != 0 {
		t.Errorf("the retired visitor's HUM: %d (%v), want gone", humans, err)
	}
	for _, v := range []EmbedVisitor{lead, busy, young} {
		if _, err := pg.Channel(ctx, a, v.ChannelID); err != nil {
			t.Errorf("kept channel %s: %v", v.ChannelID, err)
		}
	}
}
