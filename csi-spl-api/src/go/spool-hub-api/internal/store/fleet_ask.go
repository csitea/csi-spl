package store

import (
	"context"
	"errors"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
)

// FleetAsk is one ask to the orchestrator (rdb 0097, CLE-77929, owner bug t1
// 2f7996aa): a blocker, task or escalation sent to whoever holds the fleet
// lease's orch role, keyed by the spool msg_id that carried it. The sender
// fires and forgets; the acting orchestrator (any machine) lists the open
// rows, acks one (in progress) and closes it (done / declined, with a
// reason). A successor reads the same rows, so a holder that dies after
// receiving an ask and before acking it leaves the ask open for the next one.
//
// The record states are Kafka's share-group states (KIP-932; CLE-77942,
// rdb 0099): open = available, acked = acquired (the holder's lock, renewed
// by acking again), done = acknowledged, declined = rejected, dead =
// archived after the delivery limit. The lock's timeout and the limit are
// the lease tick's (ASKS_LOCK_MIN -> AskRelease, ASKS_MAX_RAISES -> AskDead):
// the hub stores the record, the tick is the share coordinator.
//
// A spawn request waits in a queue (rdb 0180, owner HUM-10 t1 c9beaa77):
// queued is open for the ops but the tick never raises it, and Position is
// its rank among its role's queued asks, filled on a list: by Priority, its
// discussion's (rdb 0214, 0241, spec 150 row B9: 1 first, none = 5), then by
// Class (rdb 0195, SPL-1817: ci, a flagged row, refactor, bug, feature), then
// by EnqueuedAt.
//
// Age is now - CreatedAt and Quiet is now - the newest of UpdatedAt and
// RaisedAt, both on the hub's clock, so the machines' clocks never have to
// agree on when an ask is overdue for a re-raise.
type FleetAsk struct {
	Fleet       string
	AskID       string
	Role        string // the recipient role, the log's topic: orch (default) | dispatch | ...
	Kind        string // blocker | task | escalation; role od: route_post | spawn | lane_verify | box_op
	From        string // <ID> or <ID>@<box>
	Topic       string
	Discussion  string // the owner topic (a uuid) it works for, "" = none known (rdb 0241): the hub's put sets it, a later put fills it only while "" and never overwrites (spec 150 B10b)
	Summary     string
	State       string // open | acked | queued | needs_owner | done | declined | dead
	DeadlineAt  time.Time
	AckedBy     string
	ClosedBy    string
	Reason      string
	RaisedN     int
	RaisedAt    time.Time
	EscalatedAt time.Time
	EnqueuedAt  time.Time // set once by the first AskQueue: a stalled placement keeps its place
	Placement   string    // "<vendor>:<slug>" the placer launches; "" = the orchestrator decides
	Class       string    // ci | refactor | bug | feature (rdb 0195); "" = never queued
	Flag        string    // "" | urgent (a bug over its band) | bypass (a feature outside the bands, the owner's ask)
	FlagMsg     string    // bypass: the owner message id that asked for it
	FlagBy      string    // who set Flag
	FlagAt      time.Time // when Flag was set
	Priority    int       // the effective priority 1..5 (filled by ListFleetAsks, askFillPriorities)
	// PrioritySource is where Priority came from: own | discussion | default.
	PrioritySource string
	// The ask's own priority and its dragged place (rdb 0323, spec 153
	// 3.22.6-3.22.7): OwnPriority 0 = never set; QueueRank 0 = unranked (a
	// list reads a rank older than the effective priority as 0: a priority
	// change clears it); RankBy "" = ranked only because a drag landed below.
	OwnPriority int
	PriorityBy  string
	PriorityAt  time.Time
	QueueRank   int64
	RankBy      string
	RankAt      time.Time
	// HoldReason is why the placer passed the row over on its last tick
	// (rdb 0323, spec 153 3.22.8, ask_op holds); "" = waiting for room.
	HoldReason string
	Position   int    // 1 = next to place; 0 = not queued (filled by ListFleetAsks)
	QueueLen   int    // the queued asks of its role (filled with Position)
	WriterBox  string // the box that last wrote it (from the authenticated hello)
	// The OD pool's columns (rdb 0183, spec 134 3.2), set on role 'od' rows.
	LockUntil   time.Time // the lock's end on the hub clock; zero = no lease (a book ack holds until released)
	LeaseS      int       // the lease lock-next and renew grant, seconds
	Gen         int64     // +1 on every lock and release: the fence renew, done, decline and release carry
	DedupeKey   string    // one open row per (kind, dedupe_key)
	IssueKey    string    // the spec 135 card, SPL-n; "" until filed
	VendorAllow string    // "" | claude | grok
	Needs       string    // "" | box:<box> | prd
	NotBy       []string  // the harnesses that refused it: lock-next skips them
	CreatedAt   time.Time
	UpdatedAt   time.Time
	Age         time.Duration
	Quiet       time.Duration
}

// Open reports whether the ask still waits on the orchestrator (an od job:
// on a seat or a human).
func (a FleetAsk) Open() bool {
	return a.State == "open" || a.State == "acked" || a.State == "queued" || a.State == "needs_owner"
}

// AskClosedTTL is how long a closed ask stays readable before a write prunes it.
const AskClosedTTL = 7 * 24 * time.Hour

// The ask ops a holder applies to an existing row (UpdateFleetAsk).
const (
	AskAck      = "ack"      // open|acked -> acked by By (in progress)
	AskDone     = "done"     // open|acked -> done, Reason optional
	AskDecline  = "decline"  // open|acked -> declined, Reason required
	AskRaise    = "raise"    // open|acked: raised_n + 1, raised_at = now
	AskEscalate = "escalate" // open|acked: escalated_at = now (the owner was told)
	AskRelease  = "release"  // acked -> open: the acquisition lock expired; acked_by stays as the last holder
	AskDead     = "dead"     // open|acked -> dead: the delivery limit was reached, Reason required
	AskQueue    = "queue"    // open|acked|queued -> queued: a spawn request waits for room (enqueued_at set once)
	// role od only (rdb 0183, spec 134 3.3): the holder's ops carry its Gen
	AskRenew  = "renew"  // acked by By at Gen: lock_until = now + lease_s
	AskReopen = "reopen" // needs_owner -> open: a human answered
)

// AskUpdate is one op on an open ask: Op (AskAck .. AskEscalate) by the
// acting agent By (<ID>@<box>), Reason for a close.
type AskUpdate struct {
	Fleet, AskID, Op, By, Reason string
	Placement                    string // AskQueue: "<vendor>:<slug>", "" keeps the stored one
	Class, Flag, FlagMsg         string // AskQueue: "" keeps the stored one (rdb 0195)
	Gen                          int64  // role od: the holder's fence (renew, done, decline, release)
	Refuse                       string // role od release: the holder's harness joins not_by
}

// The shapes 0097's CHECKs enforce, so a refusal is a 400, not a 500.
var (
	AskIDRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	// AskPlacementRe is 0180's placement: "" or <vendor>:<slug>.
	AskPlacementRe = regexp.MustCompile(`^([a-z]{2,16}:[a-z0-9][a-z0-9._-]{0,63})?$`)
)

// The work classes of a queued spawn request (rdb 0195, SPL-1817), in the
// queue's order; the bands of the live lanes are the placer's. The rule's
// one home: csi-spl-doc/doc/md/fleet-rules-index.md.
var AskClasses = []string{"ci", "refactor", "bug", "feature"}

// ErrAskClass: a queue op that would leave the row without a class, or with
// a flag its class does not take.
var ErrAskClass = errors.New("a queued ask needs a class and a flag its class takes")

// CheckAskClass names the first thing wrong with a queue op's class, flag
// and flag_msg as sent ("" = fine; "" fields keep the stored ones).
func CheckAskClass(class, flag, msg string) string {
	switch {
	case class != "" && askClassRank(class, "") < 0:
		return "class must be ci, refactor, bug or feature"
	case flag != "" && flag != "urgent" && flag != "bypass":
		return "flag must be urgent (a bug) or bypass (a feature, the owner's ask)"
	case msg != "" && !AskIDRe.MatchString(msg):
		return "flag_msg must be the owner message id (a lowercase UUID)"
	case flag == "bypass" && msg == "":
		return "a bypass needs flag_msg, the owner message that asked for it"
	case flag != "bypass" && msg != "":
		return "flag_msg goes with flag bypass only"
	}
	return ""
}

// askClassGate checks the row a queue op would leave: a class, and a flag
// that class takes (0195's fleet_asks_flag_class_check).
func askClassGate(a FleetAsk, u AskUpdate) error {
	class, flag := a.Class, a.Flag
	if u.Class != "" {
		class = u.Class
	}
	if u.Flag != "" {
		flag = u.Flag
	}
	if class == "" || (flag == "urgent" && class != "bug") || (flag == "bypass" && class != "feature") {
		return ErrAskClass
	}
	return nil
}

// askQueueRank is a queued row's place in the class order; a row with no
// class (never classed) sorts last.
func askQueueRank(a FleetAsk) int {
	if r := askClassRank(a.Class, a.Flag); r >= 0 {
		return r
	}
	return len(AskClasses) + 1
}

// askClassRank is the queue's class order: ci, a flagged row (urgent bug,
// bypass feature), refactor, bug, feature; -1 = not a class.
func askClassRank(class, flag string) int {
	if flag != "" && class != "ci" {
		return 1
	}
	switch class {
	case "ci":
		return 0
	case "refactor":
		return 2
	case "bug":
		return 3
	case "feature":
		return 4
	}
	return -1
}

// ValidAskAgent is an ask's from / acked_by / closed_by as 0097 accepts it:
// <ID> or <ID>@<box>, the id in either grammar (spec 061, agentid).
func ValidAskAgent(s string) bool {
	id, _ := agentid.SplitAtBox(s)
	return ValidFleetAgent(id) && (!strings.Contains(s, "@") || agentid.IsAtBox(s))
}

// AskAtBox is an ask's actor keyed on its box (spec 061 3.3.1, rdb 0102):
// a bare <ID> gets "@" + box, the box that wrote it (from the authenticated
// hello), so c-004 on two machines is never one name. "" and an <ID>@<box>
// come back unchanged.
func AskAtBox(ref, box string) string {
	if ref == "" || strings.Contains(ref, "@") || !FleetNameRe.MatchString(box) {
		return ref
	}
	return ref + "@" + box
}

// Ask field limits (0097).
const AskTextMax = 500

// FleetAsks is the ask half of the store contract.
type FleetAsks interface {
	// The OD pool's job ops on role 'od' rows (spec 134, rdb 0183).
	OdJobs

	// PutFleetAsk records a new open ask, stamped created_at = now and box,
	// and prunes the fleet's closed asks older than AskClosedTTL. It is
	// idempotent on (fleet, AskID): a second put of the same id (a journal
	// replay, a retried send) changes nothing and returns the stored row with
	// created false.
	PutFleetAsk(ctx context.Context, tenantID string, a FleetAsk, box string, now time.Time) (got FleetAsk, created bool, err error)
	// UpdateFleetAsk applies u.Op by u.By to an open ask. ErrNotFound when there is no such ask; ErrConflict with
	// the CURRENT row when it is already closed (the second closer learns who
	// closed it and why); ErrAskHeld with it when another holder has the
	// lock (an ack over a live ack; an od op off the holder's gen);
	// ErrAskRole when the op does not apply to the row (askGate).
	UpdateFleetAsk(ctx context.Context, tenantID string, u AskUpdate, box string, now time.Time) (FleetAsk, error)
	// ListFleetAsks reads the fleet's open asks to role ("" = every role;
	// all = also the closed week), open first, then oldest first: the
	// longest wait leads. A queued ask carries its Position and QueueLen.
	ListFleetAsks(ctx context.Context, tenantID, fleet, role string, all bool, now time.Time) ([]FleetAsk, error)
}

// sortAsks is the list order both drivers share.
func sortAsks(as []FleetAsk) {
	sort.SliceStable(as, func(i, j int) bool {
		if as[i].Open() != as[j].Open() {
			return as[i].Open()
		}
		if !as[i].CreatedAt.Equal(as[j].CreatedAt) {
			return as[i].CreatedAt.Before(as[j].CreatedAt)
		}
		return as[i].AskID < as[j].AskID
	})
}

// The sources of an ask's effective priority (spec 153 3.22.6).
const (
	AskPrioOwn        = "own"
	AskPrioDiscussion = "discussion"
	AskPrioDefault    = "default"
)

// askPrio is the priority the queue ranks by: the effective one, the default
// (3) when the list did not fill one; a ci row ranks as priority 1, so trunk
// red never waits behind the owner's priority 1 rows (spec 153 3.22.8, H3 A,
// C121; the placer already takes a ci row first).
func askPrio(a FleetAsk) int {
	if a.Class == "ci" {
		return TopicPriorityMin
	}
	if a.Priority < TopicPriorityMin || a.Priority > TopicPriorityMax {
		return TopicPriorityDefault
	}
	return a.Priority
}

func validPrio(p int) bool { return p >= TopicPriorityMin && p <= TopicPriorityMax }

// askFillPriorities sets each ask's effective Priority and PrioritySource
// (spec 153 3.22.6): its own and its discussion's (prio: discussion -> the
// topic_priorities row) both set, the newer write wins, own on a tie; one
// set, that one; neither, the default. A rank older than the winning write
// is read as none (QueueRank 0, RankBy ""): a priority change clears the
// rank (3.22.7). Both drivers call it on a list, before askPositions.
func askFillPriorities(as []FleetAsk, prio map[string]TopicPriority) {
	for i := range as {
		a := &as[i]
		d, dok := prio[a.Discussion]
		dok = dok && a.Discussion != "" && validPrio(d.Priority)
		var at time.Time
		switch {
		case validPrio(a.OwnPriority) && (!dok || !d.SetAt.After(a.PriorityAt)):
			a.Priority, a.PrioritySource, at = a.OwnPriority, AskPrioOwn, a.PriorityAt
		case dok:
			a.Priority, a.PrioritySource, at = d.Priority, AskPrioDiscussion, d.SetAt
		default:
			a.Priority, a.PrioritySource = TopicPriorityDefault, AskPrioDefault
		}
		if a.QueueRank > 0 && a.RankAt.Before(at) {
			a.QueueRank, a.RankBy = 0, ""
		}
	}
}

// askDiscussions is the distinct discussions of the asks, the ids a list
// reads the priorities of.
func askDiscussions(as []FleetAsk) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, a := range as {
		if a.Discussion != "" && !seen[a.Discussion] {
			seen[a.Discussion] = true
			out = append(out, a.Discussion)
		}
	}
	return out
}

// askPositions numbers each role's queued asks (spec 153 3.22.7): by the
// effective priority (spec 150 row B9, owner poll Q5 answer A: a priority 1
// feature before a priority 3 bug; a ci row ranks as 1, askPrio), then the
// dragged rank (ranked rows first, lower first), then class rank (rdb 0195),
// then EnqueuedAt, then AskID: position 1 is placed next unless the placer's
// bands pick another class. An ask with neither priority ranks at
// TopicPriorityDefault (3), so with no priority and no drag the order is the
// class order. Both drivers call it on a list.
func askPositions(as []FleetAsk) {
	byRole := map[string][]int{}
	for i, a := range as {
		if a.State == "queued" {
			byRole[a.Role] = append(byRole[a.Role], i)
		}
	}
	for _, ix := range byRole {
		sort.SliceStable(ix, func(i, j int) bool { return askBefore(as[ix[i]], as[ix[j]]) })
		for n, i := range ix {
			as[i].Position, as[i].QueueLen = n+1, len(ix)
		}
	}
}

// askBefore is the queue's order of two queued asks of one role.
func askBefore(a, b FleetAsk) bool {
	if pa, pb := askPrio(a), askPrio(b); pa != pb {
		return pa < pb
	}
	if (a.QueueRank > 0) != (b.QueueRank > 0) {
		return a.QueueRank > 0
	}
	if a.QueueRank != b.QueueRank {
		return a.QueueRank < b.QueueRank
	}
	if ra, rb := askQueueRank(a), askQueueRank(b); ra != rb {
		return ra < rb
	}
	if !a.EnqueuedAt.Equal(b.EnqueuedAt) {
		return a.EnqueuedAt.Before(b.EnqueuedAt)
	}
	return a.AskID < b.AskID
}

// askTimes fills the hub-clock durations.
func askTimes(a *FleetAsk, now time.Time) {
	a.Age = now.Sub(a.CreatedAt)
	last := a.UpdatedAt
	if a.RaisedAt.After(last) {
		last = a.RaisedAt
	}
	a.Quiet = now.Sub(last)
}

// CheckFleetAsk names the first field a new ask may not carry ("" = fine):
// the client and the hub refuse the same shapes 0097's CHECKs would.
func CheckFleetAsk(a FleetAsk) string {
	switch {
	case !FleetNameRe.MatchString(a.Fleet):
		return "fleet must be a lowercase slug ([a-z0-9-], up to 32)"
	case !FleetNameRe.MatchString(a.Role):
		return "role must be the recipient role, a lowercase slug (orch, dispatch)"
	case a.Role == OdRole:
		return "role od takes its jobs through enqueue, not put"
	case !AskIDRe.MatchString(a.AskID):
		return "ask_id must be the msg_id (a lowercase UUID) of the message that raised it"
	case a.Kind != "blocker" && a.Kind != "task" && a.Kind != "escalation":
		return "kind must be blocker, task or escalation"
	case !ValidAskAgent(a.From):
		return "from must be the sender, <ID> or <ID>@<box>"
	case !LaneTopicRe.MatchString(a.Topic):
		return "topic must be a task id ([A-Za-z0-9_-], up to 64)"
	case a.Discussion != "" && !canonUUIDRe.MatchString(a.Discussion):
		return "discussion must be the owner topic id (a lowercase uuid)"
	case len(a.Summary) > AskTextMax || hasControl(a.Summary):
		return "summary must be one line of up to 500 bytes"
	}
	return ""
}

// CheckFleetAskOp names the first thing wrong with an update ("" = fine).
func CheckFleetAskOp(op, by, reason string) string {
	switch op {
	case AskAck, AskDone, AskDecline, AskRaise, AskEscalate, AskRelease, AskDead, AskQueue, AskRenew, AskReopen:
	default:
		return "ask_op must be put, list, ack, done, decline, raise, escalate, release, dead, queue, renew, reopen, enqueue, lock-next or pool"
	}
	switch {
	case !ValidAskAgent(by):
		return "by must be the acting agent, <ID> or <ID>@<box>"
	case len(reason) > AskTextMax || hasControl(reason):
		return "reason must be one line of up to 500 bytes"
	case op == AskDecline && reason == "":
		return "a decline needs a reason"
	case op == AskDead && reason == "":
		return "a dead-letter needs a reason"
	}
	return ""
}

// applyAskOp changes a (an open ask) in place; both drivers share it.
func applyAskOp(a *FleetAsk, u AskUpdate, box string, now time.Time) {
	switch u.Op {
	case AskAck:
		a.State, a.AckedBy = "acked", u.By
	case AskDone, AskDecline, AskDead:
		a.State, a.ClosedBy, a.Reason = "done", u.By, u.Reason
		if a.Role == OdRole {
			a.LockUntil = time.Time{}
		}
		if u.Op == AskDecline {
			a.State = "declined"
		} else if u.Op == AskDead {
			a.State = "dead"
		}
	case AskRaise:
		a.RaisedN++
		a.RaisedAt = now
	case AskEscalate:
		a.EscalatedAt = now
	case AskRelease:
		if a.State == "acked" {
			a.State = "open"
			if a.Role == OdRole {
				a.Gen, a.LockUntil = a.Gen+1, time.Time{}
				a.NotBy = odHarnessAdd(a.NotBy, u.Refuse)
			}
		}
	case AskRenew:
		a.LockUntil = now.Add(time.Duration(a.LeaseS) * time.Second)
	case AskReopen:
		a.State = "open"
	case AskQueue:
		a.State = "queued"
		if a.EnqueuedAt.IsZero() {
			a.EnqueuedAt = now
		}
		if u.Placement != "" {
			a.Placement = u.Placement
		}
		if u.Class != "" {
			a.Class = u.Class
		}
		if u.Flag != "" {
			a.Flag, a.FlagMsg, a.FlagBy, a.FlagAt = u.Flag, u.FlagMsg, u.By, now
		}
	}
	a.WriterBox = box
	// the tick's own ops are not the holder's activity: quiet keeps counting
	if u.Op != AskRaise && u.Op != AskEscalate && u.Op != AskRelease {
		a.UpdatedAt = now
	}
}

func (s *Memory) PutFleetAsk(_ context.Context, tenant string, a FleetAsk, box string, now time.Time) (FleetAsk, bool, error) {
	a.From = AskAtBox(a.From, box)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.asks == nil {
		s.asks = map[[3]string]FleetAsk{}
	}
	for k, r := range s.asks {
		if k[0] == tenant && k[1] == a.Fleet && !r.Open() && now.Sub(r.UpdatedAt) > AskClosedTTL {
			delete(s.asks, k)
		}
	}
	k := [3]string{tenant, a.Fleet, a.AskID}
	if cur, ok := s.asks[k]; ok {
		if cur.Discussion == "" && a.Discussion != "" {
			cur.Discussion = a.Discussion
			s.asks[k] = cur
		}
		askTimes(&cur, now)
		return cur, false, nil
	}
	a.State, a.AckedBy, a.ClosedBy, a.Reason, a.RaisedN = "open", "", "", "", 0
	a.RaisedAt, a.EscalatedAt, a.EnqueuedAt, a.Placement = time.Time{}, time.Time{}, time.Time{}, ""
	a.Class, a.Flag, a.FlagMsg, a.FlagBy, a.FlagAt = "", "", "", "", time.Time{}
	a.OwnPriority, a.PriorityBy, a.PriorityAt, a.QueueRank, a.RankBy, a.RankAt = 0, "", time.Time{}, 0, "", time.Time{}
	a.WriterBox, a.CreatedAt, a.UpdatedAt = box, now, now
	s.asks[k] = a
	askTimes(&a, now)
	return a, true, nil
}

func (s *Memory) UpdateFleetAsk(_ context.Context, tenant string, u AskUpdate, box string, now time.Time) (FleetAsk, error) {
	u.By = AskAtBox(u.By, box)
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [3]string{tenant, u.Fleet, u.AskID}
	a, ok := s.asks[k]
	if !ok {
		return FleetAsk{}, ErrNotFound
	}
	if !a.Open() {
		askTimes(&a, now)
		return a, ErrConflict
	}
	if err := askGate(a, u, now); err != nil {
		askTimes(&a, now)
		return a, err
	}
	applyAskOp(&a, u, box, now)
	s.asks[k] = a
	askTimes(&a, now)
	return a, nil
}

func (s *Memory) ListFleetAsks(_ context.Context, tenant, fleet, role string, all bool, now time.Time) ([]FleetAsk, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []FleetAsk{}
	for k, r := range s.asks {
		if k[0] == tenant && k[1] == fleet && (role == "" || r.Role == role) && (all || r.Open()) {
			askTimes(&r, now)
			out = append(out, r)
		}
	}
	s.memAskFill(tenant, out)
	sortAsks(out)
	askPositions(out)
	return out, nil
}

// memAskFill is askListPriorities on the memory store; s.mu is held.
func (s *Memory) memAskFill(tenant string, out []FleetAsk) {
	prio := map[string]TopicPriority{}
	for _, d := range askDiscussions(out) {
		if p, ok := s.topicPrio[[2]string{tenant, d}]; ok {
			prio[d] = p
		}
	}
	askFillPriorities(out, prio)
}

// The order ops of a queued spawn request (spec 153 3.22.6-3.22.7, row Q2,
// rdb 0323): an operator admin sets its own priority or drags it.

// AskRankGap is the gap between two dragged ranks; a run out of room
// renumbers that priority's ranks in the same transaction.
const AskRankGap = 1024

var (
	// ErrAskNotQueued: the ask exists but is no longer queued (placed, closed).
	ErrAskNotQueued = errors.New("ask not queued")
	// ErrStalePosition: a move's neighbours are no longer adjacent, or no
	// longer queued; nothing changed.
	ErrStalePosition = errors.New("stale position")
	// ErrAskCIFirst: a ci row was dragged to a slot of a priority other than
	// the ci rows' (askPrio: a ci row is always priority 1), where it cannot
	// stand; nothing changed.
	ErrAskCIFirst = errors.New("a ci row cannot leave the ci rows' priority")
)

// AskPrioritySet sets a queued ask's own priority (1..5) by By.
type AskPrioritySet struct {
	Fleet, AskID, By string
	Priority         int
}

// AskMove drops a queued ask between two neighbours as the page saw them:
// Before is the ask it now follows (directly above it), After the ask it now
// precedes (directly below it); "" = the top or the bottom of the line.
type AskMove struct {
	Fleet, AskID, Before, After, By string
}

// FleetAskOrder is the order half of the ask store; Memory and Postgres
// implement it. Both answer the moved or set row as a list reads it, with its
// Position. ErrNotFound: no such ask; ErrAskNotQueued: not queued.
type FleetAskOrder interface {
	// SetFleetAskPriority writes the ask's own priority, who and when, and
	// clears its rank (a new decision: it joins its new priority by class).
	SetFleetAskPriority(ctx context.Context, tenantID string, p AskPrioritySet, now time.Time) (FleetAsk, error)
	// MoveFleetAsk applies a drag in one transaction over the role's queued
	// rows, locked (askPlanMove); ErrStalePosition changes nothing.
	MoveFleetAsk(ctx context.Context, tenantID string, m AskMove, now time.Time) (FleetAsk, error)
}

// askSetPriority is the priority write both drivers share.
func askSetPriority(a *FleetAsk, p AskPrioritySet, now time.Time) {
	a.OwnPriority, a.PriorityBy, a.PriorityAt = p.Priority, p.By, now
	a.QueueRank, a.RankBy, a.RankAt = 0, "", time.Time{}
}

// askPlanMove answers the rows a move writes (spec 153 3.22.7). queue is the
// moved ask's role's queued rows in queue order, as a list fills them. The
// moved row takes the priority of the row it now sits directly above (of
// the row above it when it lands last) as its own, by m.By; it gets a rank
// between its neighbours, and every unranked row of that priority above it
// gets one in its current order with no RankBy. A row whose rank changes
// keeps its RankBy, except the moved row, which gets m.By.
// ErrAskNotQueued: the moved row is not in queue (it left the queue before
// the lock); ErrAskCIFirst: a ci row dropped at another priority's slot.
func askPlanMove(queue []FleetAsk, m AskMove, now time.Time) ([]FleetAsk, error) {
	var moved FleetAsk
	found := false
	rest := make([]FleetAsk, 0, len(queue))
	for _, a := range queue {
		if a.AskID == m.AskID {
			moved, found = a, true
		} else {
			rest = append(rest, a)
		}
	}
	if !found {
		return nil, ErrAskNotQueued
	}
	at, err := askMoveSlot(rest, m)
	if err != nil {
		return nil, err
	}
	p := askPrio(moved)
	if at < len(rest) {
		p = askPrio(rest[at])
	} else if at > 0 {
		p = askPrio(rest[at-1])
	}
	moved.OwnPriority, moved.PriorityBy, moved.PriorityAt = p, m.By, now
	moved.Priority, moved.PrioritySource = p, AskPrioOwn
	moved.QueueRank = 0
	if askPrio(moved) != p {
		return nil, ErrAskCIFirst
	}
	line := append(append(append([]FleetAsk{}, rest[:at]...), moved), rest[at:]...)
	block, k := []FleetAsk{}, 0
	for _, a := range line {
		if askPrio(a) != p {
			continue
		}
		if a.AskID == m.AskID {
			k = len(block)
		}
		block = append(block, a)
	}
	return askRankBlock(block, k, m.By, now), nil
}

// askMoveSlot is where the moved row goes in rest (the line without it):
// its index, after checking Before and After are adjacent there.
func askMoveSlot(rest []FleetAsk, m AskMove) (int, error) {
	idx := func(id string) int {
		for i, a := range rest {
			if a.AskID == id {
				return i
			}
		}
		return -2
	}
	bi, ai := -1, len(rest)
	if m.Before != "" {
		bi = idx(m.Before)
	}
	if m.After != "" {
		ai = idx(m.After)
	}
	if bi == -2 || ai == -2 || ai != bi+1 {
		return 0, ErrStalePosition
	}
	return ai, nil
}

// askRankBlock ranks block (one priority's rows in their new order, the
// moved row at k) so that rows 0..k and every ranked row below k are ranked
// in strictly increasing order: kept ranks stay, the gaps between them are
// filled; a gap with no room renumbers the whole run by AskRankGap. It
// answers the rows whose rank changed, the moved row always.
func askRankBlock(block []FleetAsk, k int, by string, now time.Time) []FleetAsk {
	last := k
	for i := k + 1; i < len(block); i++ {
		if block[i].QueueRank > 0 {
			last = i
		}
	}
	ranks := make([]int64, last+1)
	for i := range ranks {
		if i != k && block[i].QueueRank > 0 {
			ranks[i] = block[i].QueueRank
		}
	}
	if !askFillGaps(ranks) {
		for i := range ranks {
			ranks[i] = int64(i+1) * AskRankGap
		}
	}
	out := []FleetAsk{}
	for i, r := range ranks {
		a := block[i]
		if i != k && a.QueueRank == r {
			continue
		}
		if a.QueueRank == 0 {
			a.RankBy = ""
		}
		if i == k {
			a.RankBy = by
		}
		a.QueueRank, a.RankAt = r, now
		out = append(out, a)
	}
	return out
}

// askFillGaps fills the zeros of ranks between the kept values, strictly
// increasing; false = a kept value out of order or a gap without room.
func askFillGaps(ranks []int64) bool {
	lo, i := int64(0), 0
	for i < len(ranks) {
		if ranks[i] > 0 {
			if ranks[i] <= lo {
				return false
			}
			lo, i = ranks[i], i+1
			continue
		}
		j := i
		for j < len(ranks) && ranks[j] == 0 {
			j++
		}
		n := int64(j - i)
		step := int64(AskRankGap)
		if j < len(ranks) {
			step = (ranks[j] - lo) / (n + 1)
		}
		if step < 1 {
			return false
		}
		for x := i; x < j; x++ {
			lo += step
			ranks[x] = lo
		}
		i = j
	}
	return true
}

// askRoleQueue is the role's queued rows of a filled, ordered list.
func askRoleQueue(as []FleetAsk, role string) []FleetAsk {
	out := []FleetAsk{}
	for _, a := range as {
		if a.State == "queued" && a.Role == role {
			out = append(out, a)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Position < out[j].Position })
	return out
}

// SetFleetAskPriority implements FleetAskOrder on the Memory store.
func (s *Memory) SetFleetAskPriority(ctx context.Context, tenant string, p AskPrioritySet, now time.Time) (FleetAsk, error) {
	s.mu.Lock()
	k := [3]string{tenant, p.Fleet, p.AskID}
	a, ok := s.asks[k]
	switch {
	case !ok:
		s.mu.Unlock()
		return FleetAsk{}, ErrNotFound
	case a.State != "queued":
		s.mu.Unlock()
		return a, ErrAskNotQueued
	}
	askSetPriority(&a, p, now)
	s.asks[k] = a
	s.mu.Unlock()
	return s.memListed(ctx, tenant, a, now)
}

// MoveFleetAsk implements FleetAskOrder on the Memory store.
func (s *Memory) MoveFleetAsk(ctx context.Context, tenant string, m AskMove, now time.Time) (FleetAsk, error) {
	s.mu.Lock()
	k := [3]string{tenant, m.Fleet, m.AskID}
	a, ok := s.asks[k]
	if !ok || a.State != "queued" {
		s.mu.Unlock()
		if !ok {
			return FleetAsk{}, ErrNotFound
		}
		return a, ErrAskNotQueued
	}
	queue := []FleetAsk{}
	for kk, r := range s.asks {
		if kk[0] == tenant && kk[1] == m.Fleet && r.Role == a.Role && r.State == "queued" {
			queue = append(queue, r)
		}
	}
	s.memAskFill(tenant, queue)
	askPositions(queue)
	writes, err := askPlanMove(askRoleQueue(queue, a.Role), m, now)
	if err != nil {
		s.mu.Unlock()
		return a, err
	}
	for _, w := range writes {
		kk := [3]string{tenant, m.Fleet, w.AskID}
		r := s.asks[kk]
		r.OwnPriority, r.PriorityBy, r.PriorityAt = w.OwnPriority, w.PriorityBy, w.PriorityAt
		r.QueueRank, r.RankBy, r.RankAt = w.QueueRank, w.RankBy, w.RankAt
		s.asks[kk] = r
	}
	s.mu.Unlock()
	return s.memListed(ctx, tenant, a, now)
}

// memListed answers a as its role's list reads it now.
func (s *Memory) memListed(ctx context.Context, tenant string, a FleetAsk, now time.Time) (FleetAsk, error) {
	as, err := s.ListFleetAsks(ctx, tenant, a.Fleet, a.Role, false, now)
	return askFind(as, a, err)
}

// askFind is a's row in a list (its Position, its effective priority); a
// itself when the list failed or no longer holds it.
func askFind(as []FleetAsk, a FleetAsk, err error) (FleetAsk, error) {
	for _, r := range as {
		if r.AskID == a.AskID {
			return r, err
		}
	}
	return a, err
}
