package store

import (
	"context"
	"errors"
	"sync"
)

// Request memo (specs/027 P2). One browser read asks for the same
// membership up to three times: the session door (AuthHooks.Member), the RBAC
// permit (rbac.Authorizer.Access) and the handler's own permission check. Each
// ask is a Postgres round trip. A memo attached to ONE request's context
// answers the repeats from the first read.
//
// It is NOT a cache: it dies with the request, so a removed or demoted member
// still loses access on the very next request or frame (025 FR-004, "the
// membership lookup is never cached"). Attach it only around work that does
// not change memberships itself: a GET view read or one browser frame. A
// sign-in callback admits a member mid-request and must never carry one.
type memoKey struct{}

type memo struct {
	mu    sync.Mutex
	roles map[[2]string]memoRole
	// SPL-1121: reactions a view read fetched in its deliveries batch, per
	// (tenant, msg_id); a message with none is present with a nil list.
	reacts map[[2]string][]StoredReaction
}

type memoRole struct {
	role string
	err  error // nil or ErrNotFound; any other error is never memoised
	// SPL-1034: the membership's channel_order, read by the same statement
	// (ordered = it was read), so GET /v1/view/me stays one round trip.
	order   []string
	ordered bool
	// SPL-1115: the human's channel_humans list (HumanChannels), read in the
	// same batch as the membership, so the read door costs no round trip of
	// its own. chansRead = it was read.
	chans     []string
	chansRead bool
}

// memberRead is what one membership read answered for the memo.
type memberRead struct {
	role      string
	order     []string
	chans     []string
	chansRead bool
}

// clone copies the slices, so a cached read is never shared with a caller.
func (v memberRead) clone() memberRead {
	v.order = append([]string(nil), v.order...)
	v.chans = append([]string(nil), v.chans...)
	return v
}

// WithMemo returns ctx carrying a fresh request memo (ctx itself when it
// already carries one).
func WithMemo(ctx context.Context) context.Context {
	if memoFrom(ctx) != nil {
		return ctx
	}
	return context.WithValue(ctx, memoKey{}, &memo{roles: map[[2]string]memoRole{}})
}

func memoFrom(ctx context.Context) *memo {
	m, _ := ctx.Value(memoKey{}).(*memo)
	return m
}

// memberRoleOrder is memberRole for a driver whose one membership read also
// answers channel_order (rdb 0073) and, with a memo, the human's channels
// (SPL-1115): all of it goes into the memo. load's argument says whether a
// memo will keep what it reads.
func memberRoleOrder(ctx context.Context, humanID, tenant string, load func(memo bool) (memberRead, error)) (string, error) {
	m := memoFrom(ctx)
	if m == nil {
		v, err := load(false)
		return v.role, err
	}
	k := [2]string{tenant, humanID}
	m.mu.Lock()
	r, ok := m.roles[k]
	m.mu.Unlock()
	if ok {
		return r.role, r.err
	}
	v, err := load(true)
	if err == nil || errors.Is(err, ErrNotFound) {
		m.mu.Lock()
		m.roles[k] = memoRole{role: v.role, err: err, order: v.order, ordered: true, chans: v.chans, chansRead: v.chansRead}
		m.mu.Unlock()
	}
	return v.role, err
}

// memoChannels is the human's channel list the request's memo already read
// with the membership: ok=false when it has not.
func memoChannels(ctx context.Context, humanID, tenant string) (chans []string, ok bool) {
	m := memoFrom(ctx)
	if m == nil {
		return nil, false
	}
	m.mu.Lock()
	r, found := m.roles[[2]string{tenant, humanID}]
	m.mu.Unlock()
	if !found || !r.chansRead {
		return nil, false
	}
	return append([]string(nil), r.chans...), true
}

// memoOrder is the channel_order the request's memo already read: ok=false
// when it has not (no memo, or the membership was not read with its order).
func memoOrder(ctx context.Context, humanID, tenant string) (order []string, ok bool, err error) {
	m := memoFrom(ctx)
	if m == nil {
		return nil, false, nil
	}
	m.mu.Lock()
	r, found := m.roles[[2]string{tenant, humanID}]
	m.mu.Unlock()
	if !found || !r.ordered {
		return nil, false, nil
	}
	return append([]string(nil), r.order...), true, r.err
}

// memberRole answers MemberRole once per (tenant, human) for the request's
// memo, and calls load every time when ctx carries none.
func memberRole(ctx context.Context, humanID, tenant string, load func() (string, error)) (string, error) {
	m := memoFrom(ctx)
	if m == nil {
		return load()
	}
	k := [2]string{tenant, humanID}
	m.mu.Lock()
	r, ok := m.roles[k]
	m.mu.Unlock()
	if ok {
		return r.role, r.err
	}
	role, err := load()
	if err == nil || errors.Is(err, ErrNotFound) {
		m.mu.Lock()
		m.roles[k] = memoRole{role: role, err: err}
		m.mu.Unlock()
	}
	return role, err
}

// memoPutReactions keeps the reactions read for ids (every id, reacted or
// not) in the request's memo; no-op without one.
func memoPutReactions(ctx context.Context, tenant string, ids []string, by map[string][]StoredReaction) {
	m := memoFrom(ctx)
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.reacts == nil {
		m.reacts = map[[2]string][]StoredReaction{}
	}
	for _, id := range ids {
		m.reacts[[2]string{tenant, id}] = by[id]
	}
}

// memoReactions answers ReactionsFor(ids) from the request's memo when it
// holds every one of ids; ok=false sends the caller to the database.
func memoReactions(ctx context.Context, tenant string, ids []string) (map[string][]StoredReaction, bool) {
	m := memoFrom(ctx)
	if m == nil {
		return nil, false
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	out := map[string][]StoredReaction{}
	for _, id := range ids {
		rs, ok := m.reacts[[2]string{tenant, id}]
		if !ok {
			return nil, false
		}
		if len(rs) > 0 {
			out[id] = append([]StoredReaction(nil), rs...)
		}
	}
	return out, true
}
