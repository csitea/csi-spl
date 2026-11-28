package store

import (
	"errors"
	"testing"
	"time"
)

// Spec 182 v0.12 (SPL-6744, rdb 0334; owner HUM-10, t1 0cf1d4cf msg
// 122b69a5): the work window of the every_* triggers. The due-time walk runs
// on a fake clock; the store rules run on Memory and, with
// SPOOL_TEST_PG_DSN, on Postgres with the same assertions.

// helsinki is the zone of the owner's example.
const helsinki = "Europe/Helsinki"

// windowLoop is an hourly loop, Monday to Friday, 08:00..17:00 Helsinki.
func windowLoop() TopicLoop {
	return TopicLoop{Triggers: []string{LoopEveryHour}, State: TopicLoopOn, DailyTZ: helsinki,
		WindowFrom: "08:00", WindowTo: "17:00", WorkdaysOnly: true}
}

func zt(t *testing.T, s string) time.Time {
	t.Helper()
	v, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// TestTopicLoopWindowDue: topicLoopDue's walk on a fake clock. Helsinki is
// UTC+2 in winter, UTC+3 from 2026-03-29 (a Sunday).
func TestTopicLoopWindowDue(t *testing.T) {
	every45 := TopicLoop{Triggers: []string{LoopEveryNMinutes}, IntervalMin: 45, State: TopicLoopOn, DailyTZ: helsinki, WorkdaysOnly: true}
	daily := TopicLoop{Triggers: []string{LoopEveryHour}, State: TopicLoopOn, DailyTZ: helsinki, WindowFrom: "08:00", WindowTo: "17:00"}
	utc := TopicLoop{Triggers: []string{LoopEveryHour}, State: TopicLoopOn, WindowFrom: "08:00", WindowTo: "17:00", WorkdaysOnly: true}
	for why, c := range map[string]struct {
		l        TopicLoop
		from, at string
	}{
		"Friday 16:30 -> Monday 08:00":       {windowLoop(), "2026-11-27T14:30:00Z", "2026-11-30T06:00:00Z"},
		"weekday before the window -> start": {windowLoop(), "2026-12-01T04:10:00Z", "2026-12-01T06:00:00Z"},
		"inside -> + interval":               {windowLoop(), "2026-12-01T07:00:00Z", "2026-12-01T08:00:00Z"},
		"the end minute is inside":           {windowLoop(), "2026-12-01T14:00:00Z", "2026-12-01T15:00:00Z"},
		"past the end -> next day 08:00":     {windowLoop(), "2026-12-01T14:01:00Z", "2026-12-02T06:00:00Z"},
		"Saturday -> Monday 08:00":           {windowLoop(), "2026-11-28T09:00:00Z", "2026-11-30T06:00:00Z"},
		"DST weekend: Monday 08:00 is +3":    {windowLoop(), "2026-03-27T14:30:00Z", "2026-03-30T05:00:00Z"},
		"DST weekend, fall back: +2 again":   {windowLoop(), "2026-10-23T13:30:00Z", "2026-10-26T06:00:00Z"},
		"workdays only, all day: Saturday":   {every45, "2026-11-28T08:00:00Z", "2026-11-29T22:00:00Z"},
		"workdays only, all day: a weekday":  {every45, "2026-12-01T08:00:00Z", "2026-12-01T08:45:00Z"},
		"hours only: Saturday is a day too":  {daily, "2026-11-28T14:30:00Z", "2026-11-29T06:00:00Z"},
		"no zone is UTC":                     {utc, "2026-11-27T16:30:00Z", "2026-11-30T08:00:00Z"},
		"DST change day, spring: to start":   {daily, "2026-03-29T03:00:00Z", "2026-03-29T05:00:00Z"},
		"DST change day, spring: past end":   {daily, "2026-03-29T14:00:00Z", "2026-03-30T05:00:00Z"},
		"DST change day, fall: to start":     {daily, "2026-10-25T05:00:00Z", "2026-10-25T06:00:00Z"},
	} {
		if got := topicLoopDue(c.l, zt(t, c.from)); !got.Equal(zt(t, c.at)) {
			t.Errorf("%s: due %v, want %s", why, got.UTC(), c.at)
		}
	}
	// No limit is today's rule exactly: from + period, whatever the day.
	plain := TopicLoop{Triggers: []string{LoopEveryHour}, State: TopicLoopOn, DailyTZ: helsinki}
	if from := zt(t, "2026-11-28T22:30:00Z"); !topicLoopDue(plain, from).Equal(from.Add(time.Hour)) {
		t.Errorf("no window: %v, want from + 1h", topicLoopDue(plain, from))
	}
}

// TestTopicLoopWindowLateClaim: W4 on the claim (R7 W1, the reviewer's
// probe): a slot due inside the window but claimed after its end (a late
// ticker) fires nothing and moves to the next slot; a claim inside fires;
// a loop with no window fires late as before.
func TestTopicLoopWindowLateClaim(t *testing.T) {
	l := windowLoop()
	l.NextDueAt = zt(t, "2026-11-27T15:00:00Z")                 // Friday 17:00 Helsinki
	got, ok := topicLoopClaim(l, zt(t, "2026-11-27T18:00:00Z")) // Friday 20:00
	if !ok || len(got.Due) != 0 || !got.NextDueAt.Equal(zt(t, "2026-11-30T06:00:00Z")) {
		t.Errorf("late claim: ok=%v due=%v next=%v, want claimed, no key, next Monday 08:00", ok, got.Due, got.NextDueAt.UTC())
	}
	if got, ok := topicLoopClaim(l, zt(t, "2026-11-27T15:00:00Z")); !ok || len(got.Due) != 1 || got.Due[0] != LoopEveryHour {
		t.Errorf("claim at 17:00: ok=%v due=%v, want every_hour", ok, got.Due)
	}
	plain := TopicLoop{Triggers: []string{LoopEveryHour}, State: TopicLoopOn, DailyTZ: helsinki, NextDueAt: l.NextDueAt}
	if got, ok := topicLoopClaim(plain, zt(t, "2026-11-27T18:00:00Z")); !ok || len(got.Due) != 1 ||
		!got.NextDueAt.Equal(zt(t, "2026-11-27T19:00:00Z")) {
		t.Errorf("no window, late: ok=%v due=%v next=%v, want every_hour and at + 1h", ok, got.Due, got.NextDueAt.UTC())
	}
}

// TestTopicLoopWindowStore: a loop with a window is stored and read back,
// its first due time is in the window, the claim moves it to the window's
// next slot (no catch-up), and an edit that drops the time trigger clears
// the window; bad windows are refused before any write.
func TestTopicLoopWindowStore(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newLoopFix(t, s)
			bad := func(fn func(l *TopicLoop)) TopicLoop {
				l := windowLoop()
				l.TaskID, l.Prompt, l.SetBy = f.task, "p", "HUM-1"
				fn(&l)
				return l
			}
			for why, l := range map[string]TopicLoop{
				"overnight window":      bad(func(l *TopicLoop) { l.WindowFrom, l.WindowTo = "22:00", "06:00" }),
				"empty window":          bad(func(l *TopicLoop) { l.WindowTo = "08:00" }),
				"only a start":          bad(func(l *TopicLoop) { l.WindowTo = "" }),
				"only an end":           bad(func(l *TopicLoop) { l.WindowFrom = "" }),
				"not hh:mm":             bad(func(l *TopicLoop) { l.WindowFrom = "8:00" }),
				"24:00":                 bad(func(l *TopicLoop) { l.WindowTo = "24:00" }),
				"window on a non-timer": bad(func(l *TopicLoop) { l.Triggers = []string{LoopAfterHumanReply} }),
				"workdays on daily_at": bad(func(l *TopicLoop) {
					l.Triggers, l.DailyAt, l.WindowFrom, l.WindowTo = []string{LoopDailyAt}, "09:00", "", ""
				}),
			} {
				if _, err := f.ls.AddTopicLoop(f.ctx, f.tn, l); !errors.Is(err, ErrBadTopicLoop) {
					t.Errorf("%s: %v, want ErrBadTopicLoop", why, err)
				}
			}
			l := windowLoop()
			l.TaskID, l.Prompt, l.SetBy, l.SetAt = f.task, "hourly at work", "HUM-1", zt(t, "2026-11-27T14:30:00Z") // Friday 16:30
			got, err := f.ls.AddTopicLoop(f.ctx, f.tn, l)
			if err != nil || got.WindowFrom != "08:00" || got.WindowTo != "17:00" || !got.WorkdaysOnly ||
				!got.NextDueAt.Equal(zt(t, "2026-11-30T06:00:00Z")) {
				t.Fatalf("add: %+v %v, want the window stored and Monday 08:00 due", got, err)
			}
			read, err := f.ls.TopicLoops(f.ctx, f.tn, f.task)
			if err != nil || len(read) != 1 || read[0].WindowFrom != "08:00" || read[0].WindowTo != "17:00" || !read[0].WorkdaysOnly {
				t.Fatalf("read back: %+v %v", read, err)
			}
			claim := func(at time.Time) TopicLoop {
				t.Helper()
				out, err := f.ls.ClaimDueTopicLoops(f.ctx, at, 1000)
				if err != nil {
					t.Fatal(err)
				}
				for _, c := range out {
					if c.LoopID == got.LoopID {
						return c
					}
				}
				return TopicLoop{}
			}
			if c := claim(zt(t, "2026-11-30T05:59:00Z")); c.LoopID != "" {
				t.Fatalf("claimed before the window: %+v", c)
			}
			c := claim(zt(t, "2026-11-30T15:00:00Z")) // Monday 17:00, after a missed day: one fire, no burst
			if c.LoopID == "" || !c.NextDueAt.Equal(zt(t, "2026-12-01T06:00:00Z")) || !c.DueAt.Equal(zt(t, "2026-11-30T06:00:00Z")) {
				t.Fatalf("claim at 17:00: %+v, want next due Tuesday 08:00", c)
			}
			if again, err := f.ls.TopicLoops(f.ctx, f.tn, f.task); err != nil || !again[0].NextDueAt.Equal(c.NextDueAt) {
				t.Fatalf("stored next due: %+v %v, want %v", again, err, c.NextDueAt)
			}
			late := claim(zt(t, "2026-12-01T18:00:00Z")) // Tuesday 20:00: the 08:00 slot claimed late, outside
			if late.LoopID == "" || len(late.Due) != 0 || !late.NextDueAt.Equal(zt(t, "2026-12-02T06:00:00Z")) {
				t.Fatalf("late claim outside the window: %+v, want claimed with no key, next due Wednesday 08:00", late)
			}
			to := "16:00"
			e, err := f.ls.EditTopicLoop(f.ctx, f.tn, f.task, got.LoopID, TopicLoopEdit{WindowTo: &to, By: "HUM-1",
				At: zt(t, "2026-12-01T13:30:00Z")}) // Tuesday 15:30 + 1h is past 16:00
			if err != nil || e.WindowTo != "16:00" || !e.NextDueAt.Equal(zt(t, "2026-12-02T06:00:00Z")) {
				t.Fatalf("edit window_to: %+v %v, want Wednesday 08:00", e, err)
			}
			e, err = f.ls.EditTopicLoop(f.ctx, f.tn, f.task, got.LoopID, TopicLoopEdit{Triggers: []string{LoopAfterHumanReply}, By: "HUM-1", At: f.t0})
			if err != nil || e.WindowFrom != "" || e.WindowTo != "" || e.WorkdaysOnly || !e.NextDueAt.IsZero() {
				t.Fatalf("drop the time trigger: %+v %v, want the window cleared", e, err)
			}
		})
	}
}
