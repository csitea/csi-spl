package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// demoStayRig is one demo workspace with the open rule on, a fake clock t0
// and a factory of Google visitors.
type demoStayRig struct {
	s     Store
	demo  string
	open  AdmitPolicy
	t0    time.Time
	tag   string
	stays DemoStays
}

func newDemoStayRig(t *testing.T, s Store, stay time.Duration) demoStayRig {
	demo := newTenant(t, s)
	return demoStayRig{s: s, demo: demo, t0: time.Now().UTC().Truncate(time.Second), tag: uid(""), stays: s.(DemoStays),
		open: AdmitPolicy{OpenWorkspace: demo, OpenProviders: []string{"google"}, OpenMaxStay: stay}}
}

func (r demoStayRig) ident(name string) Identity {
	l := name + "-" + r.tag
	return Identity{Provider: "google", Subject: "sub-" + l, Email: l + "@example.com", Name: "Visitor " + name}
}

func (r demoStayRig) admit(t *testing.T, name string, at time.Time) string {
	t.Helper()
	hum, err := r.s.(Humans).Admit(context.Background(), r.ident(name), r.demo, r.open, at)
	if err != nil {
		t.Fatalf("admit %s: %v", name, err)
	}
	return hum
}

func (r demoStayRig) until(t *testing.T, hum string) time.Time {
	t.Helper()
	ms, err := r.s.(MemberDirectory).ListMembers(context.Background(), r.demo)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range ms {
		if m.HumanID == hum {
			return m.AccessUntil
		}
	}
	return time.Time{}
}

func (r demoStayRig) sweep(t *testing.T, at time.Time) DemoSweep {
	t.Helper()
	out, err := r.stays.SweepDemo(context.Background(), r.demo, DefaultDemoMaxStay, at)
	if err != nil {
		t.Fatalf("sweep at %v: %v", at, err)
	}
	return out
}

// specs/077 T009 (FR-005): admission writes access_until = admitted + the
// stay; DemoSeatEnded turns at that instant.
func TestDemoStayAdmissionWritesAccessUntil(t *testing.T) {
	ctx := context.Background()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			r := newDemoStayRig(t, s, 0) // 0 = DefaultDemoMaxStay
			v := r.admit(t, "default", r.t0)
			if got, want := r.until(t, v), r.t0.Add(3*time.Hour); !got.Equal(want) {
				t.Fatalf("access_until %v, want admitted + 3h = %v", got, want)
			}
			r.open.OpenMaxStay = 10 * time.Minute
			w := r.admit(t, "short", r.t0)
			if got, want := r.until(t, w), r.t0.Add(10*time.Minute); !got.Equal(want) {
				t.Fatalf("configured stay: access_until %v, want %v", got, want)
			}
			// A re-login never extends the stay.
			if again := r.admit(t, "default", r.t0.Add(time.Hour)); again != v || !r.until(t, v).Equal(r.t0.Add(3*time.Hour)) {
				t.Fatalf("re-login moved the stay: %q %v", again, r.until(t, v))
			}
			for _, c := range []struct {
				at   time.Time
				want bool
			}{{r.t0.Add(3*time.Hour - time.Second), false}, {r.t0.Add(3 * time.Hour), true}} {
				if got, err := r.stays.DemoSeatEnded(ctx, r.demo, v, c.at); err != nil || got != c.want {
					t.Fatalf("DemoSeatEnded at %v: %v %v, want %v", c.at, got, err, c.want)
				}
			}
			// An invited member of the demo workspace has no end and is no
			// ended demo seat.
			staff := r.ident("staff")
			if err := s.(Humans).PutInvite(ctx, Invite{TenantID: r.demo, Email: staff.Email, Role: rbac.Admin,
				InvitedBy: AdmittedOperator, ExpiresAt: r.t0.Add(time.Hour)}, r.t0); err != nil {
				t.Fatal(err)
			}
			sh := r.admit(t, "staff", r.t0)
			if u := r.until(t, sh); !u.IsZero() {
				t.Fatalf("invited staff got access_until %v", u)
			}
			if got, _ := r.stays.DemoSeatEnded(ctx, r.demo, sh, r.t0.Add(24*time.Hour)); got {
				t.Fatal("staff reads as an ended demo seat")
			}
		})
	}
}

// demoVisitorRows gives hum a read mark, a reaction, a flow watch and a
// channel seat in the demo workspace (and, on Postgres, a sign-in row).
func demoVisitorRows(t *testing.T, r demoStayRig, hum, msgID string) {
	t.Helper()
	ctx := context.Background()
	s := r.s
	if err := s.(ReadMarks).SaveReadMarks(ctx, r.demo, hum, map[string]ReadMark{"ch:lobby": {At: r.t0, MsgID: msgID}}, r.t0); err != nil {
		t.Fatal(err)
	}
	if err := s.(MessageReactions).AddReaction(ctx, r.demo, msgID, hum, "👍", r.t0); err != nil {
		t.Fatal(err)
	}
	if err := s.(ChannelHumans).AddChannelHumans(ctx, r.demo, "visitors", []string{hum}, hum, r.t0); err != nil {
		t.Fatal(err)
	}
	if pg, ok := s.(*Postgres); ok {
		if err := pg.AppendMemberActivity(ctx, MemberActivity{TenantID: r.demo, SubjectHum: hum, ActorHum: hum,
			Kind: "sign_in", Detail: "google", IP: "192.0.2.0/24", UA: "Firefox / Linux", CreatedAt: r.t0}); err != nil {
			t.Fatal(err)
		}
		if _, err := pg.execTenant(ctx, r.demo, `INSERT INTO flow_watches (tenant_id, task_id, member_id, since)
			VALUES ($1, $2::uuid, $3, $4)`, r.demo, uuid4(), hum, r.t0); err != nil {
			t.Fatal(err)
		}
	} else {
		mem := s.(*Memory)
		mem.mu.Lock()
		mem.flowWatches[[3]string{r.demo, uuid4(), hum}] = r.t0
		mem.mu.Unlock()
	}
}

// demoVisitorLeft counts hum's rows demoVisitorRows wrote that are still there.
func demoVisitorLeft(t *testing.T, r demoStayRig, hum, msgID string) int {
	t.Helper()
	ctx := context.Background()
	n := 0
	marks, err := r.s.(ReadMarks).ReadMarksOf(ctx, r.demo, hum)
	if err != nil {
		t.Fatal(err)
	}
	n += len(marks)
	rs, err := r.s.(MessageReactions).ReactionsFor(ctx, r.demo, []string{msgID})
	if err != nil {
		t.Fatal(err)
	}
	for _, x := range rs[msgID] {
		if x.Actor == hum {
			n++
		}
	}
	chs, err := r.s.(ChannelHumans).HumanChannels(ctx, r.demo, hum)
	if err != nil {
		t.Fatal(err)
	}
	n += len(chs)
	if pg, ok := r.s.(*Postgres); ok {
		var k int
		if err := pg.pool.QueryRow(ctx, `SELECT
			(SELECT count(*) FROM flow_watches WHERE member_id = $1)
			+ (SELECT count(*) FROM member_activity WHERE subject_hum = $1)
			+ (SELECT count(*) FROM human_identities WHERE human_id = $1)
			+ (SELECT count(*) FROM humans WHERE human_id = $1)`, hum).Scan(&k); err != nil {
			t.Fatal(err)
		}
		n += k
	} else {
		mem := r.s.(*Memory)
		mem.mu.Lock()
		for k := range mem.flowWatches {
			if k[2] == hum {
				n++
			}
		}
		if _, ok := mem.hum.humans[hum]; ok {
			n++
		}
		for _, i := range mem.hum.identities {
			if i.human == hum {
				n++
			}
		}
		mem.mu.Unlock()
	}
	return n
}

// specs/077 T009 (FR-005, Q10): the sweep drops each ended demo seat and the
// visitor's personal data, never a seat still running, never a real member's
// human, and leaves the visitor's posts.
func TestDemoStaySweep(t *testing.T) {
	ctx := context.Background()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			r := newDemoStayRig(t, s, 0)
			if err := s.CreateChannel(ctx, Channel{TenantID: r.demo, ChannelID: "visitors", Name: "visitors", CreatedBy: "wui", CreatedAt: r.t0}); err != nil {
				t.Fatal(err)
			}
			post := msgFor(r.demo, uuid4(), "box-a", r.t0, r.t0, `{"v":1}`)
			if _, err := s.InsertMessage(ctx, post); err != nil {
				t.Fatal(err)
			}
			early := r.admit(t, "early", r.t0)
			late := r.admit(t, "late", r.t0.Add(time.Hour))
			demoVisitorRows(t, r, early, post.MsgID)
			demoVisitorRows(t, r, late, post.MsgID)
			pic := sha256.Sum256([]byte(uid("avatar-")))
			if err := s.(Humans).SetAvatar(ctx, early, hex.EncodeToString(pic[:])); err != nil {
				t.Fatal(err)
			}
			before := demoVisitorLeft(t, r, early, post.MsgID)
			if before < 4 {
				t.Fatalf("fixture: %d rows for the early visitor", before)
			}
			// One second before the end: nothing goes.
			if out := r.sweep(t, r.t0.Add(3*time.Hour-time.Second)); len(out.Ended) != 0 {
				t.Fatalf("swept before the end: %+v", out)
			}
			out := r.sweep(t, r.t0.Add(3*time.Hour))
			if !slices.Equal(out.Ended, []string{early}) || out.Humans != 1 || len(out.Avatars) != 1 {
				t.Fatalf("sweep at the end: %+v, want only %s with its avatar", out, early)
			}
			if left := demoVisitorLeft(t, r, early, post.MsgID); left != 0 {
				t.Fatalf("%d personal rows of the ended visitor left", left)
			}
			if left := demoVisitorLeft(t, r, late, post.MsgID); left != before {
				t.Fatalf("the running visitor lost rows: %d of %d", left, before)
			}
			if ok, err := s.HasMessage(ctx, r.demo, post.MsgID); err != nil || !ok {
				t.Fatalf("the post went with the visitor: %v", err)
			}
			if ended, _ := r.stays.DemoSeatEnded(ctx, r.demo, early, r.t0.Add(3*time.Hour)); !ended {
				t.Fatal("a swept visitor does not read as ended")
			}
			// The identity link is gone: signing in again is a new human.
			if again := r.admit(t, "early", r.t0.Add(4*time.Hour)); again == early {
				t.Fatalf("re-admission found the swept human %s", early)
			}
			// A second sweep finds nothing.
			if out := r.sweep(t, r.t0.Add(3*time.Hour)); len(out.Ended) != 0 {
				t.Fatalf("second sweep: %+v", out)
			}
		})
	}
}

// specs/077 T009, spec 3.8: a demo seat whose human became a real member
// elsewhere ends like any other, but the human, its identities and its other
// membership stay. CONTROL of the "no membership left" guard: without it the
// real member's human is deleted (cascading their membership) and the
// re-admission below gets a new HUM-*.
func TestDemoStaySweepKeepsRealMember(t *testing.T) {
	ctx := context.Background()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			r := newDemoStayRig(t, s, 0)
			v := r.admit(t, "both", r.t0)
			other := newTenant(t, s)
			id := r.ident("both")
			if err := s.(Humans).PutInvite(ctx, Invite{TenantID: other, Email: id.Email, Role: rbac.Developer,
				InvitedBy: AdmittedOperator, ExpiresAt: r.t0.Add(time.Hour)}, r.t0); err != nil {
				t.Fatal(err)
			}
			if hum, err := s.(Humans).Admit(ctx, id, other, AdmitPolicy{}, r.t0); err != nil || hum != v {
				t.Fatalf("invite into the other workspace: %q %v", hum, err)
			}
			out := r.sweep(t, r.t0.Add(3*time.Hour))
			if !slices.Equal(out.Ended, []string{v}) || out.Humans != 0 {
				t.Fatalf("sweep: %+v, want the seat ended and no human dropped", out)
			}
			if role, err := s.(Humans).MemberRole(ctx, v, other); err != nil || role != rbac.Developer {
				t.Fatalf("the real membership: %q %v", role, err)
			}
			if hum, err := s.(Humans).Admit(ctx, id, other, AdmitPolicy{}, r.t0.Add(4*time.Hour)); err != nil || hum != v {
				t.Fatalf("the identity: %q %v, want %s", hum, err, v)
			}
		})
	}
}

// A seat admitted before T009 (access_until NULL) is given admitted + the
// stay by the sweep, so no demo seat is unlimited.
func TestDemoStaySweepEndsOpenEndedSeat(t *testing.T) {
	ctx := context.Background()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			r := newDemoStayRig(t, s, 0)
			v := r.admit(t, "legacy", r.t0)
			if err := s.(MemberAccess).SetMemberAccessUntil(ctx, r.demo, v, nil); err != nil {
				t.Fatal(err)
			}
			if out := r.sweep(t, r.t0.Add(time.Hour)); len(out.Ended) != 0 || !r.until(t, v).Equal(r.t0.Add(3*time.Hour)) {
				t.Fatalf("first sweep: %+v, access_until %v", out, r.until(t, v))
			}
			if out := r.sweep(t, r.t0.Add(3*time.Hour)); !slices.Equal(out.Ended, []string{v}) {
				t.Fatalf("at admitted + 3h: %+v", out)
			}
		})
	}
}
