package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// visitorPost is a post of v as the hub builds it (hub/embed_visitor.go).
func visitorPost(v EmbedVisitor, body string, now time.Time) EmbedPost {
	return EmbedPost{MsgID: uuid4(), TaskID: v.VisitorID, TS: now, Body: body, Inner: []byte(`{"v":1}`),
		Canon: []byte("env-" + body), At: now, Expires: now.Add(30 * day)}
}

// channelRow is a staff-side row of the same shape in channel ch.
func channelRow(v EmbedVisitor, ch, from, body string, now time.Time) Message {
	m := msgFor(v.TenantID, v.VisitorID, "box-wui", now, now, "env-"+body)
	m.FromBox, m.FromID, m.ToID, m.Kind, m.Body, m.Channel, m.IsParent = "box-wui", from, "ALL-0", "note", body, ch, 1
	return m
}

// TestEmbedVisitorPostAndRead: the runtime role posts into visitor A's
// channel and reads back only A's channel, oldest first, its own line marked
// mine and a staff reply in the same channel not; visitor B reads none of it.
// A row naming another channel (B's, lobby, a staff channel, a DM) is refused
// by the channel scope's WITH CHECK and writes nothing. CONTROL: the same
// lobby row, inserted by the store's normal tenant path, is stored, so the
// refusal is the channel scope's.
func TestEmbedVisitorPostAndRead(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	a := newTenant(t, pg)
	embed := seedEmbedCustomer(t, pg, a, true)
	va, _ := mintVisitor(t, rt, a, embed, now)
	vb, _ := mintVisitor(t, rt, a, embed, now)

	mine := visitorPost(va, "hello from A", now)
	if err := rt.PostEmbedVisitorMessage(ctx, va, mine); err != nil {
		t.Fatal(err)
	}
	if err := rt.PostEmbedVisitorMessage(ctx, va, mine); !errors.Is(err, ErrConflict) {
		t.Errorf("the same msg id again: %v, want ErrConflict", err)
	}
	reply := channelRow(va, va.ChannelID, "HUM-staff", "staff answer", now.Add(time.Second))
	if _, err := pg.InsertMessage(ctx, reply); err != nil {
		t.Fatal(err)
	}
	got, err := rt.EmbedVisitorMessages(ctx, va, 50)
	if err != nil || len(got) != 2 || got[0].MsgID != mine.MsgID || !got[0].Mine || got[0].Body != "hello from A" ||
		got[1].MsgID != reply.MsgID || got[1].Mine {
		t.Fatalf("A reads %+v (%v), want its line (mine) then the staff answer", got, err)
	}
	if last, _ := rt.EmbedVisitorMessages(ctx, va, 1); len(last) != 1 || last[0].MsgID != reply.MsgID {
		t.Errorf("limit 1 reads %+v, want the newest line only", last)
	}
	if b, err := rt.EmbedVisitorMessages(ctx, vb, 50); err != nil || len(b) != 0 {
		t.Errorf("B reads %+v (%v), want nothing", b, err)
	}

	// The post names no channel: it is always the visitor row's. A row
	// forged into another channel under A's scope fails the policy's WITH
	// CHECK and writes nothing.
	staff := uid("s-")
	if err := pg.CreateChannel(ctx, Channel{TenantID: a, ChannelID: staff, Name: staff, CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	before := countOf(t, pg, "messages", a)
	for what, ch := range map[string]any{"B's channel": vb.ChannelID, "lobby": "lobby", "a staff channel": staff, "a DM": nil} {
		err := rt.inChannel(ctx, a, va.ChannelID, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id,
				kind, body, files, msg, env_sig, env, received_at, expires_at)
				VALUES ($1, gen_random_uuid(), gen_random_uuid(), $2, now(), 'box-wui', $3, 'box-wui', 'ALL-0', 'note', 'forged',
				'[]', '{}', '', 'x', now(), now() + interval '1 day')`, a, ch, va.HumanID)
			return err
		})
		if err == nil {
			t.Errorf("A's scope wrote into %s", what)
		}
	}
	if n := countOf(t, pg, "messages", a); n != before {
		t.Errorf("refused posts wrote: %d messages, want %d", n, before)
	}
	if ok, err := rt.InsertMessage(ctx, channelRow(va, "lobby", va.HumanID, "control", now)); err != nil || !ok {
		t.Fatalf("CONTROL: the lobby row through the tenant path: %v %v", ok, err)
	}
}

// TestEmbedVisitorErase: the erasure removes A's messages, channel,
// channel_humans row, visitor row (so the token), channel_guest membership
// and HUM row; erasing again is a no-op. CONTROL: visitor B, erased by
// nobody, keeps every one of them.
func TestEmbedVisitorErase(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	a := newTenant(t, pg)
	embed := seedEmbedCustomer(t, pg, a, true)
	va, ahash := mintVisitor(t, rt, a, embed, now)
	vb, bhash := mintVisitor(t, rt, a, embed, now)
	for _, v := range []EmbedVisitor{va, vb} {
		if err := rt.PostEmbedVisitorMessage(ctx, v, visitorPost(v, "hi", now)); err != nil {
			t.Fatal(err)
		}
	}
	if err := rt.EraseEmbedVisitor(ctx, va); err != nil {
		t.Fatal(err)
	}
	if err := rt.EraseEmbedVisitor(ctx, va); err != nil {
		t.Errorf("a second erasure: %v, want a no-op", err)
	}
	left := func(v EmbedVisitor) (n [5]int) {
		t.Helper()
		err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT
				(SELECT count(*) FROM messages WHERE tenant_id = $1 AND channel = $2),
				(SELECT count(*) FROM channels WHERE tenant_id = $1 AND channel_id = $2),
				(SELECT count(*) FROM channel_humans WHERE tenant_id = $1 AND channel_id = $2),
				(SELECT count(*) FROM tenant_memberships WHERE tenant_id = $1 AND human_id = $3),
				(SELECT count(*) FROM humans WHERE human_id = $3)`, a, v.ChannelID, v.HumanID).Scan(&n[0], &n[1], &n[2], &n[3], &n[4])
		})
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	if n := left(va); n != [5]int{} {
		t.Errorf("after the erasure A keeps messages/channel/channel_humans/membership/HUM %v, want none", n)
	}
	if _, err := rt.EmbedVisitorByToken(ctx, embed, ahash, now); !errors.Is(err, ErrNotFound) {
		t.Errorf("A's token after the erasure: %v, want ErrNotFound", err)
	}
	if n := left(vb); n != [5]int{1, 1, 1, 1, 1} {
		t.Errorf("CONTROL: B keeps %v, want one of each", n)
	}
	if _, err := rt.EmbedVisitorByToken(ctx, embed, bhash, now); err != nil {
		t.Errorf("CONTROL: B's token: %v", err)
	}
}

// TestMemberListsLeaveOutChannelGuests (c-902's T104 point): a visitor's
// tenant_memberships row is a row like a member's, so every member list
// leaves out channel_guest: the member directory, the people list, the
// avatars, the member count and the guest's own workspace list. CONTROL: the
// raw membership count holds the guest, and the staff member is in every list.
func TestMemberListsLeaveOutChannelGuests(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	a := newTenant(t, pg)
	embed := seedEmbedCustomer(t, pg, a, true)
	v, _ := mintVisitor(t, rt, a, embed, now)
	staff := seedStaffMember(t, pg, a, now)
	if n := countOf(t, pg, "tenant_memberships", a); n != 2 {
		t.Fatalf("CONTROL: %d membership rows, want the staff member and the guest", n)
	}

	members, err := rt.ListMembers(ctx, a)
	if err != nil || len(members) != 1 || members[0].HumanID != staff {
		t.Errorf("ListMembers = %+v (%v), want the staff member only", members, err)
	}
	people, err := rt.TenantHumans(ctx, a)
	if err != nil || len(people) != 1 || people[0].HumanID != staff {
		t.Errorf("TenantHumans = %+v (%v), want the staff member only", people, err)
	}
	avatars, err := rt.TenantAvatars(ctx, a)
	if _, ok := avatars[v.HumanID]; err != nil || ok || len(avatars) != 1 {
		t.Errorf("TenantAvatars = %v (%v), want the staff member only", avatars, err)
	}
	if n, err := rt.CountMembers(ctx, a); err != nil || n != 1 {
		t.Errorf("CountMembers = %d (%v), want 1", n, err)
	}
	if ms, err := rt.Memberships(ctx, v.HumanID); err != nil || len(ms) != 0 {
		t.Errorf("the guest's own workspaces = %+v (%v), want none", ms, err)
	}
	if ms, err := rt.Memberships(ctx, staff); err != nil || len(ms) != 1 || ms[0].TenantID != a {
		t.Errorf("CONTROL: the staff member's workspaces = %+v (%v)", ms, err)
	}
}

// seedStaffMember is one developer of tenant, as an accepted invite leaves it.
func seedStaffMember(t *testing.T, pg *Postgres, tenant string, now time.Time) string {
	t.Helper()
	var hum string
	err := pg.inTenant(context.Background(), tenant, func(tx pgx.Tx) error {
		if err := tx.QueryRow(context.Background(), `INSERT INTO humans (email, display_name, created_at)
			VALUES ($1, 'Staff', $2) RETURNING human_id`, uid("staff-")+"@example.com", now).Scan(&hum); err != nil {
			return err
		}
		_, err := tx.Exec(context.Background(), `INSERT INTO tenant_memberships (tenant_id, human_id, role, created_at, admitted_by)
			VALUES ($1, $2, 'developer', $3, 'invite')`, tenant, hum, now)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return hum
}
