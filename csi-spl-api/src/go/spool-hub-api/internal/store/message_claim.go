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
// "the orchestrator" reaches the hub as to_id 'peers').
const PeersID = "peers"

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
	odSeatRe     = regexp.MustCompile(`^[acgq]-00[1-4]$`)
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
}

// ClaimHeld reports whether seat still holds m at fence gen on the hub clock:
// responsible, the same generation, open, and its lock (if any) not run out.
func ClaimHeld(m Message, seat string, gen int64, now time.Time) bool {
	return m.HandledAt.IsZero() && m.Responsible == seat && m.ResponsibleGen == gen &&
		(m.LockedUntil.IsZero() || !m.LockedUntil.Before(now))
}

// applyClaim makes m seat's for ttl; both drivers' poll and adopt share it.
func applyClaim(m *Message, seat string, ttl time.Duration, now time.Time) {
	m.Responsible, m.LockedUntil = seat, now.Add(ttl)
	m.ResponsibleGen++
	m.ClaimN++
}

// claimDefaults resets m's claim fields to what an insert stores; the 0110
// trigger is its Postgres twin. seated: the tenant's roster holds a peer seat.
func claimDefaults(m *Message, seated bool) {
	m.Responsible, m.LockedUntil, m.ResponsibleGen, m.ClaimN = "", time.Time{}, 0, 0
	m.HandledAt, m.HandledHow, m.NotBy, m.NeedsPeer = time.Time{}, "", nil, false
	if agentid.IsAgent(m.ToID) {
		m.Responsible = m.ToID + "@" + m.ToBox
	}
	switch {
	case m.ToID == PeersID:
		m.NeedsPeer = true
	case m.Responsible == "" && m.FromBox == "box-wui" && strings.HasPrefix(m.FromID, "HUM-") && m.ToID == "ALL-0" && seated:
		m.NeedsPeer = true
	}
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

// claimFree: a peer message nobody holds a live lock on.
func claimFree(m *Message, now time.Time) bool {
	return m.NeedsPeer && m.HandledAt.IsZero() && (m.Responsible == "" || m.LockedUntil.IsZero() || m.LockedUntil.Before(now))
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
func applyRelease(m *Message, c ClaimClose) {
	m.Responsible, m.LockedUntil = "", time.Time{}
	if strings.HasPrefix(c.Reason, "harness-refused:") && c.Harness != "" && !slices.Contains(m.NotBy, c.Harness) {
		m.NotBy = append(slices.Clone(m.NotBy), c.Harness)
	}
}

func applyClose(m *Message, how string, now time.Time) {
	m.HandledAt, m.HandledHow, m.LockedUntil = now, how, time.Time{}
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

func (s *Memory) ReleaseMessageClaim(_ context.Context, tenant string, c ClaimClose, _ time.Time) (Message, error) {
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
	applyRelease(m, c)
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
