package store

import (
	"context"
	"errors"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
)

// The OD pool's job rows (spec 134 v1.0 sections 3.1-3.4, rdb 0183): every
// orchestrator / dispatcher job is ONE fleet_asks row with role 'od', and any
// able seat locks one atomically, works it and closes it. Context is the row's
// pointers (topic, issue_key, the source msg), never a copy.
//
//	enqueue   - insert a job (idempotent on ask_id; a second OPEN job with the
//	            same (kind, dedupe_key) is ErrAskDuplicate with the open one)
//	lock-next - the hub picks the oldest lockable row and locks it in one
//	            statement: open, or acked with lock_until passed (lazy expiry,
//	            no tick); gen + 1, lock_until = now + lease_s. The 4th lost
//	            lock dead-letters the row instead
//	renew     - the holder at its gen moves lock_until
//	done | decline | release - the holder at its gen (decline of an open or
//	            needs_owner row: anyone, the human or admin answer)
//	release of a seat - every row the seat holds goes back to open, gen + 1
//	            (the supervisor's kill, 4.2)
//
// Only role 'od' rows take these, and they take no book op (ack, raise,
// escalate, queue, dead): the two lock regimes never mix (3.1).

// OdRole is the pool's role in fleet_asks.
const OdRole = "od"

// OdKinds are the pool's job kinds (3.2), in the P6 cut-over order.
var OdKinds = []string{"lane_verify", "spawn", "route_post", "box_op"}

// The pool's limits: a lock's lease in seconds (default, min, max), the
// locks a row may lose, the harnesses a row may exclude and the length of
// its dedupe key.
const (
	OdLeaseDefault = 120 // seconds, owner question Q2 (B); cnf may set lease_s per kind
	OdLeaseMin     = 15
	OdLeaseMax     = 86400
	OdMaxLocks     = 4 // the 4th lock lost by expiry dead-letters the row (3.3)
	OdNotByMax     = 16
	OdDedupeMax    = 200
)

var (
	// ErrAskHeld: the op needs the lock, and the caller does not hold it at
	// that gen (another seat locked it, or it was released or expired and
	// re-locked). The current row comes back with it.
	ErrAskHeld = errors.New("ask held by another holder")
	// ErrAskRole: the op does not apply to this row's role or state (a book
	// op on an od job, an od op on a book ask, reopen of a row that does not
	// wait on the owner).
	ErrAskRole = errors.New("ask op does not apply to this row")
	// ErrAskDuplicate: an open job of the same kind and dedupe_key exists;
	// the open one comes back with it.
	ErrAskDuplicate = errors.New("ask duplicate")
)

// The shapes an ask's issue key, needs and vendor (or harness) must have.
var (
	IssueKeyRe = regexp.MustCompile(`^([A-Z][A-Z0-9]{1,9}-[0-9]{1,9})?$`)
	OdNeedsRe  = regexp.MustCompile(`^(box:[a-z0-9][a-z0-9-]{0,31}|prd)?$`)
	OdVendorRe = regexp.MustCompile(`^[a-z]{2,16}$`)
)

// OdLock is one lock-next call: the seat (<ID>@<box>), its vendor (claude |
// grok), its harness (the not_by name, default the vendor) and its caps (prd;
// the hub adds box:<the session's box>).
type OdLock struct {
	Fleet, Seat, Vendor, Harness string
	Caps                         []string
}

// OdPool is the pool's one row per tenant and fleet (rdb 0183 od_pool).
type OdPool struct {
	Fleet     string
	ClaudeN   int
	GrokN     int
	MinBoxes  int
	VendorOut string // "" | claude | grok
	OutUntil  time.Time
	Kinds     []string // the job kinds the seats lock; empty = none
	UpdatedBy string
	WriterBox string
	UpdatedAt time.Time
}

// DefaultOdPool is the row a fleet reads before anyone wrote one: 2 + 2 seats
// on 2 boxes, no kind consumed.
func DefaultOdPool(fleet string) OdPool {
	return OdPool{Fleet: fleet, ClaudeN: 2, GrokN: 2, MinBoxes: 2, Kinds: []string{}}
}

// OdJobs is the pool half of the asks contract.
type OdJobs interface {
	// EnqueueOdJob records a new od job (role od), open or, with needsOwner,
	// needs_owner. Idempotent on (fleet, AskID) like PutFleetAsk;
	// ErrAskDuplicate with the open row when its (kind, dedupe_key) is taken.
	EnqueueOdJob(ctx context.Context, tenantID string, a FleetAsk, needsOwner bool, box string, now time.Time) (got FleetAsk, created bool, err error)
	// LockNextOdJob locks the oldest lockable job of the pool's kinds for
	// q.Seat; ok false when there is none. dead lists the rows it
	// dead-lettered on the way (their 4th lost lock).
	LockNextOdJob(ctx context.Context, tenantID string, q OdLock, box string, now time.Time) (got FleetAsk, ok bool, dead []FleetAsk, err error)
	// ReleaseOdSeat frees every job seat holds (gen + 1): the kill path.
	ReleaseOdSeat(ctx context.Context, tenantID, fleet, seat, box string, now time.Time) ([]FleetAsk, error)
	GetOdPool(ctx context.Context, tenantID, fleet string) (OdPool, error)
	PutOdPool(ctx context.Context, tenantID string, p OdPool, by, box string, now time.Time) (OdPool, error)
}

func validLease(s int) bool { return s >= OdLeaseMin && s <= OdLeaseMax }

// CheckOdJob names the first field a new od job may not carry ("" = fine).
func CheckOdJob(a FleetAsk) string {
	switch {
	case !FleetNameRe.MatchString(a.Fleet):
		return "fleet must be a lowercase slug ([a-z0-9-], up to 32)"
	case !AskIDRe.MatchString(a.AskID):
		return "ask_id must be a lowercase UUID (the msg_id that carried the job)"
	case !slices.Contains(OdKinds, a.Kind):
		return "kind must be route_post, spawn, lane_verify or box_op"
	case !ValidAskAgent(a.From):
		return "from must be the sender, <ID> or <ID>@<box>"
	case !LaneTopicRe.MatchString(a.Topic):
		return "topic must be a task id ([A-Za-z0-9_-], up to 64)"
	case len(a.Summary) > AskTextMax || hasControl(a.Summary):
		return "summary must be one line of up to 500 bytes"
	case !IssueKeyRe.MatchString(a.IssueKey):
		return "issue_key must be an issue key (SPL-n) or empty"
	case len(a.DedupeKey) > OdDedupeMax || hasControl(a.DedupeKey):
		return "dedupe_key must be one line of up to 200 bytes"
	case a.VendorAllow != "" && a.VendorAllow != "claude" && a.VendorAllow != "grok":
		return "vendor_allow must be empty, claude or grok"
	case !OdNeedsRe.MatchString(a.Needs):
		return "needs must be empty, box:<box> or prd"
	case a.LeaseS != 0 && !validLease(a.LeaseS):
		return "lease_s must be 15..86400 (0 = the default 120)"
	}
	return ""
}

// CheckOdLock names the first thing wrong with a lock-next call ("" = fine).
func CheckOdLock(q OdLock) string {
	switch {
	case !FleetNameRe.MatchString(q.Fleet):
		return "fleet must be a lowercase slug ([a-z0-9-], up to 32)"
	case !ValidAskAgent(q.Seat):
		return "seat must be the locking agent, <ID>@<box>"
	case !OdVendorRe.MatchString(q.Vendor):
		return "vendor must be the seat's vendor (claude, grok)"
	case q.Harness != "" && !OdVendorRe.MatchString(q.Harness):
		return "harness must be a lowercase name (claude, grok, vibe)"
	}
	for _, c := range q.Caps {
		if c != "prd" {
			return "caps may hold prd only (the hub adds the seat's box)"
		}
	}
	return ""
}

// CheckOdPool names the first thing wrong with a pool row ("" = fine).
func CheckOdPool(p OdPool) string {
	switch {
	case !FleetNameRe.MatchString(p.Fleet):
		return "fleet must be a lowercase slug ([a-z0-9-], up to 32)"
	case p.ClaudeN < 0 || p.ClaudeN > 16 || p.GrokN < 0 || p.GrokN > 16:
		return "claude_n and grok_n must be 0..16"
	case p.MinBoxes < 1 || p.MinBoxes > 16:
		return "min_boxes must be 1..16"
	case p.VendorOut != "" && p.VendorOut != "claude" && p.VendorOut != "grok":
		return "vendor_out must be empty, claude or grok"
	}
	seen := map[string]bool{}
	for _, k := range p.Kinds {
		if !slices.Contains(OdKinds, k) || seen[k] {
			return "kinds must be distinct od kinds (lane_verify, spawn, route_post, box_op)"
		}
		seen[k] = true
	}
	return ""
}

// askGate decides whether u may apply to a (an open row) before applyAskOp
// runs; both drivers share it. It is the compare-and-set the book's ack
// lacked (spec 134 3.3) and the gen fence of the od ops.
func askGate(a FleetAsk, u AskUpdate, now time.Time) error {
	if a.Role != OdRole {
		switch u.Op {
		case AskRenew, AskReopen:
			return ErrAskRole
		case AskAck:
			// another holder's live lock: a book ack holds until the tick
			// releases it (no lock_until), an od lock until lock_until
			if a.State == "acked" && a.AckedBy != u.By && (a.LockUntil.IsZero() || a.LockUntil.After(now)) {
				return ErrAskHeld
			}
		}
		return nil
	}
	switch u.Op {
	case AskReopen:
		if a.State != "needs_owner" {
			return ErrAskRole
		}
		return nil
	case AskDecline:
		if a.State == "open" || a.State == "needs_owner" {
			return nil
		}
	case AskDone, AskRenew, AskRelease:
	default:
		return ErrAskRole
	}
	if a.State != "acked" || a.AckedBy != u.By || a.Gen != u.Gen {
		return ErrAskHeld
	}
	return nil
}

// odLockable reports whether lock-next may take a for q.
func odLockable(a FleetAsk, kinds []string, q OdLock, caps []string, now time.Time) bool {
	if a.Role != OdRole || !slices.Contains(kinds, a.Kind) {
		return false
	}
	if a.State != "open" && (a.State != "acked" || !odExpired(a, now)) {
		return false
	}
	return (a.VendorAllow == "" || a.VendorAllow == q.Vendor) && !slices.Contains(a.NotBy, q.Harness) &&
		(a.Needs == "" || slices.Contains(caps, a.Needs))
}

// odExpired: a held lock whose lease passed (lock_until < now). A lock with
// no lease never expires lazily (a book row's).
func odExpired(a FleetAsk, now time.Time) bool {
	return a.State == "acked" && !a.LockUntil.IsZero() && a.LockUntil.Before(now)
}

// OdFree reports whether a seat could lock a now, whatever its caps: the
// `list --free` filter.
func OdFree(a FleetAsk, now time.Time) bool {
	return a.Role == OdRole && (a.State == "open" || odExpired(a, now))
}

// odCaps is q's caps plus the session's box.
func odCaps(q OdLock, box string) []string {
	return append(append([]string{}, q.Caps...), "box:"+box)
}

func odLockNorm(q *OdLock, box string) {
	q.Seat = AskAtBox(q.Seat, box)
	if q.Harness == "" {
		q.Harness = q.Vendor
	}
}

// odDeadReason is the reason a 4th lost lock leaves on the row.
const odDeadReason = "lock lost 4 times (holders went silent); a pool seat is told"

func (s *Memory) EnqueueOdJob(_ context.Context, tenant string, a FleetAsk, needsOwner bool, box string, now time.Time) (FleetAsk, bool, error) {
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
	if a.DedupeKey != "" {
		for kk, r := range s.asks {
			if kk[0] == tenant && kk[1] == a.Fleet && r.Kind == a.Kind && r.DedupeKey == a.DedupeKey &&
				(r.State == "open" || r.State == "acked" || r.State == "needs_owner") {
				askTimes(&r, now)
				return r, false, ErrAskDuplicate
			}
		}
	}
	a = newOdJob(a, needsOwner, box, now)
	s.asks[k] = a
	askTimes(&a, now)
	return a, true, nil
}

// newOdJob is a fresh od row as both drivers store it.
func newOdJob(a FleetAsk, needsOwner bool, box string, now time.Time) FleetAsk {
	a.Role, a.State = OdRole, "open"
	if needsOwner {
		a.State = "needs_owner"
	}
	if a.LeaseS == 0 {
		a.LeaseS = OdLeaseDefault
	}
	a.AckedBy, a.ClosedBy, a.Reason, a.RaisedN, a.Gen = "", "", "", 0, 0
	a.RaisedAt, a.EscalatedAt, a.EnqueuedAt, a.LockUntil, a.Placement = time.Time{}, time.Time{}, time.Time{}, time.Time{}, ""
	a.NotBy = []string{}
	a.WriterBox, a.CreatedAt, a.UpdatedAt = box, now, now
	return a
}

// odLock locks a for q (both drivers' lock-next, the Go half of 3.3's SQL).
func odLock(a *FleetAsk, q OdLock, box string, now time.Time) {
	if a.State == "acked" {
		a.RaisedN++
	}
	a.State, a.AckedBy, a.Gen = "acked", q.Seat, a.Gen+1
	a.LockUntil = now.Add(time.Duration(a.LeaseS) * time.Second)
	a.WriterBox, a.UpdatedAt = box, now
}

// odDead dead-letters an expired row on its 4th lost lock.
func odDead(a *FleetAsk, box string, now time.Time) {
	a.RaisedN++
	a.State, a.ClosedBy, a.Reason, a.LockUntil = "dead", "", odDeadReason, time.Time{}
	a.WriterBox, a.UpdatedAt = box, now
}

func (s *Memory) LockNextOdJob(_ context.Context, tenant string, q OdLock, box string, now time.Time) (FleetAsk, bool, []FleetAsk, error) {
	odLockNorm(&q, box)
	caps := odCaps(q, box)
	s.mu.Lock()
	defer s.mu.Unlock()
	kinds := DefaultOdPool(q.Fleet).Kinds
	if p, ok := s.odPools[[2]string{tenant, q.Fleet}]; ok {
		kinds = p.Kinds
	}
	dead := []FleetAsk{}
	var cand [][3]string
	for k, a := range s.asks {
		if k[0] != tenant || k[1] != q.Fleet || a.Role != OdRole || !slices.Contains(kinds, a.Kind) {
			continue
		}
		if odExpired(a, now) && a.RaisedN >= OdMaxLocks-1 {
			odDead(&a, box, now)
			s.asks[k] = a
			askTimes(&a, now)
			dead = append(dead, a)
			continue
		}
		if odLockable(a, kinds, q, caps, now) {
			cand = append(cand, k)
		}
	}
	if len(cand) == 0 {
		return FleetAsk{}, false, dead, nil
	}
	sort.Slice(cand, func(i, j int) bool {
		a, b := s.asks[cand[i]], s.asks[cand[j]]
		if !a.CreatedAt.Equal(b.CreatedAt) {
			return a.CreatedAt.Before(b.CreatedAt)
		}
		return a.AskID < b.AskID
	})
	a := s.asks[cand[0]]
	odLock(&a, q, box, now)
	s.asks[cand[0]] = a
	askTimes(&a, now)
	return a, true, dead, nil
}

func (s *Memory) ReleaseOdSeat(_ context.Context, tenant, fleet, seat, box string, now time.Time) ([]FleetAsk, error) {
	seat = AskAtBox(seat, box)
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []FleetAsk{}
	for k, a := range s.asks {
		if k[0] == tenant && k[1] == fleet && a.Role == OdRole && a.State == "acked" && a.AckedBy == seat {
			applyAskOp(&a, AskUpdate{Fleet: fleet, AskID: a.AskID, Op: AskRelease, By: seat, Gen: a.Gen}, box, now)
			s.asks[k] = a
			askTimes(&a, now)
			out = append(out, a)
		}
	}
	sortAsks(out)
	return out, nil
}

func (s *Memory) GetOdPool(_ context.Context, tenant, fleet string) (OdPool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if p, ok := s.odPools[[2]string{tenant, fleet}]; ok {
		p.Kinds = append([]string{}, p.Kinds...)
		return p, nil
	}
	return DefaultOdPool(fleet), nil
}

func (s *Memory) PutOdPool(_ context.Context, tenant string, p OdPool, by, box string, now time.Time) (OdPool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.odPools == nil {
		s.odPools = map[[2]string]OdPool{}
	}
	p.Kinds = append([]string{}, p.Kinds...)
	p.UpdatedBy, p.WriterBox, p.UpdatedAt = AskAtBox(by, box), box, now
	if !p.OutUntil.IsZero() {
		p.OutUntil = p.OutUntil.UTC()
	}
	s.odPools[[2]string{tenant, p.Fleet}] = p
	return p, nil
}

// odHarnessAdd appends h to notBy once.
func odHarnessAdd(notBy []string, h string) []string {
	h = strings.TrimSpace(h)
	if h == "" || slices.Contains(notBy, h) || len(notBy) >= OdNotByMax {
		return notBy
	}
	return append(append([]string{}, notBy...), h)
}
