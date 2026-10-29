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
	Discussion  string // the owner topic (a uuid) it works for, "" = none known (rdb 0241, set once by the hub at put)
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
	Priority    int       // its Discussion's priority 1..5, TopicPriorityDefault without one (filled by ListFleetAsks)
	Position    int       // 1 = next to place; 0 = not queued (filled by ListFleetAsks)
	QueueLen    int       // the queued asks of its role (filled with Position)
	WriterBox   string    // the box that last wrote it (from the authenticated hello)
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

// askPrio is the priority the queue ranks by: the discussion's, the default
// (5) when the list did not fill one.
func askPrio(a FleetAsk) int {
	if a.Priority < TopicPriorityMin || a.Priority > TopicPriorityMax {
		return TopicPriorityDefault
	}
	return a.Priority
}

// askFillPriorities sets each ask's Priority from its discussion's (prio:
// discussion -> priority, as TopicPriorities answers), the default without
// one. Both drivers call it on a list, before askPositions.
func askFillPriorities(as []FleetAsk, prio map[string]int) {
	for i := range as {
		as[i].Priority = TopicPriorityDefault
		if p, ok := prio[as[i].Discussion]; ok && as[i].Discussion != "" {
			as[i].Priority = p
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

// askPositions numbers each role's queued asks by their discussion's
// priority (spec 150 row B9, owner poll Q5 answer A: a priority 1 feature
// before a priority 3 bug), then class rank (rdb 0195), then EnqueuedAt, then
// AskID: position 1 is placed next unless the placer's bands pick another
// class. An ask with no discussion ranks at 5, so with no priority set the
// order is the class order. Both drivers call it on a list.
func askPositions(as []FleetAsk) {
	byRole := map[string][]int{}
	for i, a := range as {
		if a.State == "queued" {
			byRole[a.Role] = append(byRole[a.Role], i)
		}
	}
	for _, ix := range byRole {
		sort.SliceStable(ix, func(i, j int) bool {
			a, b := as[ix[i]], as[ix[j]]
			if pa, pb := askPrio(a), askPrio(b); pa != pb {
				return pa < pb
			}
			if ra, rb := askQueueRank(a), askQueueRank(b); ra != rb {
				return ra < rb
			}
			if !a.EnqueuedAt.Equal(b.EnqueuedAt) {
				return a.EnqueuedAt.Before(b.EnqueuedAt)
			}
			return a.AskID < b.AskID
		})
		for n, i := range ix {
			as[i].Position, as[i].QueueLen = n+1, len(ix)
		}
	}
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
		askTimes(&cur, now)
		return cur, false, nil
	}
	a.State, a.AckedBy, a.ClosedBy, a.Reason, a.RaisedN = "open", "", "", "", 0
	a.RaisedAt, a.EscalatedAt, a.EnqueuedAt, a.Placement = time.Time{}, time.Time{}, time.Time{}, ""
	a.Class, a.Flag, a.FlagMsg, a.FlagBy, a.FlagAt = "", "", "", "", time.Time{}
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
	prio := map[string]int{}
	for _, d := range askDiscussions(out) {
		if p, ok := s.topicPrio[[2]string{tenant, d}]; ok {
			prio[d] = p.Priority
		}
	}
	askFillPriorities(out, prio)
	sortAsks(out)
	askPositions(out)
	return out, nil
}
