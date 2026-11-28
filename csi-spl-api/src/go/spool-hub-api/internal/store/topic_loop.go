package store

import (
	"context"
	"errors"
	"slices"
	"sort"
	"strings"
	"time"
)

// Discussion loops (spec 182 v0.4 sections 4, 5 and 7.1.1, row L1, rdb
// 0301). The owner (HUM-10, t1 f08c0c58, msg b20e28e9): "setup a txt prompt
// for discussion, which will execute on either agent reply or human prompt
// or another human prompt"; the eleven triggers, msgs d44af000 and
// a1d73b19, less before_human_reply (Q11 C, msg 46e61a8c).
//
//   - a loop is one topic_loops row: its prompt, its checked triggers (spec
//     182 1.2), the fields some triggers need (the n of "each n minutes",
//     the keyword, the idle n, the daily time and zone), on or paused, its
//     author, its hour counter, its three due times and the agent whose
//     answer it awaits (Q10 A). A topic has any number of them (answer 6 B);
//   - a fire counts in the same statement that checks the cap (answer 4 B:
//     at most cap fires in the loop's hour, then it holds until the hour
//     rolls over), so two hub instances never fire past it; the time
//     ticker claims the due loops the same way;
//   - the message a fire stores carries Message.LoopID (messages.loop_id),
//     and no view, topic head or fallback read shows it (spec 182 5.2).
//
// The contract is spec 182 7.1.1 (binding): who may write a loop, when it
// fires, what it sends and the ticker are the hub's (row L2).

// The triggers (spec 182 1.2, Q11 C dropped before_human_reply; v0.11
// change 9 split post_has_file by poster, the old key stays readable and
// firing), the bounds of the fields some of them need, the states and the
// prompt's length.
const (
	LoopAfterAgentReply    = "after_agent_reply"
	LoopBeforeAgentReply   = "before_agent_reply"
	LoopAfterHumanReply    = "after_human_reply"
	LoopEveryHour          = "every_hour"
	LoopEveryNMinutes      = "every_n_minutes"
	LoopPostHasKeyword     = "post_has_keyword"     // v0.4
	LoopPostHasFile        = "post_has_file"        // v0.4; v0.11: no longer offered, still fires
	LoopPostHasFileAgent   = "post_has_file_agent"  // v0.11 change 9
	LoopPostHasFileHuman   = "post_has_file_human"  // v0.11 change 9
	LoopBlockerPosted      = "blocker_posted"       // v0.4
	LoopNoReplyAfterHuman  = "no_reply_after_human" // v0.4
	LoopIssueStatusChanged = "issue_status_changed" // v0.4
	LoopDailyAt            = "daily_at"             // v0.4
	TopicLoopIntervalMin   = 5                      // minutes; also the idle n's bounds
	TopicLoopIntervalMax   = 1440                   // minutes
	TopicLoopKeywordMax    = 200                    // characters, rdb CHECK (v0.4)
	TopicLoopOn            = "on"
	TopicLoopPaused        = "paused"
	TopicLoopPromptMax     = 4000 // characters, rdb CHECK
)

// TopicLoopTriggers: the thirteen keys in the order of 1.2 (v0.4, less Q11 C,
// plus the two file keys of v0.11 change 9 after post_has_file). A new
// trigger is a key here, a new rdb CHECK, and, when it needs a field, a
// row of topicLoopFields.
var TopicLoopTriggers = []string{LoopAfterAgentReply, LoopBeforeAgentReply,
	LoopAfterHumanReply, LoopEveryHour, LoopEveryNMinutes,
	LoopPostHasKeyword, LoopPostHasFile, LoopPostHasFileAgent, LoopPostHasFileHuman,
	LoopBlockerPosted, LoopNoReplyAfterHuman,
	LoopIssueStatusChanged, LoopDailyAt}

// TopicLoopCapDefault is the fires a loop may make in its hour when the
// caller passes no cap (SPOOL_HUB_TOPIC_LOOP_CAP, spec 182 5.1).
const TopicLoopCapDefault = 12

// topicLoopClaimDefault is ClaimDueTopicLoops' limit when none is given.
const topicLoopClaimDefault = 100

// topicLoopUTC is the zone a loop with no DailyTZ is read and written as.
const topicLoopUTC = "UTC"

// ErrBadTopicLoop: an empty or too long prompt, no trigger, an unknown
// trigger or state, a missing or stray interval, keyword, idle n or daily
// time, a daily zone time.LoadLocation refuses, a bad work window (v0.12),
// or a set_by not 1..64 characters. Before any write.
var ErrBadTopicLoop = errors.New("store: a topic loop needs a prompt (1..4000 characters), 1..13 known triggers, an interval of 5..1440 minutes exactly with every_n_minutes, a keyword of 1..200 characters exactly with post_has_keyword, an idle n of 5..1440 minutes exactly with no_reply_after_human, a time and a known zone exactly with daily_at, a work window (window_from before window_to, both hh:mm, the same day; workdays_only) only with every_hour or every_n_minutes, state on|paused and who (1..64)")

// TopicLoop is one topic_loops row.
type TopicLoop struct {
	TenantID    string
	LoopID      string // uuid, lower case
	TaskID      string // uuid, lower case
	Prompt      string
	Triggers    []string // distinct, sorted
	SetBy       string   // the member id (hum) of who set it; the v:1 from is derived from it at fire time (spec 182 v0.5)
	SetAt       time.Time
	State       string    // TopicLoopOn | TopicLoopPaused
	HourStart   time.Time // zero: never fired
	FiresInHour int
	FiresTotal  int
	LastFiredAt time.Time // zero: never fired
	IntervalMin int       // 0 unless every_n_minutes
	NextDueAt   time.Time // zero: no time trigger, or paused
	Awaiting    string    // Q10 A: the agent whose next reply does not fire this loop
	AwaitUntil  time.Time
	// v0.4
	Keyword    string    // "" unless post_has_keyword
	IdleMin    int       // 0 unless no_reply_after_human
	IdleDueAt  time.Time // zero: not armed, or paused
	IdlePost   string    // msg_id of the human post that armed it; "" when not armed
	DailyAt    string    // "hh:mm", "" unless daily_at
	DailyTZ    string    // IANA zone; "" is read and written as "UTC"
	DailyDueAt time.Time // zero: no daily_at, or paused
	Due        []string  // set only by ClaimDueTopicLoops: the time keys that came due this claim
	DueAt      time.Time // v0.5, set only by ClaimDueTopicLoops: the earliest of NextDueAt, DailyDueAt that came due, as it was BEFORE the move; zero when only the idle key came due
	Position   int       // v0.11 (rdb 0329): its place in the topic's list, 0 first; an add goes last
	// v0.12 (rdb 0334, SPL-6744): the work window of the every_* triggers,
	// read in DailyTZ. Both "" and false: no limit, the behaviour before.
	WindowFrom   string // "hh:mm", the first minute a fire may be due; "" = all day
	WindowTo     string // "hh:mm", the last (inclusive); set exactly with WindowFrom, after it
	WorkdaysOnly bool   // Monday to Friday only (no public holidays)
}

// Has reports a checked trigger.
func (l TopicLoop) Has(trigger string) bool { return slices.Contains(l.Triggers, trigger) }

// HeldUntil is when a loop the cap holds at now fires again (spec 182
// 7.1.2 held_until: HourStart + 1h once FiresInHour reaches the cap);
// false when the cap does not hold it.
func (l TopicLoop) HeldUntil(now time.Time, limit int) (time.Time, bool) {
	end := l.HourStart.Add(time.Hour)
	if l.HourStart.IsZero() || l.FiresInHour < topicLoopCap(limit) || !now.Before(end) {
		return time.Time{}, false
	}
	return end, true
}

// TopicLoopEdit: nil / empty fields are kept. A changed Prompt or Triggers
// resets HourStart and FiresInHour. By becomes SetBy and At SetAt (4.5).
type TopicLoopEdit struct {
	Prompt   *string
	Triggers []string // nil: keep
	Interval *int     // nil: keep
	State    *string
	Keyword  *string // v0.4; nil: keep
	IdleMin  *int    // v0.4; nil: keep
	DailyAt  *string // v0.4; nil: keep
	DailyTZ  *string // v0.4; nil: keep
	// v0.12; nil: keep. "" clears a window bound.
	WindowFrom   *string
	WindowTo     *string
	WorkdaysOnly *bool
	By           string
	At           time.Time
}

// TopicLoopStore is spec 182 7.1.1, implemented by Memory and Postgres, in
// the workspace's own scope (ClaimDueTopicLoops: every workspace). The hub
// reads it as an optional interface.
type TopicLoopStore interface {
	// TopicLoops: every loop of taskID, Position, SetAt then LoopID order.
	// ErrBadTopicTask (topic_priority.go:29) on a non-uuid task.
	TopicLoops(ctx context.Context, tenant, taskID string) ([]TopicLoop, error)
	// TopicLoopsOn: only State == on; the fire path's one index probe (4.2 step 6).
	TopicLoopsOn(ctx context.Context, tenant, taskID string) ([]TopicLoop, error)
	// AddTopicLoop stores l (LoopID minted with uid.New when ""), State on.
	// ErrBadTopicTask, ErrBadTopicLoop; ErrNotFound: no such workspace.
	AddTopicLoop(ctx context.Context, tenant string, l TopicLoop) (TopicLoop, error)
	// EditTopicLoop: ErrNotFound when loopID is not a loop of taskID.
	EditTopicLoop(ctx context.Context, tenant, taskID, loopID string, e TopicLoopEdit) (TopicLoop, error)
	// DeleteTopicLoop: false when there was no such loop (never an error).
	DeleteTopicLoop(ctx context.Context, tenant, taskID, loopID string) (bool, error)
	// DeleteTopicLoops: every loop of taskID (the archive path, 4.5); the count.
	DeleteTopicLoops(ctx context.Context, tenant, taskID string) (int, error)
	// CountTopicLoopFire is 5.1's single UPDATE: true and the row after it
	// when the loop is on and under cap in its hour (rolling the hour when
	// HourStart <= at - 1h); false when paused, capped or gone.
	CountTopicLoopFire(ctx context.Context, tenant, loopID string, at time.Time, cap int) (TopicLoop, bool, error)
	// ClaimDueTopicLoops is the time ticker's one UPDATE (4.2 step 5): up to
	// limit on state-on loops where any of NextDueAt, IdleDueAt, DailyDueAt
	// is <= at, every workspace. In the same statement it moves NextDueAt on
	// by the interval, DailyDueAt to the next DailyAt in DailyTZ, and sets
	// IdleDueAt to zero; each row as claimed carries Due (v0.4: was only
	// NextDueAt), e.g. ["every_n_minutes", "no_reply_after_human"], and
	// IdlePost as it was before the clear.
	ClaimDueTopicLoops(ctx context.Context, at time.Time, limit int) ([]TopicLoop, error)
	// ArmTopicLoopIdle (v0.4, 4.2 step 11): on every state-on loop of taskID
	// with no_reply_after_human, IdleDueAt = at + IdleMin and IdlePost =
	// postID. The count of loops armed.
	ArmTopicLoopIdle(ctx context.Context, tenant, taskID, postID string, at time.Time) (int, error)
	// ClearTopicLoopIdle (v0.4): IdleDueAt and IdlePost cleared on every
	// loop of taskID. The count cleared.
	ClearTopicLoopIdle(ctx context.Context, tenant, taskID string) (int, error)
	// SetTopicLoopAwaiting writes Awaiting / AwaitUntil (Q10 A); "" clears.
	SetTopicLoopAwaiting(ctx context.Context, tenant, loopID, agent string, until time.Time) error
	// TenantHasTopicLoops refreshes the hub's in-memory bit (4.2 step 6).
	TenantHasTopicLoops(ctx context.Context, tenant string) (bool, error)
}

// TopicLoopOrderStore is spec 182 v0.11 change 8 (SPL-6587, rdb 0329): the
// list's order, a store of its own so a TopicLoopStore without it still
// serves every other route (the hub answers 501 on the order route).
type TopicLoopOrderStore interface {
	// OrderTopicLoops sets Position 0..n-1 on taskID's loops in loopIDs'
	// order, in one transaction, and returns the list as TopicLoops reads
	// it. loopIDs names every loop of taskID exactly once, else
	// ErrBadTopicLoopOrder and nothing is written; ErrBadTopicTask.
	OrderTopicLoops(ctx context.Context, tenant, taskID string, loopIDs []string) ([]TopicLoop, error)
}

// ErrBadTopicLoopOrder: an order that does not name each of the topic's
// loops exactly once (a loop missing, twice, or not of the topic).
var ErrBadTopicLoopOrder = errors.New("store: a loop order names every loop of the topic exactly once")

var (
	_ TopicLoopStore      = (*Memory)(nil)
	_ TopicLoopStore      = (*Postgres)(nil)
	_ TopicLoopOrderStore = (*Memory)(nil)
	_ TopicLoopOrderStore = (*Postgres)(nil)
)

// topicLoopOrder is loopIDs lower cased when they are exactly the ids of
// have (each once, any order), else ErrBadTopicLoopOrder.
func topicLoopOrder(have []TopicLoop, loopIDs []string) ([]string, error) {
	if len(loopIDs) != len(have) {
		return nil, ErrBadTopicLoopOrder
	}
	want := make(map[string]bool, len(have))
	for _, l := range have {
		want[l.LoopID] = true
	}
	out := make([]string, len(loopIDs))
	for i, id := range loopIDs {
		id = strings.ToLower(id)
		if !want[id] {
			return nil, ErrBadTopicLoopOrder
		}
		delete(want, id)
		out[i] = id
	}
	return out, nil
}

// Further rules both stores share, beyond the contract's comments:
//   - Triggers are stored sorted by name (sort.Strings), duplicates dropped;
//     Keyword is trimmed, DailyAt is "hh:mm" (Go's "15:04"), DailyTZ any
//     zone time.LoadLocation knows but "Local".
//   - NextDueAt is SetAt (an add) or the edit's At plus the loop's period
//     (topicLoopPeriod) while it is on, zero otherwise; DailyDueAt is the
//     first DailyAt in DailyTZ strictly after that time (topicLoopNextDaily).
//     An edit recomputes both and disarms the idle count when it changes
//     the state, the triggers or a time field (interval, idle n, daily time
//     or zone); pausing zeroes all three due times.
//   - New Triggers that leave out a trigger whose field the edit does not
//     set clear that field (IntervalMin, Keyword, IdleMin, DailyAt).
//   - ClaimDueTopicLoops moves each due time from at, so a tick missed
//     while no hub ran fires once, never a catch-up burst. Due lists the
//     keys in TopicLoopTriggers order: every_hour and every_n_minutes when
//     NextDueAt came due (each one whose own period is the loop's period),
//     no_reply_after_human for IdleDueAt, daily_at for DailyDueAt. It
//     answers the rows after the move, by tenant then loop id.
//   - ArmTopicLoopIdle refuses a postID that is not a uuid
//     (ErrBadTopicLoop); ClearTopicLoopIdle counts the loops that were
//     armed.
//   - SetTopicLoopAwaiting: ErrNotFound when the loop is gone; an agent id
//     over 64 characters is ErrBadTopicLoop.

// topicLoopField is a field that is set exactly when its trigger is
// checked (rdb 0301's pairing CHECKs).
type topicLoopField struct {
	trigger string
	set     func(l TopicLoop) bool
	clear   func(l *TopicLoop)
	valid   func(l TopicLoop) bool
}

// topicLoopFields are the triggers that carry a field.
var topicLoopFields = []topicLoopField{
	{LoopEveryNMinutes, func(l TopicLoop) bool { return l.IntervalMin != 0 }, func(l *TopicLoop) { l.IntervalMin = 0 },
		func(l TopicLoop) bool { return topicLoopMinutes(l.IntervalMin) }},
	{LoopPostHasKeyword, func(l TopicLoop) bool { return l.Keyword != "" }, func(l *TopicLoop) { l.Keyword = "" },
		func(l TopicLoop) bool { return len([]rune(l.Keyword)) <= TopicLoopKeywordMax }},
	{LoopNoReplyAfterHuman, func(l TopicLoop) bool { return l.IdleMin != 0 }, func(l *TopicLoop) { l.IdleMin = 0 },
		func(l TopicLoop) bool { return topicLoopMinutes(l.IdleMin) }},
	{LoopDailyAt, func(l TopicLoop) bool { return l.DailyAt != "" }, func(l *TopicLoop) { l.DailyAt = "" },
		func(l TopicLoop) bool { return topicLoopClock(l.DailyAt) }},
}

// topicLoopMinutes reports n in TopicLoopIntervalMin..TopicLoopIntervalMax.
func topicLoopMinutes(n int) bool { return n >= TopicLoopIntervalMin && n <= TopicLoopIntervalMax }

// topicLoopClock reports an "hh:mm" time of day.
func topicLoopClock(s string) bool {
	_, err := time.Parse("15:04", s)
	return err == nil && len(s) == 5
}

// topicLoopZone is tz's location ("" is UTC); false for a zone
// time.LoadLocation does not know, and for "Local" (the hub box's zone).
func topicLoopZone(tz string) (*time.Location, bool) {
	if tz == "" {
		tz = topicLoopUTC
	}
	loc, err := time.LoadLocation(tz)
	return loc, err == nil && tz != "Local"
}

// topicLoopCap is limit, or TopicLoopCapDefault when it is not positive.
func topicLoopCap(limit int) int {
	if limit <= 0 {
		return TopicLoopCapDefault
	}
	return limit
}

// topicLoopPeriod is how often a loop's every_* triggers fire: the shorter
// of an hour (every_hour) and IntervalMin (every_n_minutes); 0 with neither.
func topicLoopPeriod(l TopicLoop) time.Duration {
	var p time.Duration
	if l.Has(LoopEveryHour) {
		p = time.Hour
	}
	if n := time.Duration(l.IntervalMin) * time.Minute; l.Has(LoopEveryNMinutes) && n > 0 && (p == 0 || n < p) {
		p = n
	}
	return p
}

// topicLoopPeriodKeys are the every_* keys that come due with NextDueAt:
// each checked one whose own period is the loop's period.
func topicLoopPeriodKeys(l TopicLoop) []string {
	var out []string
	p := topicLoopPeriod(l)
	if l.Has(LoopEveryHour) && p == time.Hour {
		out = append(out, LoopEveryHour)
	}
	if l.Has(LoopEveryNMinutes) && p == time.Duration(l.IntervalMin)*time.Minute {
		out = append(out, LoopEveryNMinutes)
	}
	return out
}

// topicLoopDue is l's NextDueAt counted from from: zero when it is paused
// or has no every_* trigger. With a work window (v0.12) a slot outside it
// moves to the window's next start, so no fire is due outside it and none
// is caught up later.
func topicLoopDue(l TopicLoop, from time.Time) time.Time {
	if p := topicLoopPeriod(l); p > 0 && l.State == TopicLoopOn {
		return topicLoopWindowNext(l, from.Add(p))
	}
	return time.Time{}
}

// topicLoopIsPeriodKey reports an every_* key (the keys NextDueAt brings).
func topicLoopIsPeriodKey(k string) bool { return k == LoopEveryHour || k == LoopEveryNMinutes }

// topicLoopWindowed reports a loop with a work window (v0.12).
func topicLoopWindowed(l TopicLoop) bool { return l.WindowFrom != "" || l.WorkdaysOnly }

// topicLoopWindowNext is the first instant at or after c inside l's work
// window in DailyTZ (spec 182 v0.12): c itself when it is inside, else
// WindowFrom (or midnight) of the next day that may fire. WindowTo is
// inclusive. A WindowFrom that falls in a DST gap takes Go's
// normalisation, as daily_at does.
func topicLoopWindowNext(l TopicLoop, c time.Time) time.Time {
	loc, ok := topicLoopZone(l.DailyTZ)
	if !topicLoopWindowed(l) || !ok {
		return c
	}
	from, to := topicLoopHM(l.WindowFrom, 0), topicLoopHM(l.WindowTo, 24*60)
	d := c.In(loc)
	for i := 0; i <= 7; i++ {
		day := time.Date(d.Year(), d.Month(), d.Day()+i, 0, 0, 0, 0, loc)
		if wd := day.Weekday(); l.WorkdaysOnly && (wd == time.Saturday || wd == time.Sunday) {
			continue
		}
		start := time.Date(day.Year(), day.Month(), day.Day(), 0, from, 0, 0, loc)
		end := time.Date(day.Year(), day.Month(), day.Day(), 0, to, 0, 0, loc)
		switch {
		case i > 0:
			return start.UTC()
		case c.Before(start):
			return start.UTC()
		case !c.After(end) && (l.WindowTo != "" || c.Before(end)):
			return c
		}
	}
	return c // unreachable: a week holds five working days
}

// topicLoopHM is "hh:mm" as minutes after midnight, or def when "".
func topicLoopHM(s string, def int) int {
	t, err := time.Parse("15:04", s)
	if s == "" || err != nil {
		return def
	}
	return t.Hour()*60 + t.Minute()
}

// topicLoopWindowOK is v0.12's rule (rdb 0334's CHECKs): no limit, or a
// limit on a loop with an every_* trigger whose window is both "hh:mm"
// bounds, from before to, or none.
func topicLoopWindowOK(l TopicLoop) bool {
	if !topicLoopWindowed(l) && l.WindowTo == "" {
		return true
	}
	if !l.Has(LoopEveryHour) && !l.Has(LoopEveryNMinutes) {
		return false
	}
	if l.WindowFrom == "" && l.WindowTo == "" {
		return true
	}
	return topicLoopClock(l.WindowFrom) && topicLoopClock(l.WindowTo) && l.WindowFrom < l.WindowTo
}

// topicLoopNextDaily is the first DailyAt in DailyTZ strictly after from
// (the Go twin of topicLoopDailySQL): zero when l is paused or has no
// daily_at. A day whose DailyAt does not exist (a DST gap) takes Go's
// normalisation of it.
func topicLoopNextDaily(l TopicLoop, from time.Time) time.Time {
	loc, ok := topicLoopZone(l.DailyTZ)
	hm, err := time.Parse("15:04", l.DailyAt)
	if !l.Has(LoopDailyAt) || l.State != TopicLoopOn || !ok || err != nil {
		return time.Time{}
	}
	d := from.In(loc)
	at := time.Date(d.Year(), d.Month(), d.Day(), hm.Hour(), hm.Minute(), 0, 0, loc)
	if !at.After(from) {
		at = time.Date(d.Year(), d.Month(), d.Day()+1, hm.Hour(), hm.Minute(), 0, 0, loc)
	}
	return at.UTC()
}

// checkTopicLoopTask validates the tenant and task id; it answers the id as
// rdb 0301 stores it (lower case).
func checkTopicLoopTask(tenant, taskID string) (string, error) {
	if err := checkTenant(tenant); err != nil {
		return "", err
	}
	if !isUUID(taskID) {
		return "", ErrBadTopicTask
	}
	return strings.ToLower(taskID), nil
}

// normTopicLoop is l as rdb 0301 stores it (prompt and keyword trimmed,
// triggers distinct and sorted, ids lower case, the zone UTC when ""), or
// ErrBadTopicLoop.
func normTopicLoop(l TopicLoop) (TopicLoop, error) {
	l.Prompt, l.Keyword = strings.TrimSpace(l.Prompt), strings.TrimSpace(l.Keyword)
	if l.Prompt == "" || len([]rune(l.Prompt)) > TopicLoopPromptMax || l.SetBy == "" || len(l.SetBy) > 64 {
		return TopicLoop{}, ErrBadTopicLoop
	}
	if l.State != TopicLoopOn && l.State != TopicLoopPaused {
		return TopicLoop{}, ErrBadTopicLoop
	}
	if l.DailyTZ == "" {
		l.DailyTZ = topicLoopUTC
	}
	if _, ok := topicLoopZone(l.DailyTZ); !ok || len(l.DailyTZ) > 64 {
		return TopicLoop{}, ErrBadTopicLoop
	}
	ts := make([]string, 0, len(l.Triggers))
	for _, t := range l.Triggers {
		if !slices.Contains(TopicLoopTriggers, t) {
			return TopicLoop{}, ErrBadTopicLoop
		}
		if !slices.Contains(ts, t) {
			ts = append(ts, t)
		}
	}
	sort.Strings(ts)
	l.Triggers = ts
	if len(ts) == 0 {
		return TopicLoop{}, ErrBadTopicLoop
	}
	for _, f := range topicLoopFields {
		if l.Has(f.trigger) != f.set(l) || (f.set(l) && !f.valid(l)) {
			return TopicLoop{}, ErrBadTopicLoop
		}
	}
	if !topicLoopWindowOK(l) {
		return TopicLoop{}, ErrBadTopicLoop
	}
	l.TaskID, l.LoopID = strings.ToLower(l.TaskID), strings.ToLower(l.LoopID)
	return l, nil
}

// newTopicLoop is l checked for an add: the stored row at l.SetAt (now when
// zero), on, its counters zero and its due times from SetAt; LoopID is
// left to the store when "".
func newTopicLoop(tenant string, l TopicLoop) (TopicLoop, error) {
	task, err := checkTopicLoopTask(tenant, l.TaskID)
	if err != nil {
		return TopicLoop{}, err
	}
	if l.LoopID != "" && !isUUID(l.LoopID) {
		return TopicLoop{}, ErrBadTopicLoop
	}
	row := TopicLoop{TenantID: tenant, LoopID: l.LoopID, TaskID: task, Prompt: l.Prompt, Triggers: l.Triggers,
		SetBy: l.SetBy, SetAt: followAt(l.SetAt), State: TopicLoopOn, IntervalMin: l.IntervalMin,
		Keyword: l.Keyword, IdleMin: l.IdleMin, DailyAt: l.DailyAt, DailyTZ: l.DailyTZ,
		WindowFrom: l.WindowFrom, WindowTo: l.WindowTo, WorkdaysOnly: l.WorkdaysOnly}
	if row, err = normTopicLoop(row); err != nil {
		return TopicLoop{}, err
	}
	row.NextDueAt, row.DailyDueAt = topicLoopDue(row, row.SetAt), topicLoopNextDaily(row, row.SetAt)
	return row, nil
}

// applyTopicLoopEdit is old after e (the rules of TopicLoopEdit and the
// list above), checked; both stores write exactly this row.
func applyTopicLoopEdit(old TopicLoop, e TopicLoopEdit) (TopicLoop, error) {
	if e.By == "" || len(e.By) > 64 {
		return TopicLoop{}, ErrBadTopicLoop
	}
	l := old
	l.Triggers = slices.Clone(old.Triggers)
	at := followAt(e.At)
	if e.Triggers != nil {
		l.Triggers = e.Triggers
		for _, f := range topicLoopFields {
			if !slices.Contains(e.Triggers, f.trigger) {
				f.clear(&l)
			}
		}
		if !slices.Contains(e.Triggers, LoopEveryHour) && !slices.Contains(e.Triggers, LoopEveryNMinutes) {
			l.WindowFrom, l.WindowTo, l.WorkdaysOnly = "", "", false // v0.12: the window goes with the time triggers
		}
	}
	setStr(&l.Prompt, e.Prompt)
	setStr(&l.State, e.State)
	setStr(&l.Keyword, e.Keyword)
	setStr(&l.DailyAt, e.DailyAt)
	setStr(&l.DailyTZ, e.DailyTZ)
	setInt(&l.IntervalMin, e.Interval)
	setInt(&l.IdleMin, e.IdleMin)
	setStr(&l.WindowFrom, e.WindowFrom)
	setStr(&l.WindowTo, e.WindowTo)
	if e.WorkdaysOnly != nil {
		l.WorkdaysOnly = *e.WorkdaysOnly
	}
	window := e.WindowFrom != nil || e.WindowTo != nil || e.WorkdaysOnly != nil
	sends := e.Prompt != nil || e.Triggers != nil || e.Interval != nil || e.Keyword != nil ||
		e.IdleMin != nil || e.DailyAt != nil || e.DailyTZ != nil || window
	if sends {
		l.SetBy, l.SetAt = e.By, at
	}
	if e.Prompt != nil || e.Triggers != nil {
		l.HourStart, l.FiresInHour = time.Time{}, 0
	}
	l, err := normTopicLoop(l)
	if err != nil {
		return TopicLoop{}, err
	}
	if e.State != nil || e.Triggers != nil || e.Interval != nil || e.IdleMin != nil || e.DailyAt != nil || e.DailyTZ != nil || window {
		l.NextDueAt, l.DailyDueAt = topicLoopDue(l, at), topicLoopNextDaily(l, at)
		l.IdleDueAt, l.IdlePost = time.Time{}, ""
	}
	return l, nil
}

// setStr sets *dst to *v when v is not nil.
func setStr(dst, v *string) {
	if v != nil {
		*dst = *v
	}
}

// setInt sets *dst to *v when v is not nil.
func setInt(dst, v *int) {
	if v != nil {
		*dst = *v
	}
}

// topicLoopFire is CountTopicLoopFire's rule on l at at (the Memory twin of
// topicLoopFireSQL): the row after the count, or false.
func topicLoopFire(l TopicLoop, at time.Time, limit int) (TopicLoop, bool) {
	rolled := l.HourStart.IsZero() || !l.HourStart.After(at.Add(-time.Hour))
	if l.State != TopicLoopOn || (!rolled && l.FiresInHour >= topicLoopCap(limit)) {
		return l, false
	}
	if rolled {
		l.HourStart, l.FiresInHour = at, 0
	}
	l.FiresInHour++
	l.FiresTotal++
	l.LastFiredAt = at
	return l, true
}

// topicLoopClaim is ClaimDueTopicLoops' move of one claimed loop at at
// (the Memory twin of topicLoopClaimSQL), and whether it was due.
func topicLoopClaim(l TopicLoop, at time.Time) (TopicLoop, bool) {
	due := func(t time.Time) bool { return !t.IsZero() && !t.After(at) }
	if l.State != TopicLoopOn || !(due(l.NextDueAt) || due(l.IdleDueAt) || due(l.DailyDueAt)) {
		return l, false
	}
	l.Due, l.DueAt = nil, time.Time{}
	if due(l.NextDueAt) {
		l.DueAt = l.NextDueAt
	}
	if due(l.DailyDueAt) && (l.DueAt.IsZero() || l.DailyDueAt.Before(l.DueAt)) {
		l.DueAt = l.DailyDueAt
	}
	if due(l.NextDueAt) {
		l.Due = append(l.Due, topicLoopPeriodKeys(l)...)
		l.NextDueAt = topicLoopDue(l, at)
	}
	if due(l.IdleDueAt) {
		l.Due = append(l.Due, LoopNoReplyAfterHuman)
		l.IdleDueAt = time.Time{}
	}
	if due(l.DailyDueAt) {
		l.Due = append(l.Due, LoopDailyAt)
		l.DailyDueAt = topicLoopNextDaily(l, at)
	}
	return l, true
}
