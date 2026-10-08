package store

import (
	"context"
	"errors"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// The peer claim on a message (spec 068 4.1, rdb 0110, lane L1). Four peer
// seats per box (<letter>-001..004, always <id>@<box>) share one pool of
// messages: every 5 s each seat's poll loop locks unclaimed messages for
// itself in ONE statement, renews what it holds, and closes a message when it
// has dealt with it. The lock lives on the message row:
//
//	Responsible     the seat that must deal with it (<id>@<box>)
//	LockedUntil     the lock, on the hub clock; past it any peer may take it
//	ResponsibleGen  +1 per claim: the fence an outward action re-checks (4.2)
//	ClaimN          +1 per claim: the delivery count (dead at ClaimMax)
//	HandledAt/How   the close: answered | handed:<lane> | no-reply:<reason> | dead
//	NotBy           the harnesses that refused it (F6): their polls skip it
//	NeedsPeer       a message the peers pick up (claimDefaults)
//
// Two polls in the same millisecond take disjoint messages (Postgres: FOR
// UPDATE SKIP LOCKED; Memory: its one mutex), so a message has exactly one
// responsible seat at a time.

// PeersID is the to_id of a message to the peers (spec 068 4.1: a report to
// "the orchestrator" reaches the hub as to_id 'peers'); msg.PeersID.
const PeersID = msg.PeersID

// The claim knobs the hub enforces (spec 068 section 7).
const (
	ClaimMax        = 4                 // CLAIM_MAX: claims without a close before the message goes dead
	ClaimTTLDefault = 120 * time.Second // LOCK_TTL
	ClaimTTLMin     = 10 * time.Second
	ClaimTTLMax     = 10 * time.Minute
	ClaimPollMax    = 50 // the most one poll takes (the loop asks PEER_MAX_HELD minus what it holds)
	ClaimTextMax    = 500
)

// ErrNotPeerMessage: a release of a message no peer polls (one to a single
// agent): released, nobody would ever take it again.
var ErrNotPeerMessage = errors.New("the message is not a peer message")

var (
	odSeatRe     = regexp.MustCompile(`^[acgmq]-00[1-4]$`)
	handledHowRe = regexp.MustCompile(`^(answered|handed:.+|no-reply:.+)$`)
)

// ClaimPoll is one poll: lock at most Max messages for Seat (<id>@<box>) for
// TTL, skipping what Harness refused.
type ClaimPoll struct {
	Seat, Harness string
	Max           int
	TTL           time.Duration
}

// ClaimClose is a release (Reason) or a close (How) of MsgID by Seat. Gen > 0
// is a compare-and-set on ResponsibleGen (4.2: `--done handed:<lane>`).
type ClaimClose struct {
	MsgID, Seat, Harness string
	How, Reason          string
	Gen                  int64
}

// MessageClaims is the claim half of the store contract. A refused release
// or close returns ErrConflict and the CURRENT row, so the caller names the
// responsible seat, the close it already had, or the gen it moved to.
type MessageClaims interface {
	// PollMessageClaims first closes `dead` every free peer message already
	// claimed ClaimMax times (returned once, as dead: the caller tells the
	// owner), then locks up to p.Max free peer messages for p.Seat, oldest
	// first. Free = unhandled and nobody's lock is live.
	PollMessageClaims(ctx context.Context, tenant string, p ClaimPoll, now time.Time) (claimed, dead []Message, err error)
	// RenewMessageClaims extends the lock of every open peer message seat
	// holds to now + ttl, and returns them. A lock with more than ttl/2 left
	// is not rewritten (a write per renew would bump the view stamp, 0103).
	RenewMessageClaims(ctx context.Context, tenant, seat string, ttl time.Duration, now time.Time) ([]Message, error)
	// ReleaseMessageClaim gives a held peer message back at once. A reason
	// harness-refused:<step> adds c.Harness to NotBy.
	ReleaseMessageClaim(ctx context.Context, tenant string, c ClaimClose, now time.Time) (Message, error)
	// CloseMessageClaim records c.How. Only the responsible seat may close.
	CloseMessageClaim(ctx context.Context, tenant string, c ClaimClose, now time.Time) (Message, error)
	// GetMessageClaim reads one message's claim, no lock taken (the fence
	// check of 4.2). ErrNotFound when there is no such message.
	GetMessageClaim(ctx context.Context, tenant, msgID string) (Message, error)
	// AdoptMessageClaim is insert-if-absent (spec 068 section 7, hub down: a
	// seat's local lock pushed back to the hub). A free peer message becomes
	// c.Seat's exactly as a claim makes it (lock, fence +1, claim_n +1) and
	// adopted is true; one another seat holds, or closed, comes back
	// unchanged with adopted false. ErrNotPeerMessage for a one-agent message.
	AdoptMessageClaim(ctx context.Context, tenant string, c ClaimClose, ttl time.Duration, now time.Time) (m Message, adopted bool, err error)
	// MessageRounds is spec 093's two-phase claim on the same rows; a
	// release (T8) and a close (T9) stay ReleaseMessageClaim and
	// CloseMessageClaim.
	MessageRounds
}

// ClaimHeld reports whether seat still holds m at fence gen on the hub clock:
// responsible, the same generation, open, and its lock (if any) not run out.
func ClaimHeld(m Message, seat string, gen int64, now time.Time) bool {
	return m.HandledAt.IsZero() && m.Responsible == seat && m.ResponsibleGen == gen &&
		(m.LockedUntil.IsZero() || !m.LockedUntil.Before(now))
}

// applyClaim makes m seat's for ttl; both drivers' poll and adopt share it.
// It is 068's one-step claim: the row is owned at once (spec 093 4.1).
func applyClaim(m *Message, seat string, ttl time.Duration, now time.Time) {
	m.Responsible, m.LockedUntil = seat, now.Add(ttl)
	m.ResponsibleGen++
	m.ClaimN++
	m.Round.State, m.Round.AcceptedAt, m.Round.TouchedAt = ClaimOwned, now, now
}

// claimDefaults resets m's claim fields to what an insert stores; the 0110
// trigger is its Postgres twin. seated: the tenant's roster holds a peer seat.
func claimDefaults(m *Message, seated bool) {
	m.Responsible, m.LockedUntil, m.ResponsibleGen, m.ClaimN = "", time.Time{}, 0, 0
	m.HandledAt, m.HandledHow, m.NotBy, m.NeedsPeer = time.Time{}, "", nil, false
	m.Round = ClaimRound{State: ClaimFree}
	m.Responsible = InsertResponsible(m.ToID, m.ToBox)
	switch {
	case m.ToID == PeersID:
		m.NeedsPeer = true
	case m.Responsible == "" && m.FromBox == "box-wui" && strings.HasPrefix(m.FromID, "HUM-") && m.ToID == "ALL-0" && seated:
		m.NeedsPeer = true
	}
}

// InsertResponsible is the responsible seat an insert stores (the 0110
// trigger's first branch): <to_id>@<to_box> for a message to one agent, ""
// otherwise. The hub's live WUI frame reads it too, so the echo shows the
// seat the row was stored with.
func InsertResponsible(toID, toBox string) string {
	if agentid.IsAgent(toID) {
		return toID + "@" + toBox
	}
	return ""
}

// IsPeerSeat reports whether id (bare or <id>@<box>) is a peer seat number.
func IsPeerSeat(id string) bool {
	id, _ = agentid.SplitAtBox(id)
	return odSeatRe.MatchString(id)
}

// CheckClaimSeat names what is wrong with a seat ("" = fine): an agent id at
// a box, <id>@<box>.
func CheckClaimSeat(seat string) string {
	id, _ := agentid.SplitAtBox(seat)
	if !agentid.IsAtBox(seat) || !agentid.IsAgent(id) || len(seat) > 100 {
		return "seat must be the acting agent, <ID>@<box>"
	}
	return ""
}

// CheckClaimHow names what is wrong with a close ("" = fine).
func CheckClaimHow(how string) string {
	if !handledHowRe.MatchString(how) || len(how) > ClaimTextMax+20 || hasControl(how) {
		return "how must be answered, handed:<lane> or no-reply:<reason> (one line)"
	}
	return ""
}

// CheckClaimReason names what is wrong with a release reason ("" = fine).
func CheckClaimReason(reason string) string {
	if reason == "" || len(reason) > ClaimTextMax || hasControl(reason) {
		return "reason must be one line of 1..500 bytes (harness-refused:<step>, send-failed, ...)"
	}
	return ""
}

// claimFree: a peer message nobody holds a live lock on, and no 093 round
// is open on.
func claimFree(m *Message, now time.Time) bool {
	return m.NeedsPeer && m.HandledAt.IsZero() && m.Round.State != ClaimOffered &&
		(m.Responsible == "" || m.LockedUntil.IsZero() || m.LockedUntil.Before(now))
}

// claimRefusal is ErrConflict when c may not release / close m: it is closed,
// another seat holds it, or the fence moved. Both drivers share it.
func claimRefusal(m *Message, c ClaimClose) error {
	if !m.HandledAt.IsZero() || m.Responsible != c.Seat || (c.Gen > 0 && c.Gen != m.ResponsibleGen) {
		return ErrConflict
	}
	return nil
}

// applyRelease / applyClose change m in place; both drivers share them.
// A release is 093's T8 (free, free since now), a close its T9 (done).
func applyRelease(m *Message, c ClaimClose, now time.Time) {
	m.Responsible, m.LockedUntil = "", time.Time{}
	m.Round = ClaimRound{State: ClaimFree, OfferN: m.Round.OfferN, OfferUntil: now, Lapsed: m.Round.Lapsed, TouchedAt: now}
	if strings.HasPrefix(c.Reason, "harness-refused:") && c.Harness != "" && !slices.Contains(m.NotBy, c.Harness) {
		m.NotBy = append(slices.Clone(m.NotBy), c.Harness)
	}
}

func applyClose(m *Message, how string, now time.Time) {
	m.HandledAt, m.HandledHow, m.LockedUntil = now, how, time.Time{}
	m.Round.State, m.Round.TouchedAt, m.Round.OfferSet, m.Round.ParkedUntil = ClaimDone, now, nil, time.Time{}
}

// seatedLocked reports whether tenant's roster holds a peer seat. s.mu held.
func (s *Memory) seatedLocked(tenant string) bool {
	for k, as := range s.roster {
		if k[0] == tenant && slices.ContainsFunc(as, IsPeerSeat) {
			return true
		}
	}
	return false
}

// claimRowsLocked is tenant's messages matching keep, oldest first. s.mu held.
func (s *Memory) claimRowsLocked(tenant string, keep func(*Message) bool) []*Message {
	var out []*Message
	for k, m := range s.messages {
		if k[0] == tenant && keep(m) {
			out = append(out, m)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].TS.Equal(out[j].TS) {
			return out[i].TS.Before(out[j].TS)
		}
		return out[i].MsgID < out[j].MsgID
	})
	return out
}

func claimCopy(m *Message) Message {
	c := *m
	c.NotBy = slices.Clone(m.NotBy)
	c.Round.OfferSet, c.Round.Lapsed = slices.Clone(m.Round.OfferSet), slices.Clone(m.Round.Lapsed)
	return c
}

func (s *Memory) PollMessageClaims(_ context.Context, tenant string, p ClaimPoll, now time.Time) ([]Message, []Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	claimed, dead := []Message{}, []Message{}
	for _, m := range s.claimRowsLocked(tenant, func(m *Message) bool { return claimFree(m, now) && m.ClaimN >= ClaimMax }) {
		if len(dead) == ClaimPollMax {
			break
		}
		applyClose(m, "dead", now)
		dead = append(dead, claimCopy(m))
	}
	for _, m := range s.claimRowsLocked(tenant, func(m *Message) bool {
		return claimFree(m, now) && m.ClaimN < ClaimMax && !slices.Contains(m.NotBy, p.Harness)
	}) {
		if len(claimed) == p.Max {
			break
		}
		applyClaim(m, p.Seat, p.TTL, now)
		claimed = append(claimed, claimCopy(m))
	}
	return claimed, dead, nil
}

func (s *Memory) RenewMessageClaims(_ context.Context, tenant, seat string, ttl time.Duration, now time.Time) ([]Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []Message{}
	for _, m := range s.claimRowsLocked(tenant, func(m *Message) bool {
		return m.NeedsPeer && m.HandledAt.IsZero() && m.Responsible == seat
	}) {
		if m.LockedUntil.Before(now.Add(ttl / 2)) {
			m.LockedUntil = now.Add(ttl)
		}
		out = append(out, claimCopy(m))
	}
	return out, nil
}

func (s *Memory) ReleaseMessageClaim(_ context.Context, tenant string, c ClaimClose, now time.Time) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.messages[[2]string{tenant, c.MsgID}]
	if !ok {
		return Message{}, ErrNotFound
	}
	if err := claimRefusal(m, c); err != nil {
		return claimCopy(m), err
	}
	if !m.NeedsPeer {
		return claimCopy(m), ErrNotPeerMessage
	}
	applyRelease(m, c, now)
	return claimCopy(m), nil
}

func (s *Memory) CloseMessageClaim(_ context.Context, tenant string, c ClaimClose, now time.Time) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.messages[[2]string{tenant, c.MsgID}]
	if !ok {
		return Message{}, ErrNotFound
	}
	if err := claimRefusal(m, c); err != nil {
		return claimCopy(m), err
	}
	applyClose(m, c.How, now)
	return claimCopy(m), nil
}

func (s *Memory) GetMessageClaim(_ context.Context, tenant, msgID string) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.messages[[2]string{tenant, msgID}]
	if !ok {
		return Message{}, ErrNotFound
	}
	return claimCopy(m), nil
}

func (s *Memory) AdoptMessageClaim(_ context.Context, tenant string, c ClaimClose, ttl time.Duration, now time.Time) (Message, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.messages[[2]string{tenant, c.MsgID}]
	if !ok {
		return Message{}, false, ErrNotFound
	}
	if !m.NeedsPeer {
		return claimCopy(m), false, ErrNotPeerMessage
	}
	if !claimFree(m, now) {
		return claimCopy(m), false, nil
	}
	applyClaim(m, c.Seat, ttl, now)
	return claimCopy(m), true, nil
}

// Spec 093 section 4 (rdb 0132, task T008): the claim in two phases. A
// round, run by a seat's poll loop, tells up to OfferK seats about a job;
// the job is owned only once an agent accepts it with its own call. Every
// transition T1..T10 of 4.2 is one function below, shared by both drivers:
// Memory runs it under its mutex, Postgres on the row read FOR UPDATE in one
// transaction, so the two cannot drift. Every function writes claim_state
// together with the clocks it implies, so a row is in exactly one state
// (ClaimStateProblem names a row that is not).

// The claim states (rdb 0132 claim_state).
const (
	ClaimFree    = "free"
	ClaimOffered = "offered"
	ClaimOwned   = "owned"
	ClaimParked  = "parked"
	ClaimDone    = "done"
)

// The round knobs the hub enforces (spec 093 4.2, 4.3, 5.3).
const (
	OfferWindow  = 20 * time.Second // OFFER_WINDOW: a round's accept window
	OfferK       = 2                // OFFER_K: the seats one round tells
	OfferMax     = 6                // OFFER_MAX: rounds without an accept before the job goes dead
	BusyDelay    = 8 * time.Second  // BUSY_DELAY: a busy seat opens or joins only this long after an idle one could
	HarnessDelay = 5 * time.Second  // a seat of a harness already in the round joins only this late
	HBFresh      = 120 * time.Second
	JobIdleMax   = 15 * time.Minute // JOB_IDLE_MAX: an owned job untouched this long is not renewed
	ParkMax      = 60 * time.Minute // PARK_MAX: the furthest a park may reach
)

// ErrClaimArg: a claim call whose arguments are refused (a park past
// ParkMax, a reason that is not one line). The row is not read.
var ErrClaimArg = errors.New("claim arguments refused")

// ClaimRound is the 093 half of a message's claim (rdb 0132). While the row
// is free, OfferUntil is the moment it went free (a lapse, an expiry, a
// release), zero = since its insert: a busy seat opens a round only
// BusyDelay after it.
type ClaimRound struct {
	State                 string
	OfferSet              []string
	OfferN                int
	OfferUntil            time.Time
	Lapsed                []string
	AcceptedAt, TouchedAt time.Time
	ParkedUntil           time.Time
	ParkReason, WaitToken string
}

// RoundPoll is one poll of a READY seat (T1, T1j): Busy = the seat is inside
// a turn; Ready = every ready seat the caller knows (Seat always counts),
// the set whose lapse clears the skip list; Max = the most rounds the seat
// may be in at once.
type RoundPoll struct {
	Seat, Harness string
	Busy          bool
	Ready         []string
	Max           int
}

// ClaimAct is an agent's call on one job: Round for an accept, Gen (the
// fence) for the holder's calls, Until / Wait / Reason for a park.
type ClaimAct struct {
	MsgID, Seat  string
	Round        int
	Gen          int64
	Until        time.Time
	Wait, Reason string
}

// ClaimRenew is the holder seat's renew (T4): Fresh and Able are its
// heartbeat verdicts (spec 5.3, section 9), AnchorAge how long ago its
// anchor was, measured on the box: the hub turns it into its own clock, so
// a box never compares its clock with a lock.
type ClaimRenew struct {
	Seat        string
	Fresh, Able bool
	AnchorAge   time.Duration
}

// MessageRounds is spec 093's claim contract. A refused call returns
// ErrConflict and the CURRENT row; ErrNotFound when there is no such message.
type MessageRounds interface {
	// PollMessageRounds settles the tenant's open jobs (T5 expiry, T3
	// lapse, T10 dead: returned once as dead), then opens or joins rounds
	// for p.Seat (T1, T1j), oldest first. It returns every open round
	// p.Seat is in, new or not: the poll loop's stubs.
	PollMessageRounds(ctx context.Context, tenant string, p RoundPoll, now time.Time) (offered, dead []Message, err error)
	// AcceptMessageClaim is T2: the first accept of an open round wins and
	// gets the body and the new fence; the loser gets ErrConflict.
	AcceptMessageClaim(ctx context.Context, tenant string, a ClaimAct, now time.Time) (Message, error)
	// RenewMessageRounds is T4 on every job r.Seat holds, and returns them:
	// an owned job to anchor + HBFresh while fresh and touched within
	// JobIdleMax, a parked one to now + HBFresh while able and before
	// parked_until. A lock already run out is expired (T5), never renewed.
	RenewMessageRounds(ctx context.Context, tenant string, r ClaimRenew, now time.Time) ([]Message, error)
	// ParkMessageClaim is T6, UnparkMessageClaim T7a, ReofferMessageClaim
	// T7b (a round for the holder alone), TouchMessageClaim the per-job
	// touch: each needs the holder at its fence (a.Gen).
	ParkMessageClaim(ctx context.Context, tenant string, a ClaimAct, now time.Time) (Message, error)
	UnparkMessageClaim(ctx context.Context, tenant string, a ClaimAct, now time.Time) (Message, error)
	ReofferMessageClaim(ctx context.Context, tenant string, a ClaimAct, now time.Time) (Message, error)
	TouchMessageClaim(ctx context.Context, tenant string, a ClaimAct, now time.Time) (Message, error)
}

// CheckClaimPark names what is wrong with a park ("" = fine).
func CheckClaimPark(a ClaimAct, now time.Time) string {
	switch {
	case !a.Until.After(now) || a.Until.After(now.Add(ParkMax)):
		return "until must be in the future, at most 60 min ahead"
	case a.Wait == "" || len(a.Wait) > 200 || hasControl(a.Wait):
		return "wait must be one line of 1..200 bytes (a lane id, a task id, a CI run)"
	}
	return CheckClaimReason(a.Reason)
}

// ClaimStateProblem names how m's claim columns disagree with its state
// ("" = they agree). Only a peer message is held to it.
func ClaimStateProblem(m Message) string {
	r, held := m.Round, m.Responsible != "" && !m.LockedUntil.IsZero()
	ok := map[string]bool{
		ClaimFree:    m.Responsible == "" && m.LockedUntil.IsZero() && r.AcceptedAt.IsZero() && r.ParkedUntil.IsZero() && len(r.OfferSet) == 0 && m.HandledAt.IsZero(),
		ClaimOffered: m.Responsible == "" && m.LockedUntil.IsZero() && len(r.OfferSet) > 0 && !r.OfferUntil.IsZero() && r.ParkedUntil.IsZero() && m.HandledAt.IsZero(),
		ClaimOwned:   held && !r.AcceptedAt.IsZero() && len(r.OfferSet) == 0 && r.ParkedUntil.IsZero() && m.HandledAt.IsZero(),
		ClaimParked:  held && !r.ParkedUntil.IsZero() && r.WaitToken != "" && len(r.OfferSet) == 0 && m.HandledAt.IsZero(),
		ClaimDone:    !m.HandledAt.IsZero() && m.HandledHow != "" && m.LockedUntil.IsZero(),
	}
	if !m.NeedsPeer || ok[roundState(&m)] {
		return ""
	}
	return "claim_state " + r.State + " disagrees with its columns"
}

// roundState is m's state; "" (a row from before 0132) is free.
func roundState(m *Message) string {
	if m.Round.State == "" {
		return ClaimFree
	}
	return m.Round.State
}

func lapsedOrOffered(m *Message, seat string) bool {
	return slices.Contains(m.Round.Lapsed, seat) || slices.Contains(m.Round.OfferSet, seat)
}

// roundSettle is T5 and T3 on one row, and the step every call takes first,
// so no call ever acts on a lock or a round that has run out. It reports
// whether m changed.
func roundSettle(m *Message, now time.Time) bool {
	switch st := roundState(m); {
	case (st == ClaimOwned || st == ClaimParked) && m.LockedUntil.Before(now):
		// T5, the owner's 2-minute rule: claim_n stays; a parked job's
		// wait_token and park_reason go to the next owner.
		m.Round = ClaimRound{State: ClaimFree, OfferN: m.Round.OfferN, OfferUntil: m.LockedUntil, Lapsed: m.Round.Lapsed,
			TouchedAt: m.Round.TouchedAt, ParkReason: m.Round.ParkReason, WaitToken: m.Round.WaitToken}
		m.Responsible, m.LockedUntil = "", time.Time{}
		return true
	case st == ClaimOffered && m.Round.OfferUntil.Before(now):
		// T3: a lapse is a one-lap skip of the seats that were told.
		lapsed := slices.Clone(m.Round.Lapsed)
		for _, s := range m.Round.OfferSet {
			if !slices.Contains(lapsed, s) {
				lapsed = append(lapsed, s)
			}
		}
		m.Round.State, m.Round.OfferSet, m.Round.Lapsed = ClaimFree, nil, lapsed
		return true
	}
	return false
}

// roundDead is T10 on a settled free row: CLAIM_MAX accepts or OFFER_MAX
// rounds without a close. It reports whether m went dead.
func roundDead(m *Message, now time.Time) bool {
	if !m.NeedsPeer || roundState(m) != ClaimFree || (m.ClaimN < ClaimMax && m.Round.OfferN < OfferMax) {
		return false
	}
	applyClose(m, "dead", now)
	return true
}

// roundOffer is T1 (open) or T1j (join) of m for p on a settled row. It
// reports whether m changed; the caller counts m against p.Max when
// p.Seat is in its offer_set afterwards.
func roundOffer(m *Message, p RoundPoll, now time.Time) bool {
	if !m.NeedsPeer || !m.HandledAt.IsZero() || slices.Contains(m.NotBy, pollHarness(p)) {
		return false
	}
	switch roundState(m) {
	case ClaimFree:
		return roundOpen(m, p, now)
	case ClaimOffered:
		return roundJoin(m, p, now)
	}
	return false
}

func pollHarness(p RoundPoll) string {
	if p.Harness != "" {
		return p.Harness
	}
	return agentid.Kind(p.Seat)
}

// roundOpen is T1: an idle seat at once, a busy one BusyDelay after the row
// went free. A seat on the skip list waits its lap, unless every ready seat
// is on it: then the same step clears the list.
func roundOpen(m *Message, p RoundPoll, now time.Time) bool {
	freeSince := m.TS
	if m.Round.OfferUntil.After(freeSince) {
		freeSince = m.Round.OfferUntil
	}
	if p.Busy && now.Before(freeSince.Add(BusyDelay)) {
		return false
	}
	lapsed := m.Round.Lapsed
	if slices.Contains(lapsed, p.Seat) {
		for _, s := range p.Ready {
			if !slices.Contains(lapsed, s) {
				return false
			}
		}
		lapsed = nil
	}
	m.Round.State, m.Round.OfferSet, m.Round.Lapsed = ClaimOffered, []string{p.Seat}, lapsed
	m.Round.OfferN++
	m.Round.OfferUntil = now.Add(OfferWindow)
	return true
}

// roundJoin is T1j: room in the round, the seat not yet told or lapsed; a
// busy seat waits BusyDelay and a seat of a harness already told waits
// HarnessDelay after the round opened (room for another harness).
func roundJoin(m *Message, p RoundPoll, now time.Time) bool {
	if len(m.Round.OfferSet) >= OfferK || lapsedOrOffered(m, p.Seat) {
		return false
	}
	wait := time.Duration(0)
	if p.Busy {
		wait = BusyDelay
	}
	if slices.ContainsFunc(m.Round.OfferSet, func(s string) bool { return agentid.Kind(s) == agentid.Kind(p.Seat) }) {
		wait = max(wait, HarnessDelay)
	}
	if now.Before(m.Round.OfferUntil.Add(-OfferWindow).Add(wait)) {
		return false
	}
	m.Round.OfferSet = append(slices.Clone(m.Round.OfferSet), p.Seat)
	return true
}

// roundAccept is T2. claim_n counts accepts only.
func roundAccept(m *Message, a ClaimAct, now time.Time) error {
	if roundState(m) != ClaimOffered || !slices.Contains(m.Round.OfferSet, a.Seat) || m.Round.OfferN != a.Round || m.Round.OfferUntil.Before(now) {
		return ErrConflict
	}
	m.Responsible, m.LockedUntil = a.Seat, now.Add(HBFresh)
	m.ResponsibleGen++
	m.ClaimN++
	m.Round.State, m.Round.OfferSet, m.Round.Lapsed = ClaimOwned, nil, nil
	m.Round.AcceptedAt, m.Round.TouchedAt = now, now
	return nil
}

// roundHolder refuses a holder call unless a.Seat holds m at fence a.Gen in
// one of states.
func roundHolder(m *Message, a ClaimAct, states ...string) error {
	if !slices.Contains(states, roundState(m)) || m.Responsible != a.Seat || m.ResponsibleGen != a.Gen {
		return ErrConflict
	}
	return nil
}

// roundRenew is T4 on one row a seat holds (settled first). It reports
// whether m changed; an unchanged lock is not rewritten (a write bumps the
// view stamp, rdb 0103).
func roundRenew(m *Message, r ClaimRenew, now time.Time) bool {
	want := time.Time{}
	switch roundState(m) {
	case ClaimOwned:
		if r.Fresh && !m.Round.TouchedAt.Before(now.Add(-JobIdleMax)) {
			want = now.Add(-max(r.AnchorAge, 0)).Add(HBFresh)
		}
	case ClaimParked:
		if r.Able && now.Before(m.Round.ParkedUntil) {
			want = now.Add(HBFresh)
		}
	}
	if want.IsZero() || want.Equal(m.LockedUntil) {
		return false
	}
	m.LockedUntil = want
	return true
}

// The holder's single-row steps (T6, T7a, T7b, touch); each runs on a
// settled row and returns ErrConflict to refuse.
func roundPark(a ClaimAct, now time.Time) func(*Message) error {
	return func(m *Message) error {
		if err := roundHolder(m, a, ClaimOwned, ClaimParked); err != nil {
			return err
		}
		m.Round.State, m.Round.ParkedUntil, m.Round.ParkReason, m.Round.WaitToken = ClaimParked, a.Until, a.Reason, a.Wait
		m.Round.TouchedAt = now
		return nil
	}
}

func roundUnpark(a ClaimAct, now time.Time) func(*Message) error {
	return func(m *Message) error {
		if err := roundHolder(m, a, ClaimParked); err != nil {
			return err
		}
		m.Round.State, m.Round.ParkedUntil, m.Round.ParkReason, m.Round.WaitToken = ClaimOwned, time.Time{}, "", ""
		m.Round.TouchedAt, m.LockedUntil = now, now.Add(HBFresh)
		return nil
	}
}

func roundReoffer(a ClaimAct, now time.Time) func(*Message) error {
	return func(m *Message) error {
		if err := roundHolder(m, a, ClaimParked); err != nil {
			return err
		}
		m.Round = ClaimRound{State: ClaimOffered, OfferSet: []string{a.Seat}, OfferN: m.Round.OfferN + 1,
			OfferUntil: now.Add(OfferWindow), TouchedAt: now}
		m.Responsible, m.LockedUntil = "", time.Time{}
		return nil
	}
}

func roundTouch(a ClaimAct, now time.Time) func(*Message) error {
	return func(m *Message) error {
		if err := roundHolder(m, a, ClaimOwned, ClaimParked); err != nil {
			return err
		}
		m.Round.TouchedAt = now
		return nil
	}
}

func (s *Memory) PollMessageRounds(_ context.Context, tenant string, p RoundPoll, now time.Time) ([]Message, []Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	offered, dead := []Message{}, []Message{}
	for _, m := range s.claimRowsLocked(tenant, func(m *Message) bool { return m.NeedsPeer && m.HandledAt.IsZero() }) {
		switch _, got := roundPollRow(m, p, now, len(offered) < p.Max); got {
		case ClaimDone:
			dead = append(dead, claimCopy(m))
		case ClaimOffered:
			offered = append(offered, claimCopy(m))
		}
	}
	return offered, dead, nil
}

// roundPollRow is one open row of a poll, oldest first: settle it, close it
// dead, or (room = p.Seat may be in one more round) open or join its round.
// It reports whether m changed and what the poll returns it as: ClaimDone
// (dead), ClaimOffered (a round p.Seat is in), or "".
func roundPollRow(m *Message, p RoundPoll, now time.Time, room bool) (bool, string) {
	changed := roundSettle(m, now)
	switch {
	case roundDead(m, now):
		return true, ClaimDone
	case !room:
		return changed, ""
	case inRound(m, p.Seat):
		return changed, ClaimOffered
	case roundOffer(m, p, now):
		return true, ClaimOffered
	}
	return changed, ""
}

// inRound: m's open round already told seat.
func inRound(m *Message, seat string) bool {
	return roundState(m) == ClaimOffered && slices.Contains(m.Round.OfferSet, seat)
}

func (s *Memory) AcceptMessageClaim(_ context.Context, tenant string, a ClaimAct, now time.Time) (Message, error) {
	return s.roundStep(tenant, a.MsgID, now, func(m *Message) error { return roundAccept(m, a, now) })
}

func (s *Memory) RenewMessageRounds(_ context.Context, tenant string, r ClaimRenew, now time.Time) ([]Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []Message{}
	for _, m := range s.claimRowsLocked(tenant, func(m *Message) bool {
		return m.NeedsPeer && m.HandledAt.IsZero() && m.Responsible == r.Seat
	}) {
		if roundSettle(m, now) {
			continue
		}
		roundRenew(m, r, now)
		out = append(out, claimCopy(m))
	}
	return out, nil
}

func (s *Memory) ParkMessageClaim(_ context.Context, tenant string, a ClaimAct, now time.Time) (Message, error) {
	if CheckClaimPark(a, now) != "" {
		return Message{}, ErrClaimArg
	}
	return s.roundStep(tenant, a.MsgID, now, roundPark(a, now))
}

func (s *Memory) UnparkMessageClaim(_ context.Context, tenant string, a ClaimAct, now time.Time) (Message, error) {
	return s.roundStep(tenant, a.MsgID, now, roundUnpark(a, now))
}

func (s *Memory) ReofferMessageClaim(_ context.Context, tenant string, a ClaimAct, now time.Time) (Message, error) {
	return s.roundStep(tenant, a.MsgID, now, roundReoffer(a, now))
}

func (s *Memory) TouchMessageClaim(_ context.Context, tenant string, a ClaimAct, now time.Time) (Message, error) {
	return s.roundStep(tenant, a.MsgID, now, roundTouch(a, now))
}

// roundStep settles one row and applies step to it under s.mu; a refusal
// leaves the settled row and returns it with the error.
func (s *Memory) roundStep(tenant, msgID string, now time.Time, step func(*Message) error) (Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.messages[[2]string{tenant, msgID}]
	if !ok {
		return Message{}, ErrNotFound
	}
	if m.NeedsPeer && m.HandledAt.IsZero() {
		roundSettle(m, now)
	}
	err := step(m)
	return claimCopy(m), err
}
