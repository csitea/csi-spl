package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// Spec 107 T005 (section 1.2): a member's post, edit and reaction write their
// minute into hours_minutes in the write's own transaction, on Memory and
// Postgres (SPOOL_TEST_PG_DSN). One row per post; a post takes a tab minute's
// target; a later tab write leaves a post minute; an agent writes none; the
// zone order of 1.6; and on Postgres a failing upsert rolls back its write
// and nothing else.

// hoursPostFixture is a workspace with one admitted member (a HUM-*).
type hoursPostFixture struct {
	st     Store
	h      Hours
	tenant string
	member string
	task   string
}

func newHoursPostFixture(t *testing.T, st Store) hoursPostFixture {
	t.Helper()
	ctx, now := context.Background(), time.Now()
	tid := newTenant(t, st)
	hum := st.(Humans)
	email := uid("h") + "@example.com"
	if err := hum.PutInvite(ctx, Invite{TenantID: tid, Email: email, Role: "developer", InvitedBy: AdmittedOperator,
		ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	member, err := hum.Admit(ctx, Identity{Provider: "google", Subject: "s-" + email, Email: email}, tid, AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(member, "HUM-") {
		t.Fatalf("member id %q", member)
	}
	return hoursPostFixture{st: st, h: hoursStore(t, st), tenant: tid, member: member, task: uuid4()}
}

// post is the member's box-wui message at.
func (f hoursPostFixture) post(at time.Time) Message {
	m := msgFor(f.tenant, f.task, "box-b", at, at, `{"m":"`+uuid4()+`"}`)
	m.FromBox, m.FromID, m.ToID = wuiBox, f.member, "CLE-07"
	return m
}

func (f hoursPostFixture) insert(t *testing.T, m Message) {
	t.Helper()
	if ok, err := f.st.InsertMessage(context.Background(), m); err != nil || !ok {
		t.Fatalf("insert: %v %v", ok, err)
	}
}

func (f hoursPostFixture) minutes(t *testing.T) []HoursMinute {
	t.Helper()
	got, err := f.h.HoursMinutes(context.Background(), f.tenant, f.member, hoursT0.Add(-24*time.Hour), hoursT0.Add(24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func wantMinutes(t *testing.T, got []HoursMinute, want ...HoursMinute) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("minutes: got %+v want %+v", got, want)
	}
	for i := range want {
		if !got[i].At.Equal(want[i].At) || got[i].Target != want[i].Target || got[i].Src != want[i].Src || got[i].TZ != want[i].TZ {
			t.Errorf("minute %d: got %+v want %+v", i, got[i], want[i])
		}
	}
}

func TestHoursPostWritesOneRow(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newHoursPostFixture(t, st)
			m := f.post(hoursT0.Add(42 * time.Second))
			f.insert(t, m)
			// A resend of the same envelope stores nothing more.
			if ok, err := st.InsertMessage(ctx, m); err != nil || ok {
				t.Fatalf("resend: %v %v", ok, err)
			}
			want := HoursMinute{At: hoursT0, Target: "t:" + f.task, Src: HoursSrcPost, TZ: "UTC"}
			wantMinutes(t, f.minutes(t), want)
			// Two posts in one minute are one row; the next minute is another.
			f.insert(t, f.post(hoursT0.Add(50*time.Second)))
			f.insert(t, f.post(hoursT0.Add(time.Minute)))
			wantMinutes(t, f.minutes(t), want,
				HoursMinute{At: hoursT0.Add(time.Minute), Target: "t:" + f.task, Src: HoursSrcPost, TZ: "UTC"})
			// The sent-in-one path (box-wui's own deliveries) writes it too.
			if si, ok := st.(SentInserter); ok {
				m := f.post(hoursT0.Add(2 * time.Minute))
				m.ToBox = wuiBox
				if ok, err := si.InsertMessageSent(ctx, m, m.ReceivedAt.Add(time.Hour)); err != nil || !ok {
					t.Fatalf("sent: %v %v", ok, err)
				}
				if got := f.minutes(t); len(got) != 3 || !got[2].At.Equal(hoursT0.Add(2*time.Minute)) {
					t.Errorf("sent-in-one: %+v", got)
				}
			}
		})
	}
}

func TestHoursPostOverTab(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newHoursPostFixture(t, st)
			// m0: a tab minute, then a post takes its target.
			// m1: a post, then a tab write leaves it.
			m0, m1 := hoursT0, hoursT0.Add(time.Minute)
			if err := f.h.UpsertHoursMinutes(ctx, f.tenant, f.member, []HoursMinute{
				{At: m0, Target: "ch:lobby", Src: HoursSrcTab, TZ: "Europe/Helsinki"}}); err != nil {
				t.Fatal(err)
			}
			f.insert(t, f.post(m0.Add(10*time.Second)))
			f.insert(t, f.post(m1))
			if err := f.h.UpsertHoursMinutes(ctx, f.tenant, f.member, []HoursMinute{
				{At: m1, Target: "ws", Src: HoursSrcTab, TZ: "UTC"}}); err != nil {
				t.Fatal(err)
			}
			// m0's zone is the tab batch's it replaced (spec 1.6); by m1 no tab
			// minute is left, so UTC.
			wantMinutes(t, f.minutes(t),
				HoursMinute{At: m0, Target: "t:" + f.task, Src: HoursSrcPost, TZ: "Europe/Helsinki"},
				HoursMinute{At: m1, Target: "t:" + f.task, Src: HoursSrcPost, TZ: "UTC"})
		})
	}
}

func TestHoursPostAgentWritesNone(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newHoursPostFixture(t, st)
			agent := msgFor(f.tenant, f.task, "box-b", hoursT0, hoursT0, `{"a":1}`) // box-a, GRK-03
			f.insert(t, agent)
			guest := f.post(hoursT0.Add(time.Minute))
			guest.FromID = "GST-1"
			f.insert(t, guest)
			// An agent's edit and reaction on the member's message write none.
			mine := f.post(hoursT0.Add(-time.Hour))
			f.insert(t, mine)
			if err := st.AddReaction(ctx, f.tenant, agent.MsgID, "GRK-03", "👍", hoursT0.Add(2*time.Minute)); err != nil {
				t.Fatal(err)
			}
			if _, err := st.ApplyEdit(ctx, f.tenant, agent.MsgID, Edit{Body: "x", Msg: []byte(`{"v":1}`), Env: []byte(`{"e":1}`),
				EditedBy: "GRK-03", EditedAt: hoursT0.Add(3 * time.Minute)}); err != nil {
				t.Fatal(err)
			}
			wantMinutes(t, f.minutes(t), HoursMinute{At: hoursT0.Add(-time.Hour), Target: "t:" + f.task, Src: HoursSrcPost, TZ: "UTC"})
			if got, _ := f.h.HoursMinutes(ctx, f.tenant, "GRK-03", hoursT0.Add(-time.Hour), hoursT0.Add(time.Hour)); len(got) != 0 {
				t.Errorf("agent minutes: %+v", got)
			}
		})
	}
}

func TestHoursPostEditAndReaction(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newHoursPostFixture(t, st)
			// An agent's message in another topic: the member's edit is not
			// theirs to make, a reaction is; both count against its topic.
			other := msgFor(f.tenant, uuid4(), "box-b", hoursT0, hoursT0, `{"o":1}`)
			f.insert(t, other)
			mine := f.post(hoursT0)
			f.insert(t, mine)
			e1, r1 := hoursT0.Add(5*time.Minute), hoursT0.Add(7*time.Minute)
			if _, err := st.ApplyEdit(ctx, f.tenant, mine.MsgID, Edit{Body: "fixed", Msg: []byte(`{"v":1}`), Env: []byte(`{"e":2}`),
				EditedBy: f.member, EditedAt: e1.Add(9 * time.Second)}); err != nil {
				t.Fatal(err)
			}
			if err := st.AddReaction(ctx, f.tenant, other.MsgID, f.member, "👍", r1.Add(30*time.Second)); err != nil {
				t.Fatal(err)
			}
			// Adding the same reaction again later adds nothing, and writes none.
			if err := st.AddReaction(ctx, f.tenant, other.MsgID, f.member, "👍", r1.Add(3*time.Minute)); err != nil {
				t.Fatal(err)
			}
			wantMinutes(t, f.minutes(t),
				HoursMinute{At: hoursT0, Target: "t:" + f.task, Src: HoursSrcPost, TZ: "UTC"},
				HoursMinute{At: e1, Target: "t:" + f.task, Src: HoursSrcPost, TZ: "UTC"},
				HoursMinute{At: r1, Target: "t:" + other.TaskID, Src: HoursSrcPost, TZ: "UTC"})
		})
	}
}

// TestHoursPostZone: spec 1.6, the member's zone, else the last tab batch's,
// else the workspace's hours.tz, else UTC.
func TestHoursPostZone(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newHoursPostFixture(t, st)
			zoneAt := func(i int) string {
				t.Helper()
				at := hoursT0.Add(time.Duration(i) * time.Hour)
				f.insert(t, f.post(at))
				got, err := f.h.HoursMinutes(ctx, f.tenant, f.member, at, at.Add(time.Minute))
				if err != nil || len(got) != 1 {
					t.Fatalf("minute %d: %+v %v", i, got, err)
				}
				return got[0].TZ
			}
			if z := zoneAt(-3); z != "UTC" {
				t.Errorf("nothing set: %q", z)
			}
			if _, err := st.(TenantKV).SetTenantSettings(ctx, f.tenant, TenantSettingsPatch{Set: map[string]any{HoursKeyTZ: "Asia/Tokyo"}}); err != nil {
				t.Fatal(err)
			}
			if z := zoneAt(-2); z != "Asia/Tokyo" {
				t.Errorf("workspace: %q", z)
			}
			if err := f.h.UpsertHoursMinutes(ctx, f.tenant, f.member, []HoursMinute{
				{At: hoursT0.Add(-90 * time.Minute), Target: "ws", Src: HoursSrcTab, TZ: "America/New_York"}}); err != nil {
				t.Fatal(err)
			}
			if z := zoneAt(-1); z != "America/New_York" {
				t.Errorf("last tab batch: %q", z)
			}
			if err := st.(membershipSettingsStore).SetMembershipSettings(ctx, f.member, f.tenant, map[string]any{"time_zone": "Europe/Helsinki"}); err != nil {
				t.Fatal(err)
			}
			if z := zoneAt(0); z != "Europe/Helsinki" {
				t.Errorf("member: %q", z)
			}
		})
	}
}

// TestHoursPostFailureRollsBack: the upsert is in the write's transaction. A
// minute the table refuses (a zone over the rdb 0151 CHECK, planted where the
// API never lets one through) fails the member's post, edit and reaction with
// nothing of them stored; an agent's post, which writes no minute, is not
// touched. Postgres only: Memory has no CHECK to fail.
func TestHoursPostFailureRollsBack(t *testing.T) {
	ctx := context.Background()
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN not set")
	}
	f := newHoursPostFixture(t, pg)
	mine := f.post(hoursT0)
	f.insert(t, mine)
	agent := msgFor(f.tenant, f.task, "box-b", hoursT0, hoursT0, `{"a":2}`)
	f.insert(t, agent)
	if err := pg.SetMembershipSettings(ctx, f.member, f.tenant, map[string]any{"time_zone": strings.Repeat("Z", 65)}); err != nil {
		t.Fatal(err)
	}
	at := hoursT0.Add(time.Hour)

	bad := f.post(at)
	if _, err := pg.InsertMessage(ctx, bad); err == nil {
		t.Fatal("post with a refused minute was stored")
	}
	if _, err := pg.GetEditable(ctx, f.tenant, bad.MsgID, at); !errors.Is(err, ErrNotFound) {
		t.Errorf("the post outlived its minute: %v", err)
	}
	if _, err := pg.ApplyEdit(ctx, f.tenant, mine.MsgID, Edit{Body: "lost", Msg: []byte(`{"v":1}`), Env: []byte(`{"e":3}`),
		EditedBy: f.member, EditedAt: at}); err == nil {
		t.Fatal("edit with a refused minute was applied")
	}
	if m, err := pg.GetEditable(ctx, f.tenant, mine.MsgID, at); err != nil || m.Body != mine.Body || m.Revision != 0 {
		t.Errorf("the edit outlived its minute: %q rev %d %v", m.Body, m.Revision, err)
	}
	if err := pg.AddReaction(ctx, f.tenant, agent.MsgID, f.member, "👍", at); err == nil {
		t.Fatal("reaction with a refused minute was stored")
	}
	if rs, err := pg.ReactionsFor(ctx, f.tenant, []string{agent.MsgID}); err != nil || len(rs[agent.MsgID]) != 0 {
		t.Errorf("the reaction outlived its minute: %+v %v", rs, err)
	}
	// Writes that carry no minute are not touched.
	f.insert(t, msgFor(f.tenant, f.task, "box-b", at, at, `{"a":3}`))
	if err := pg.AddReaction(ctx, f.tenant, mine.MsgID, "GRK-03", "👍", at); err != nil {
		t.Errorf("agent reaction: %v", err)
	}
	wantMinutes(t, f.minutes(t), HoursMinute{At: hoursT0, Target: "t:" + f.task, Src: HoursSrcPost, TZ: "UTC"})
}

// TestHoursPostWithoutTable: before rdb 0151 reaches the database a post
// writes no minute and does not fail (the probe).
func TestHoursPostWithoutTable(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN not set")
	}
	ctx := context.Background()
	f := newHoursPostFixture(t, pg)
	pg.hoursTab = seatsProbe{check: func(context.Context) (bool, error) { return false, nil }}
	if pg.hasHoursMinutes(ctx) {
		t.Fatal("probe override ignored")
	}
	f.insert(t, f.post(hoursT0))
	if got := f.minutes(t); len(got) != 0 {
		t.Errorf("minutes without the table: %+v", got)
	}
}
