package store

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// seatMember admits a fresh human and seats it in tenant with role. Returns the
// human id.
func seatMember(t *testing.T, pg *Postgres, tenant, role string) string {
	t.Helper()
	ctx := context.Background()
	hum, err := pg.Admit(ctx, Identity{Provider: "google", Subject: uid("m-"), Name: "FirstName LastName"}, "", AdmitPolicy{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by)
			VALUES ($1, $2, $3, 'operator')`, tenant, hum, role)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return hum
}

// TestStartClone: a clone snapshots the target's role and its non-private
// channel memberships, is technical (excluded from member lists and seat
// counts), and its member_clones row is the audit trail.
func TestStartClone(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	admin := seatMember(t, pg, tid, "admin")
	target := seatMember(t, pg, tid, "developer")

	pub := uid("ch-")
	priv := uid("ch-")
	for _, ch := range []string{pub, priv} {
		if err := pg.CreateChannel(ctx, Channel{TenantID: tid, ChannelID: ch, Name: ch, CreatedBy: admin}); err != nil {
			t.Fatal(err)
		}
		if err := pg.AddChannelHumans(ctx, tid, ch, []string{target}, admin, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	// Make priv a private (DM-like) channel; the clone must not copy it.
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE channels SET is_private = true WHERE tenant_id = $1 AND channel_id = $2`, tid, priv)
		return err
	}); err != nil {
		t.Fatal(err)
	}

	usersBefore, _ := pg.CountMembers(ctx, tid)
	now := time.Now().UTC().Truncate(time.Microsecond)
	cl, err := pg.StartClone(ctx, CloneStart{TenantID: tid, TargetHum: target, AdminName: "Admin", CreatedBy: admin,
		ExpiresAt: now.Add(time.Hour)}, now)
	if err != nil {
		t.Fatal(err)
	}
	if cl.CloneHum == "" || cl.Role != "developer" || cl.TargetHum != target || cl.CreatedBy != admin {
		t.Fatalf("clone row: %+v", cl)
	}
	// The clone resolves the target's role (this is the whole point).
	if r, err := pg.MemberRole(ctx, cl.CloneHum, tid); err != nil || r != "developer" {
		t.Fatalf("clone MemberRole = %q %v, want developer", r, err)
	}
	// It copied the public channel, not the private one.
	chans, err := pg.HumanChannels(ctx, tid, cl.CloneHum)
	if err != nil {
		t.Fatal(err)
	}
	if len(chans) != 1 || chans[0] != pub {
		t.Fatalf("clone channels = %v, want [%s] (private excluded)", chans, pub)
	}
	// It is technical: not a seat, not in the member list, not in the roster.
	if usersAfter, _ := pg.CountMembers(ctx, tid); usersAfter != usersBefore {
		t.Errorf("CountMembers %d -> %d: a clone must not count as a seat", usersBefore, usersAfter)
	}
	members, err := pg.ListMembers(ctx, tid)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range members {
		if m.HumanID == cl.CloneHum {
			t.Error("ListMembers lists the clone")
		}
	}
	hs, _ := pg.TenantHumans(ctx, tid)
	for _, h := range hs {
		if h.HumanID == cl.CloneHum {
			t.Error("TenantHumans lists the clone")
		}
	}
	// The audit trail has exactly this live clone, carrying the target's name
	// for the WUI banner.
	list, err := pg.ListClones(ctx, tid)
	if err != nil || len(list) != 1 || list[0].CloneHum != cl.CloneHum || list[0].EndedAt != nil {
		t.Fatalf("ListClones = %+v %v", list, err)
	}
	got, err := pg.Clone(ctx, tid, cl.CloneHum)
	if err != nil || got.TargetName == "" || got.TargetHum != target {
		t.Fatalf("Clone target name/hum = %q/%q %v", got.TargetName, got.TargetHum, err)
	}
	// specs/054 §9 CONTROL: the clone has NO human_identities, so no provider
	// (password, Google, keys…) can ever authenticate as it — the only session
	// for it is the one the act-as handler mints.
	var ids int
	if err := pg.pool.QueryRow(ctx, `SELECT count(*) FROM human_identities WHERE human_id = $1`, cl.CloneHum).Scan(&ids); err != nil {
		t.Fatal(err)
	}
	if ids != 0 {
		t.Errorf("clone has %d human_identities, want 0 (nothing may sign in as it)", ids)
	}
}

// TestStartCloneNotMember: cloning a non-member is refused, nothing minted.
func TestStartCloneNotMember(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	admin := seatMember(t, pg, tid, "admin")
	now := time.Now().UTC()
	if _, err := pg.StartClone(ctx, CloneStart{TenantID: tid, TargetHum: "HUM-nobody", CreatedBy: admin,
		ExpiresAt: now.Add(time.Hour)}, now); err != ErrNotFound {
		t.Fatalf("StartClone(non-member) = %v, want ErrNotFound", err)
	}
	if list, _ := pg.ListClones(ctx, tid); len(list) != 0 {
		t.Fatalf("a refused start left %d clone row(s)", len(list))
	}
}

// TestStopClone: stop disables the clone, strips its membership and channels,
// marks the audit row, and is idempotent (a second stop is ErrNotFound).
func TestStopClone(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	admin := seatMember(t, pg, tid, "admin")
	target := seatMember(t, pg, tid, "developer")
	now := time.Now().UTC().Truncate(time.Microsecond)
	cl, err := pg.StartClone(ctx, CloneStart{TenantID: tid, TargetHum: target, CreatedBy: admin,
		ExpiresAt: now.Add(time.Hour)}, now)
	if err != nil {
		t.Fatal(err)
	}
	// a message the clone authored while acting (specs/054 §4 step 2: kept on stop)
	m := msgFor(tid, uuid4(), "box-a", now, now, "env-"+tid)
	m.FromID, m.Channel = cl.CloneHum, "lobby"
	if _, err := pg.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	if err := pg.StopClone(ctx, tid, cl.CloneHum, "stop", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	// specs/054 §9 CONTROL (owner default, §8 Q2 "keep"): the clone's messages
	// survive the stop — only its memberships and sign-in are removed.
	if ok, err := pg.HasMessage(ctx, tid, m.MsgID); err != nil || !ok {
		t.Errorf("clone's message after stop: ok=%v err=%v, want kept", ok, err)
	}
	if r, err := pg.MemberRole(ctx, cl.CloneHum, tid); err == nil && r != "" {
		t.Errorf("stopped clone still resolves role %q", r)
	}
	got, err := pg.Clone(ctx, tid, cl.CloneHum)
	if err != nil {
		t.Fatal(err)
	}
	if got.EndedAt == nil || got.EndReason != "stop" {
		t.Errorf("audit row after stop: ended=%v reason=%q", got.EndedAt, got.EndReason)
	}
	if err := pg.StopClone(ctx, tid, cl.CloneHum, "stop", now.Add(2*time.Minute)); err != ErrNotFound {
		t.Errorf("second stop = %v, want ErrNotFound", err)
	}
}

// TestSweepClones: a clone past its expiry is expired by the sweep exactly as a
// stop, cross-tenant, with end_reason 'expired'.
func TestSweepClones(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	admin := seatMember(t, pg, tid, "admin")
	target := seatMember(t, pg, tid, "developer")
	start := time.Now().UTC().Truncate(time.Microsecond)
	cl, err := pg.StartClone(ctx, CloneStart{TenantID: tid, TargetHum: target, CreatedBy: admin,
		ExpiresAt: start.Add(-time.Minute)}, start.Add(-time.Hour)) // already expired
	if err != nil {
		t.Fatal(err)
	}
	n, err := pg.SweepClones(ctx, start)
	if err != nil || n < 1 {
		t.Fatalf("SweepClones = %d %v, want >=1", n, err)
	}
	got, err := pg.Clone(ctx, tid, cl.CloneHum)
	if err != nil {
		t.Fatal(err)
	}
	if got.EndedAt == nil || got.EndReason != "expired" {
		t.Errorf("swept clone audit: ended=%v reason=%q", got.EndedAt, got.EndReason)
	}
	endedAt := *got.EndedAt
	if r, err := pg.MemberRole(ctx, cl.CloneHum, tid); err == nil && r != "" {
		t.Errorf("expired clone still resolves role %q", r)
	}
	// A second sweep does not re-end this clone (the sweep is global, so it may
	// touch other tests' clones in the shared DB — assert only on ours).
	if _, err := pg.SweepClones(ctx, start.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if again, _ := pg.Clone(ctx, tid, cl.CloneHum); again.EndedAt == nil || !again.EndedAt.Equal(endedAt) {
		t.Errorf("second sweep moved ended_at %v -> %v", endedAt, again.EndedAt)
	}
}
