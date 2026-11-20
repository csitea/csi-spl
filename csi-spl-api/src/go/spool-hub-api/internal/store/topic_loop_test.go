package store

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
	"github.com/jackc/pgx/v5"
)

// Spec 182 v0.4 row L1 (rdb 0299): discussion loops. Every test runs on
// Memory and, with SPOOL_TEST_PG_DSN, on Postgres with the same assertions:
// the two stores answer alike (parity).

// loopFix is one driver's tenant and topic for a loop test.
type loopFix struct {
	t    *testing.T
	ctx  context.Context
	s    Store
	ls   TopicLoopStore
	tn   string
	task string
	t0   time.Time
}

func newLoopFix(t *testing.T, s Store) *loopFix {
	t.Helper()
	return &loopFix{t: t, ctx: context.Background(), s: s, ls: s.(TopicLoopStore), tn: newTenant(t, s), task: uuid4(),
		t0: time.Now().UTC().Truncate(time.Microsecond)}
}

// add stores a loop on f.task, failing the test on an error.
func (f *loopFix) add(prompt string, interval int, triggers ...string) TopicLoop {
	f.t.Helper()
	l, err := f.ls.AddTopicLoop(f.ctx, f.tn, TopicLoop{TaskID: f.task, Prompt: prompt, Triggers: triggers,
		IntervalMin: interval, SetBy: "HUM-1", SetAt: f.t0})
	if err != nil {
		f.t.Fatalf("add %q: %v", prompt, err)
	}
	return l
}

// TestTopicLoopAddRefusals: every bad loop is ErrBadTopicLoop (or
// ErrBadTopicTask / ErrNotFound) before any write, and nothing is stored.
func TestTopicLoopAddRefusals(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newLoopFix(t, s)
			ok := TopicLoop{TaskID: f.task, Prompt: "p", Triggers: []string{LoopAfterAgentReply}, SetBy: "HUM-1"}
			with := func(fn func(l *TopicLoop)) TopicLoop { l := ok; fn(&l); return l }
			for why, c := range map[string]struct {
				l    TopicLoop
				want error
			}{
				"empty prompt":       {with(func(l *TopicLoop) { l.Prompt = "  \n " }), ErrBadTopicLoop},
				"prompt over 4000":   {with(func(l *TopicLoop) { l.Prompt = strings.Repeat("ä", TopicLoopPromptMax+1) }), ErrBadTopicLoop},
				"no trigger":         {with(func(l *TopicLoop) { l.Triggers = nil }), ErrBadTopicLoop},
				"unknown trigger":    {with(func(l *TopicLoop) { l.Triggers = []string{"other_human_post"} }), ErrBadTopicLoop},
				"n minutes, no n":    {with(func(l *TopicLoop) { l.Triggers = []string{LoopEveryNMinutes} }), ErrBadTopicLoop},
				"n under 5":          {with(func(l *TopicLoop) { l.Triggers, l.IntervalMin = []string{LoopEveryNMinutes}, 4 }), ErrBadTopicLoop},
				"n over 1440":        {with(func(l *TopicLoop) { l.Triggers, l.IntervalMin = []string{LoopEveryNMinutes}, 1441 }), ErrBadTopicLoop},
				"stray interval":     {with(func(l *TopicLoop) { l.IntervalMin = 30 }), ErrBadTopicLoop},
				"no author":          {with(func(l *TopicLoop) { l.SetBy = "" }), ErrBadTopicLoop},
				"author over 64":     {with(func(l *TopicLoop) { l.SetBy = strings.Repeat("H", 65) }), ErrBadTopicLoop},
				"task not a uuid":    {with(func(l *TopicLoop) { l.TaskID = "not-a-uuid" }), ErrBadTopicTask},
				"loop id not a uuid": {with(func(l *TopicLoop) { l.LoopID = "x" }), ErrBadTopicLoop},
				"keyword, no word":   {with(func(l *TopicLoop) { l.Triggers = []string{LoopPostHasKeyword} }), ErrBadTopicLoop},
				"keyword over 200":   {with(func(l *TopicLoop) { l.Triggers, l.Keyword = []string{LoopPostHasKeyword}, strings.Repeat("k", 201) }), ErrBadTopicLoop},
				"stray keyword":      {with(func(l *TopicLoop) { l.Keyword = "pdf" }), ErrBadTopicLoop},
				"idle, no n":         {with(func(l *TopicLoop) { l.Triggers = []string{LoopNoReplyAfterHuman} }), ErrBadTopicLoop},
				"idle under 5":       {with(func(l *TopicLoop) { l.Triggers, l.IdleMin = []string{LoopNoReplyAfterHuman}, 4 }), ErrBadTopicLoop},
				"stray idle":         {with(func(l *TopicLoop) { l.IdleMin = 30 }), ErrBadTopicLoop},
				"daily, no time":     {with(func(l *TopicLoop) { l.Triggers = []string{LoopDailyAt} }), ErrBadTopicLoop},
				"daily 25:00":        {with(func(l *TopicLoop) { l.Triggers, l.DailyAt = []string{LoopDailyAt}, "25:00" }), ErrBadTopicLoop},
				"daily 9:00":         {with(func(l *TopicLoop) { l.Triggers, l.DailyAt = []string{LoopDailyAt}, "9:00" }), ErrBadTopicLoop},
				"daily bad zone":     {with(func(l *TopicLoop) { l.Triggers, l.DailyAt, l.DailyTZ = []string{LoopDailyAt}, "09:00", "Mars/Base" }), ErrBadTopicLoop},
				"daily Local zone":   {with(func(l *TopicLoop) { l.Triggers, l.DailyAt, l.DailyTZ = []string{LoopDailyAt}, "09:00", "Local" }), ErrBadTopicLoop},
				"stray daily":        {with(func(l *TopicLoop) { l.DailyAt = "09:00" }), ErrBadTopicLoop},
			} {
				if _, err := f.ls.AddTopicLoop(f.ctx, f.tn, c.l); !errors.Is(err, c.want) {
					t.Errorf("%s: %v, want %v", why, err, c.want)
				}
			}
			if _, err := f.ls.AddTopicLoop(f.ctx, uid("gone-"), ok); !errors.Is(err, ErrNotFound) {
				t.Errorf("no such workspace: %v, want ErrNotFound", err)
			}
			if got, err := f.ls.TopicLoops(f.ctx, f.tn, f.task); err != nil || len(got) != 0 {
				t.Fatalf("after the refusals: %d loops, %v; want none", len(got), err)
			}
			if has, err := f.ls.TenantHasTopicLoops(f.ctx, f.tn); err != nil || has {
				t.Fatalf("TenantHasTopicLoops = %v %v, want false", has, err)
			}
		})
	}
}

// TestTopicLoopCRUD: an add stores the loop as normalised (prompt trimmed,
// triggers distinct and sorted, task lower case, on, NextDueAt from the
// period); the list is SetAt order and TopicLoopsOn drops paused loops; an
// edit follows TopicLoopEdit's rules; the deletes answer what they did.
func TestTopicLoopCRUD(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newLoopFix(t, s)
			a, err := f.ls.AddTopicLoop(f.ctx, f.tn, TopicLoop{TaskID: strings.ToUpper(f.task), Prompt: "  mail me the PDF \n",
				Triggers:    []string{LoopEveryNMinutes, LoopAfterAgentReply, LoopEveryHour, LoopAfterAgentReply},
				IntervalMin: 90, SetBy: "HUM-1", SetAt: f.t0})
			if err != nil {
				t.Fatal(err)
			}
			want := []string{LoopAfterAgentReply, LoopEveryHour, LoopEveryNMinutes}
			if !isUUID(a.LoopID) || a.TaskID != f.task || a.Prompt != "mail me the PDF" || !slices.Equal(a.Triggers, want) ||
				a.State != TopicLoopOn || a.IntervalMin != 90 || !a.SetAt.Equal(f.t0) || a.TenantID != f.tn {
				t.Fatalf("add stored %+v", a)
			}
			if !a.NextDueAt.Equal(f.t0.Add(time.Hour)) { // the shorter of every_hour and 90 minutes
				t.Fatalf("NextDueAt %v, want set_at + 1h", a.NextDueAt)
			}
			b := f.add("on each human post", 0, LoopAfterHumanReply)
			if !b.NextDueAt.IsZero() || b.IntervalMin != 0 {
				t.Fatalf("a loop with no time trigger: %+v", b)
			}
			if has, err := f.ls.TenantHasTopicLoops(f.ctx, f.tn); err != nil || !has {
				t.Fatalf("TenantHasTopicLoops = %v %v, want true", has, err)
			}

			// Pause b: TopicLoopsOn drops it; the author and hour stay.
			paused := TopicLoopPaused
			at1 := f.t0.Add(time.Minute)
			pb, err := f.ls.EditTopicLoop(f.ctx, f.tn, f.task, b.LoopID, TopicLoopEdit{State: &paused, By: "HUM-2", At: at1})
			if err != nil || pb.State != TopicLoopPaused || pb.SetBy != "HUM-1" || !pb.SetAt.Equal(f.t0) {
				t.Fatalf("pause: %+v %v", pb, err)
			}
			all, _ := f.ls.TopicLoops(f.ctx, f.tn, f.task)
			on, _ := f.ls.TopicLoopsOn(f.ctx, f.tn, f.task)
			if len(all) != 2 || len(on) != 1 || on[0].LoopID != a.LoopID {
				t.Fatalf("lists: all %d, on %+v; want 2 and only a", len(all), on)
			}

			// Pause a: no time trigger is due while paused; resume counts again.
			pa, err := f.ls.EditTopicLoop(f.ctx, f.tn, f.task, a.LoopID, TopicLoopEdit{State: &paused, By: "HUM-2", At: at1})
			if err != nil || !pa.NextDueAt.IsZero() {
				t.Fatalf("pause a: NextDueAt %v %v, want zero", pa.NextDueAt, err)
			}
			resume := TopicLoopOn
			at2 := f.t0.Add(2 * time.Minute)
			ra, err := f.ls.EditTopicLoop(f.ctx, f.tn, f.task, a.LoopID, TopicLoopEdit{State: &resume, By: "HUM-2", At: at2})
			if err != nil || !ra.NextDueAt.Equal(at2.Add(time.Hour)) {
				t.Fatalf("resume a: NextDueAt %v %v, want at + 1h", ra.NextDueAt, err)
			}

			// A fire, then a new prompt: the editor is the author, the hour resets.
			if _, fired, err := f.ls.CountTopicLoopFire(f.ctx, f.tn, a.LoopID, at2, 0); err != nil || !fired {
				t.Fatalf("fire: %v %v", fired, err)
			}
			prompt := "new prompt"
			at3 := f.t0.Add(3 * time.Minute)
			ea, err := f.ls.EditTopicLoop(f.ctx, f.tn, f.task, a.LoopID, TopicLoopEdit{Prompt: &prompt, By: "HUM-3", At: at3})
			if err != nil || ea.Prompt != prompt || ea.SetBy != "HUM-3" || !ea.SetAt.Equal(at3) ||
				!ea.HourStart.IsZero() || ea.FiresInHour != 0 || ea.FiresTotal != 1 {
				t.Fatalf("edit prompt: %+v %v", ea, err)
			}

			// New triggers without every_n_minutes clear the interval; a stray one is refused.
			ea, err = f.ls.EditTopicLoop(f.ctx, f.tn, f.task, a.LoopID, TopicLoopEdit{Triggers: []string{LoopEveryHour}, By: "HUM-3", At: at3})
			if err != nil || ea.IntervalMin != 0 || !slices.Equal(ea.Triggers, []string{LoopEveryHour}) || !ea.NextDueAt.Equal(at3.Add(time.Hour)) {
				t.Fatalf("drop every_n_minutes: %+v %v", ea, err)
			}
			n := 10
			if _, err := f.ls.EditTopicLoop(f.ctx, f.tn, f.task, a.LoopID, TopicLoopEdit{Interval: &n, By: "HUM-3", At: at3}); !errors.Is(err, ErrBadTopicLoop) {
				t.Fatalf("stray interval: %v, want ErrBadTopicLoop", err)
			}
			ea, err = f.ls.EditTopicLoop(f.ctx, f.tn, f.task, a.LoopID,
				TopicLoopEdit{Triggers: []string{LoopEveryNMinutes, LoopEveryHour}, Interval: &n, By: "HUM-3", At: at3})
			if err != nil || ea.IntervalMin != 10 || !ea.NextDueAt.Equal(at3.Add(10*time.Minute)) {
				t.Fatalf("every 10 minutes: %+v %v", ea, err)
			}
			if _, err := f.ls.EditTopicLoop(f.ctx, f.tn, f.task, a.LoopID, TopicLoopEdit{Prompt: &prompt}); !errors.Is(err, ErrBadTopicLoop) {
				t.Fatalf("edit with no By: %v, want ErrBadTopicLoop", err)
			}
			if _, err := f.ls.EditTopicLoop(f.ctx, f.tn, uuid4(), a.LoopID, TopicLoopEdit{Prompt: &prompt, By: "HUM-3"}); !errors.Is(err, ErrNotFound) {
				t.Fatalf("edit in another topic: %v, want ErrNotFound", err)
			}

			// Deletes.
			if ok, err := f.ls.DeleteTopicLoop(f.ctx, f.tn, uuid4(), a.LoopID); err != nil || ok {
				t.Fatalf("delete from another topic: %v %v, want false", ok, err)
			}
			if ok, err := f.ls.DeleteTopicLoop(f.ctx, f.tn, f.task, a.LoopID); err != nil || !ok {
				t.Fatalf("delete a: %v %v", ok, err)
			}
			if ok, err := f.ls.DeleteTopicLoop(f.ctx, f.tn, f.task, a.LoopID); err != nil || ok {
				t.Fatalf("delete a again: %v %v, want false", ok, err)
			}
			f.add("third", 0, LoopBeforeHumanReply)
			if n, err := f.ls.DeleteTopicLoops(f.ctx, f.tn, f.task); err != nil || n != 2 {
				t.Fatalf("delete the topic's loops: %d %v, want 2", n, err)
			}
			if has, _ := f.ls.TenantHasTopicLoops(f.ctx, f.tn); has {
				t.Fatal("TenantHasTopicLoops true after every loop is gone")
			}
		})
	}
}

// TestTopicLoopCap: 12 fires in the loop's hour count, the 13th does not
// (HeldUntil = HourStart + 1h); an hour later the hour rolls over; a paused
// or deleted loop never counts; a cap passed in replaces the default.
func TestTopicLoopCap(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newLoopFix(t, s)
			l := f.add("cap", 0, LoopAfterAgentReply)
			for i := 1; i <= TopicLoopCapDefault; i++ {
				got, fired, err := f.ls.CountTopicLoopFire(f.ctx, f.tn, l.LoopID, f.t0.Add(time.Duration(i)*time.Minute), 0)
				if err != nil || !fired || got.FiresInHour != i || !got.HourStart.Equal(f.t0.Add(time.Minute)) {
					t.Fatalf("fire %d: %+v %v %v", i, got, fired, err)
				}
			}
			at13 := f.t0.Add(30 * time.Minute)
			got, fired, err := f.ls.CountTopicLoopFire(f.ctx, f.tn, l.LoopID, at13, 0)
			if err != nil || fired || got.FiresInHour != TopicLoopCapDefault || got.FiresTotal != TopicLoopCapDefault {
				t.Fatalf("13th fire: %+v %v %v, want held at 12", got, fired, err)
			}
			if until, held := got.HeldUntil(at13, 0); !held || !until.Equal(f.t0.Add(time.Minute+time.Hour)) {
				t.Fatalf("HeldUntil = %v %v, want hour start + 1h", until, held)
			}
			roll := f.t0.Add(time.Minute + time.Hour)
			got, fired, err = f.ls.CountTopicLoopFire(f.ctx, f.tn, l.LoopID, roll, 0)
			if err != nil || !fired || got.FiresInHour != 1 || !got.HourStart.Equal(roll) || got.FiresTotal != 13 || !got.LastFiredAt.Equal(roll) {
				t.Fatalf("fire after the hour: %+v %v %v, want a new hour", got, fired, err)
			}
			if _, held := got.HeldUntil(roll, 0); held {
				t.Fatal("held right after the roll")
			}
			if _, fired, _ := f.ls.CountTopicLoopFire(f.ctx, f.tn, l.LoopID, roll.Add(time.Second), 2); !fired {
				t.Fatal("fire 2 under cap 2 did not count")
			}
			if _, fired, _ := f.ls.CountTopicLoopFire(f.ctx, f.tn, l.LoopID, roll.Add(2*time.Second), 2); fired {
				t.Fatal("fire 3 under cap 2 counted")
			}
			paused := TopicLoopPaused
			if _, err := f.ls.EditTopicLoop(f.ctx, f.tn, f.task, l.LoopID, TopicLoopEdit{State: &paused, By: "HUM-1", At: roll}); err != nil {
				t.Fatal(err)
			}
			if got, fired, err := f.ls.CountTopicLoopFire(f.ctx, f.tn, l.LoopID, roll.Add(2*time.Hour), 0); err != nil || fired || got.State != TopicLoopPaused {
				t.Fatalf("paused loop: %+v %v %v, want not counted", got, fired, err)
			}
			if _, fired, err := f.ls.CountTopicLoopFire(f.ctx, f.tn, uuid4(), roll, 0); err != nil || fired {
				t.Fatalf("no such loop: %v %v", fired, err)
			}
		})
	}
}

// TestTopicLoopCapConcurrent: 2 x 15 concurrent fires at one clock count
// exactly 12 (on Postgres two connections race the one UPDATE).
func TestTopicLoopCapConcurrent(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newLoopFix(t, s)
			l := f.add("race", 0, LoopAfterAgentReply)
			var mu sync.Mutex
			var wg sync.WaitGroup
			counted := 0
			for w := 0; w < 2; w++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					for i := 0; i < 15; i++ {
						_, fired, err := f.ls.CountTopicLoopFire(f.ctx, f.tn, l.LoopID, f.t0, 0)
						if err != nil {
							t.Error(err)
							return
						}
						if fired {
							mu.Lock()
							counted++
							mu.Unlock()
						}
					}
				}()
			}
			wg.Wait()
			if counted != TopicLoopCapDefault {
				t.Fatalf("%d of 30 concurrent fires counted, want %d", counted, TopicLoopCapDefault)
			}
			got, _ := f.ls.TopicLoops(f.ctx, f.tn, f.task)
			if len(got) != 1 || got[0].FiresInHour != TopicLoopCapDefault || got[0].FiresTotal != TopicLoopCapDefault {
				t.Fatalf("stored counters %+v, want 12 and 12", got)
			}
		})
	}
}

// TestTopicLoopClaimDue: the ticker claims a due loop once per tick,
// across workspaces, moves it on by its period from the tick (no catch-up
// after a gap), and never claims a paused loop or one with no time trigger.
func TestTopicLoopClaimDue(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newLoopFix(t, s)
			g := newLoopFix(t, s)
			g.t0 = f.t0
			fast := f.add("every 5", 5, LoopEveryNMinutes)
			hourly := g.add("hourly", 0, LoopEveryHour)
			paused := f.add("paused", 5, LoopEveryNMinutes)
			f.add("no time trigger", 0, LoopAfterHumanReply)
			p := TopicLoopPaused
			if _, err := f.ls.EditTopicLoop(f.ctx, f.tn, f.task, paused.LoopID, TopicLoopEdit{State: &p, By: "HUM-1", At: f.t0}); err != nil {
				t.Fatal(err)
			}
			mine := func(at time.Time) map[string]TopicLoop {
				t.Helper()
				got, err := f.ls.ClaimDueTopicLoops(f.ctx, at, 1000)
				if err != nil {
					t.Fatal(err)
				}
				out := map[string]TopicLoop{}
				for _, l := range got {
					if l.TenantID == f.tn || l.TenantID == g.tn {
						out[l.LoopID] = l
					}
				}
				return out
			}
			if got := mine(f.t0.Add(4 * time.Minute)); len(got) != 0 {
				t.Fatalf("claimed before due: %+v", got)
			}
			tick := f.t0.Add(3 * time.Hour) // a long gap: one fire, not a burst
			got := mine(tick)
			if !got[fast.LoopID].DueAt.Equal(f.t0.Add(5*time.Minute)) || !got[hourly.LoopID].DueAt.Equal(f.t0.Add(time.Hour)) {
				t.Fatalf("DueAt: %v %v, want the pre-move due times", got[fast.LoopID].DueAt, got[hourly.LoopID].DueAt)
			}
			if len(got) != 2 || !got[fast.LoopID].NextDueAt.Equal(tick.Add(5*time.Minute)) ||
				!got[hourly.LoopID].NextDueAt.Equal(tick.Add(time.Hour)) || got[hourly.LoopID].TenantID != g.tn {
				t.Fatalf("claim at the tick: %+v, want fast and hourly moved on from the tick", got)
			}
			if again := mine(tick); len(again) != 0 {
				t.Fatalf("second claim of the same tick: %+v", again)
			}
			if next := mine(tick.Add(5 * time.Minute)); len(next) != 1 || next[fast.LoopID].LoopID == "" {
				t.Fatalf("next tick: %+v, want only the 5-minute loop", next)
			}
		})
	}
}

// TestTopicLoopDaily: daily_at counts in its zone (Helsinki is UTC+3 in
// June, UTC+2 in January), a claim fills Due and moves to the next day, and
// an edit that drops the trigger clears the time.
func TestTopicLoopDaily(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newLoopFix(t, s)
			for _, c := range []struct{ setAt, due string }{
				{"2026-06-15T05:00:00Z", "2026-06-15T06:30:00Z"},
				{"2026-01-15T05:00:00Z", "2026-01-15T07:30:00Z"},
				{"2026-01-15T08:00:00Z", "2026-01-16T07:30:00Z"},
			} {
				at, _ := time.Parse(time.RFC3339, c.setAt)
				want, _ := time.Parse(time.RFC3339, c.due)
				l, err := f.ls.AddTopicLoop(f.ctx, f.tn, TopicLoop{TaskID: f.task, Prompt: "daily", Triggers: []string{LoopDailyAt},
					DailyAt: "09:30", DailyTZ: "Europe/Helsinki", SetBy: "HUM-1", SetAt: at})
				if err != nil || !l.DailyDueAt.Equal(want) || l.DailyAt != "09:30" || l.DailyTZ != "Europe/Helsinki" {
					t.Fatalf("set at %s: %+v %v, want daily due %s", c.setAt, l, err, c.due)
				}
			}
			utc, err := f.ls.AddTopicLoop(f.ctx, f.tn, TopicLoop{TaskID: f.task, Prompt: "utc", Triggers: []string{LoopDailyAt, LoopEveryHour},
				DailyAt: "06:00", SetBy: "HUM-1", SetAt: time.Date(2026, 6, 15, 5, 0, 0, 0, time.UTC)})
			if err != nil || utc.DailyTZ != "UTC" {
				t.Fatalf("no zone: %+v %v, want UTC", utc, err)
			}
			tick := time.Date(2026, 6, 15, 6, 0, 0, 0, time.UTC) // every_hour and daily_at both due
			got, err := f.ls.ClaimDueTopicLoops(f.ctx, tick, 1000)
			if err != nil {
				t.Fatal(err)
			}
			var c TopicLoop
			for _, l := range got {
				if l.LoopID == utc.LoopID {
					c = l
				}
			}
			if !slices.Equal(c.Due, []string{LoopEveryHour, LoopDailyAt}) || !c.DailyDueAt.Equal(tick.Add(24*time.Hour)) ||
				!c.NextDueAt.Equal(tick.Add(time.Hour)) || !c.DueAt.Equal(tick) {
				t.Fatalf("claim: %+v, want Due [every_hour daily_at], daily +1 day, next +1h", c)
			}
			// DST: Helsinki moves to UTC+3 on 2026-03-29; the claim at
			// Saturday's 09:30 (07:30Z) moves to Sunday's 09:30 (06:30Z).
			dst, err := f.ls.AddTopicLoop(f.ctx, f.tn, TopicLoop{TaskID: f.task, Prompt: "dst", Triggers: []string{LoopDailyAt},
				DailyAt: "09:30", DailyTZ: "Europe/Helsinki", SetBy: "HUM-1", SetAt: time.Date(2026, 3, 28, 5, 0, 0, 0, time.UTC)})
			sat := time.Date(2026, 3, 28, 7, 30, 0, 0, time.UTC)
			if err != nil || !dst.DailyDueAt.Equal(sat) {
				t.Fatalf("dst add: %+v %v, want daily due %v", dst, err, sat)
			}
			got, err = f.ls.ClaimDueTopicLoops(f.ctx, sat, 1000)
			if err != nil {
				t.Fatal(err)
			}
			var d TopicLoop
			for _, l := range got {
				if l.LoopID == dst.LoopID {
					d = l
				}
			}
			if sun := time.Date(2026, 3, 29, 6, 30, 0, 0, time.UTC); !d.DailyDueAt.Equal(sun) || !d.DueAt.Equal(sat) {
				t.Fatalf("dst claim: daily due %v, DueAt %v; want %v and %v", d.DailyDueAt, d.DueAt, sun, sat)
			}
			e, err := f.ls.EditTopicLoop(f.ctx, f.tn, f.task, utc.LoopID, TopicLoopEdit{Triggers: []string{LoopEveryHour}, By: "HUM-1", At: tick})
			if err != nil || e.DailyAt != "" || !e.DailyDueAt.IsZero() {
				t.Fatalf("drop daily_at: %+v %v, want the time cleared", e, err)
			}
		})
	}
}

// TestTopicLoopIdle: ArmTopicLoopIdle counts the on loops with
// no_reply_after_human, the claim reports the key and the human post and
// clears the count, ClearTopicLoopIdle answers only the armed loops.
func TestTopicLoopIdle(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newLoopFix(t, s)
			f.t0 = time.Date(2026, 6, 15, 5, 0, 0, 0, time.UTC)
			idle, err := f.ls.AddTopicLoop(f.ctx, f.tn, TopicLoop{TaskID: f.task, Prompt: "nudge", Triggers: []string{LoopNoReplyAfterHuman},
				IdleMin: 10, SetBy: "HUM-1", SetAt: f.t0})
			if err != nil || idle.IdleMin != 10 || !idle.IdleDueAt.IsZero() {
				t.Fatalf("add: %+v %v", idle, err)
			}
			f.add("other", 0, LoopAfterAgentReply)
			post := uuid4()
			if _, err := f.ls.ArmTopicLoopIdle(f.ctx, f.tn, f.task, "nope", f.t0); !errors.Is(err, ErrBadTopicLoop) {
				t.Fatalf("arm with a bad post id: %v, want ErrBadTopicLoop", err)
			}
			if n, err := f.ls.ClearTopicLoopIdle(f.ctx, f.tn, f.task); err != nil || n != 0 {
				t.Fatalf("clear with none armed: %d %v, want 0", n, err)
			}
			if n, err := f.ls.ArmTopicLoopIdle(f.ctx, f.tn, f.task, post, f.t0); err != nil || n != 1 {
				t.Fatalf("arm: %d %v, want 1", n, err)
			}
			claim := func(at time.Time) (TopicLoop, bool) {
				t.Helper()
				got, err := f.ls.ClaimDueTopicLoops(f.ctx, at, 1000)
				if err != nil {
					t.Fatal(err)
				}
				for _, l := range got {
					if l.TenantID == f.tn {
						return l, true
					}
				}
				return TopicLoop{}, false
			}
			if l, ok := claim(f.t0.Add(9 * time.Minute)); ok {
				t.Fatalf("claimed before the idle time: %+v", l)
			}
			l, ok := claim(f.t0.Add(10 * time.Minute))
			if !ok || l.LoopID != idle.LoopID || !slices.Equal(l.Due, []string{LoopNoReplyAfterHuman}) || l.IdlePost != post || !l.IdleDueAt.IsZero() || !l.DueAt.IsZero() {
				t.Fatalf("idle claim: %+v %v, want Due [no_reply_after_human] with the post", l, ok)
			}
			ls, _ := f.ls.TopicLoops(f.ctx, f.tn, f.task)
			for _, l := range ls {
				if !l.IdleDueAt.IsZero() || l.IdlePost != "" {
					t.Fatalf("after the claim: %+v, want the idle count cleared", l)
				}
			}
			if _, err := f.ls.ArmTopicLoopIdle(f.ctx, f.tn, f.task, post, f.t0); err != nil {
				t.Fatal(err)
			}
			if n, err := f.ls.ClearTopicLoopIdle(f.ctx, f.tn, f.task); err != nil || n != 1 {
				t.Fatalf("clear an armed loop: %d %v, want 1", n, err)
			}
			p := TopicLoopPaused
			if _, err := f.ls.EditTopicLoop(f.ctx, f.tn, f.task, idle.LoopID, TopicLoopEdit{State: &p, By: "HUM-1", At: f.t0}); err != nil {
				t.Fatal(err)
			}
			if n, err := f.ls.ArmTopicLoopIdle(f.ctx, f.tn, f.task, post, f.t0); err != nil || n != 0 {
				t.Fatalf("arm a paused loop: %d %v, want 0", n, err)
			}
		})
	}
}

// TestTopicLoopAwaiting: SetTopicLoopAwaiting writes and clears the Q10 A
// mark; a gone loop is ErrNotFound.
func TestTopicLoopAwaiting(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newLoopFix(t, s)
			l := f.add("await", 0, LoopAfterAgentReply)
			until := f.t0.Add(30 * time.Minute)
			if err := f.ls.SetTopicLoopAwaiting(f.ctx, f.tn, l.LoopID, "CLE-07@box-a", until); err != nil {
				t.Fatal(err)
			}
			got, _ := f.ls.TopicLoops(f.ctx, f.tn, f.task)
			if len(got) != 1 || got[0].Awaiting != "CLE-07@box-a" || !got[0].AwaitUntil.Equal(until) {
				t.Fatalf("awaiting: %+v", got)
			}
			if err := f.ls.SetTopicLoopAwaiting(f.ctx, f.tn, l.LoopID, "", until); err != nil {
				t.Fatal(err)
			}
			got, _ = f.ls.TopicLoops(f.ctx, f.tn, f.task)
			if got[0].Awaiting != "" || !got[0].AwaitUntil.IsZero() {
				t.Fatalf("cleared: %+v", got[0])
			}
			if err := f.ls.SetTopicLoopAwaiting(f.ctx, f.tn, uuid4(), "CLE-07", until); !errors.Is(err, ErrNotFound) {
				t.Fatalf("gone loop: %v, want ErrNotFound", err)
			}
		})
	}
}

// TestTopicLoopRowHidden (spec 182 5.2, the row's red control): a loop
// prompt message (Message.LoopID) is stored and read back by FanoutRow, but
// it is in no topic view, no topic list row, no channel count, no batch
// page, no fallback read, no search hit (messages, files, topics), no
// channel stat (count, unread, last) and no browser change; on Postgres it
// moves no topic head and topic_head_diff stays empty.
func TestTopicLoopRowHidden(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newLoopFix(t, s)
			now := time.Now().UTC().Truncate(time.Microsecond)
			post := msgFor(f.tn, f.task, "box-desk", now, now, `{"post":"`+uuid4()+`"}`)
			post.Channel, post.FromBox, post.FromID, post.ToBox, post.ToID = "ops", "box-wui", "HUM-1", "box-desk", "CLE-07"
			post.Body = postWord + " the human post"
			loop := post
			loop.MsgID, loop.Env, loop.ReceivedAt, loop.TS = uuid4(), []byte(`{"loop":"`+uuid4()+`"}`), now.Add(time.Second), now.Add(time.Second)
			loop.LoopID = uuid4()
			loop.Body, loop.Files = loopWord+" export this discussion", []byte(`[{"name":"`+loopWord+`.txt","kind":"text"}]`)
			for _, m := range []Message{post, loop} {
				if ok, err := s.InsertMessage(f.ctx, m); err != nil || !ok {
					t.Fatalf("insert %s: %v %v", m.MsgID, ok, err)
				}
			}
			assertLoopRowHidden(t, f, post, loop, now)
		})
	}
}

// loopWord is a word only the loop prompt row of TestTopicLoopRowHidden
// carries, postWord one only its human post carries.
const (
	loopWord = "zebraloopword"
	postWord = "yakpostword"
)

// assertLoopRowHidden is TestTopicLoopRowHidden's checks of every reader.
func assertLoopRowHidden(t *testing.T, f *loopFix, post, loop Message, now time.Time) {
	t.Helper()
	if w, ok := f.s.(WUIWaker); ok {
		if r, err := w.FanoutRow(f.ctx, f.tn, loop.MsgID); err != nil || r.LoopID != loop.LoopID {
			t.Fatalf("FanoutRow loop_id %q %v, want %q", r.LoopID, err, loop.LoopID)
		}
	}
	vm, err := f.s.ViewTopic(f.ctx, f.tn, TopicMsgQuery{TaskID: f.task, Now: now, Limit: 50})
	if err != nil || len(vm) != 1 || vm[0].MsgID != post.MsgID {
		t.Fatalf("topic view: %d rows %v, want only the post (the loop prompt is shown to nobody)", len(vm), err)
	}
	rows, err := f.s.ViewTopics(f.ctx, f.tn, TopicQuery{Now: now, Limit: 50})
	if err != nil || len(rows) != 1 || rows[0].Count != 1 || !rows[0].LastAt.Equal(post.ReceivedAt) {
		t.Fatalf("topic list: %+v %v, want one row of one line, last at the post", rows, err)
	}
	if ch, err := f.s.ViewChannels(f.ctx, f.tn, now); err != nil || len(ch) != 1 || ch[0].Count != 1 {
		t.Fatalf("channel counts: %+v %v, want ops with 1", ch, err)
	}
	if tm, ok := f.s.(TopicsMessager); ok {
		page, _, err := tm.ViewTopicsMessages(f.ctx, f.tn, TopicsMsgQuery{TaskIDs: []string{f.task}, PerTopic: 50, Now: now})
		if err != nil || len(page[f.task]) != 1 || page[f.task][0].MsgID != post.MsgID {
			t.Fatalf("batch page: %+v %v, want only the post", page[f.task], err)
		}
	}
	assertLoopRowUnsearched(t, f, post, now)
	assertLoopRowNoStatNoChange(t, f, post, now)
	fb := f.s.(Fallbacks)
	for what, read := range map[string]func() ([]Queued, error){
		"unheard": func() ([]Queued, error) {
			return fb.UnheardPosts(f.ctx, f.tn, now.Add(-time.Minute), now.Add(time.Minute), 20)
		},
		"unanswered": func() ([]Queued, error) {
			return fb.UnansweredPosts(f.ctx, f.tn, now.Add(-time.Minute), now.Add(time.Minute), 20)
		},
	} {
		q, err := read()
		if err != nil || len(q) != 1 || q[0].MsgID != post.MsgID {
			t.Fatalf("%s posts: %+v %v, want only the human post", what, q, err)
		}
	}
	pg, ok := f.s.(*Postgres)
	if !ok {
		return
	}
	var last string
	if err := pg.asOperator(f.ctx, func(tx pgx.Tx) error {
		if err := tx.QueryRow(f.ctx, `SELECT last_msg_id::text FROM topic_heads WHERE tenant_id = $1 AND task_id = $2`,
			f.tn, f.task).Scan(&last); err != nil {
			return err
		}
		var n int
		if err := tx.QueryRow(f.ctx, `SELECT count(*) FROM topic_head_diff($1)`, f.tn).Scan(&n); err != nil || n != 0 {
			t.Errorf("topic_head_diff: %d rows %v, want none", n, err)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if last != post.MsgID {
		t.Fatalf("topic head last_msg_id %s, want the post %s (a loop row moves no head)", last, post.MsgID)
	}
}

// assertLoopRowUnsearched: a search for loopWord finds no message, no file
// and no topic, and the topic a search for postWord finds counts only the
// post (spec 182 5.2, the search statements).
func assertLoopRowUnsearched(t *testing.T, f *loopFix, post Message, now time.Time) {
	t.Helper()
	pq, err := search.Parse(loopWord, now)
	if err != nil {
		t.Fatal(err)
	}
	q := SearchQuery{Q: pq, Now: now, Limit: 20}
	sr := f.s.(Searcher)
	ms, err := sr.SearchMessages(f.ctx, f.tn, q)
	if err != nil || len(ms) != 0 {
		t.Fatalf("search messages %q: %+v %v, want none", loopWord, ms, err)
	}
	fs, err := sr.SearchFiles(f.ctx, f.tn, q)
	if err != nil || len(fs) != 0 {
		t.Fatalf("search files %q: %+v %v, want none", loopWord, fs, err)
	}
	ts, err := sr.SearchTopics(f.ctx, f.tn, q)
	if err != nil || len(ts) != 0 {
		t.Fatalf("search topics %q: %+v %v, want none", loopWord, ts, err)
	}
	if q.Q, err = search.Parse(postWord, now); err != nil {
		t.Fatal(err)
	}
	if ts, err = sr.SearchTopics(f.ctx, f.tn, q); err != nil || len(ts) != 1 || ts[0].Count != 1 || !ts[0].LastAt.Equal(post.ReceivedAt) {
		t.Fatalf("search topics %q: %+v %v, want one topic of one line, last at the post", postWord, ts, err)
	}
}

// assertLoopRowNoStatNoChange: the channel's stat counts only the post, for
// a reader with no mark and one with a mark before both rows, and the
// browser's change poll lists only the post as new.
func assertLoopRowNoStatNoChange(t *testing.T, f *loopFix, post Message, now time.Time) {
	t.Helper()
	before := map[string]ReadMark{"ops": {At: post.ReceivedAt.Add(-time.Minute)}}
	for what, reads := range map[string]map[string]ReadMark{"no mark": nil, "a mark": before} {
		stats, err := f.s.(Channels).ViewChannelStats(f.ctx, f.tn, now, reads, "HUM-2", "")
		if err != nil {
			t.Fatal(err)
		}
		// ops must be listed: a read that drops the channel row (the newest
		// line a loop row the probe skips) would pass a check that only
		// looks at the rows it finds.
		found := false
		for _, st := range stats {
			if st.ChannelID != "ops" {
				continue
			}
			found = true
			if st.Count != 1 || st.Unread != 1 || st.LastMsgID != post.MsgID {
				t.Fatalf("channel stat, %s: count %d unread %d last %s, want 1 1 %s (the post)", what, st.Count, st.Unread, st.LastMsgID, post.MsgID)
			}
		}
		if !found {
			t.Fatalf("channel stat, %s: no ops row in %d stats, want ops with the post", what, len(stats))
		}
	}
	cs, err := f.s.(ViewChanger).ViewChanges(f.ctx, f.tn, ChangeQuery{Since: post.ReceivedAt.Add(-time.Minute), Now: now, Max: 50})
	if err != nil || len(cs) != 1 || cs[0].MsgID != post.MsgID || cs[0].Kind != ChangeNew {
		t.Fatalf("view changes: %+v %v, want only the post as new", cs, err)
	}
}

// TestTopicLoopSweepPickIndexOnly: the unanswered sweep's k0 pick (L2b,
// spl-unanswered-sweep.func.sh) skips loop rows, so messages_task_received
// carries loop_id and, for the RLS policies' read, is_private_scope (rdb
// 0299): under the operator scope, with every other scan and the sort off,
// the pick is an Index Only Scan, not an Index Scan that reads the heap.
func TestTopicLoopSweepPickIndexOnly(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	var def string
	if err := pg.pool.QueryRow(ctx, `SELECT indexdef FROM pg_indexes
		WHERE schemaname = current_schema() AND indexname = 'messages_task_received'`).Scan(&def); err != nil {
		t.Fatal(err)
	}
	want := "(tenant_id, task_id, received_at, msg_id) INCLUDE (expires_at, channel, from_id, from_box, to_id, to_box, kind, parent_task_id, loop_id, is_private_scope)"
	if !strings.HasSuffix(def, want) {
		t.Fatalf("messages_task_received: %s, want it to end %s", def, want)
	}
	var plan []string
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = off; SET LOCAL enable_indexscan = off; SET LOCAL enable_sort = off`); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `EXPLAIN SELECT DISTINCT ON (m.tenant_id, m.task_id) m.tenant_id, m.msg_id
			FROM messages m
			WHERE m.expires_at > now() AND m.received_at > now() - make_interval(days => 7) AND m.loop_id IS NULL
			ORDER BY m.tenant_id DESC, m.task_id DESC, m.received_at DESC, m.msg_id DESC`)
		if err != nil {
			return err
		}
		return scanRows(rows, func(rows pgx.Rows) error {
			var line string
			err := rows.Scan(&line)
			plan = append(plan, line)
			return err
		})
	}); err != nil {
		t.Fatal(err)
	}
	only := slices.ContainsFunc(plan, func(l string) bool {
		return strings.Contains(l, "Index Only Scan") && strings.Contains(l, "using messages_task_received ")
	})
	if !only {
		t.Fatalf("k0 pick plan:\n%s\nwant an Index Only Scan of messages_task_received", strings.Join(plan, "\n"))
	}
}
