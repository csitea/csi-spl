package auth

import (
	"context"
	"sync"
	"time"
)

// Sessions are stateless signed cookies, so "sign them out everywhere" (the
// admin password reset, admin_reset.go) is a per-human cut-off: a session of
// that human issued before the cut-off's second is no session (a session
// minted in that very second - the reset link's own sign-in - lives). The cut-offs live
// in the store (rdb 0148 session_revocations) so every hub instance honours
// them; each instance keeps them in memory and re-reads them at most every
// revokeRefresh, off the request path, so the check costs no round trip.

// SessionRevoker persists the cut-offs.
type SessionRevoker interface {
	// RevokeSessions sets humanID's cut-off to at (a later one wins).
	RevokeSessions(ctx context.Context, humanID string, at time.Time) error
	// SessionRevocations answers every cut-off later than since.
	SessionRevocations(ctx context.Context, since time.Time) (map[string]time.Time, error)
}

// revokeRefresh bounds how long another instance keeps honouring a session
// this one revoked.
const revokeRefresh = 15 * time.Second

type revocations struct {
	src     SessionRevoker // nil = this instance's memory only (tests, lde)
	ttl     time.Duration  // a session older than the TTL is dead anyway
	mu      sync.Mutex
	at      map[string]time.Time
	loaded  time.Time
	loading bool
}

func newRevocations(src SessionRevoker, ttl time.Duration) *revocations {
	return &revocations{src: src, ttl: ttl, at: map[string]time.Time{}}
}

// dead reports whether s was issued before its human's cut-off second. The
// first call loads the cut-offs; later ones refresh them in the background.
func (v *revocations) dead(ctx context.Context, s Session, now time.Time) bool {
	if v == nil || s.HumanID == "" {
		return false
	}
	v.mu.Lock()
	first := v.src != nil && v.loaded.IsZero() && !v.loading
	stale := v.src != nil && !v.loaded.IsZero() && !v.loading && now.Sub(v.loaded) >= revokeRefresh
	if first || stale {
		v.loading = true
	}
	v.mu.Unlock()
	switch {
	case first:
		c, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
		v.load(c, now)
		cancel()
	case stale:
		go func() {
			c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			v.load(c, now)
		}()
	}
	v.mu.Lock()
	cut, ok := v.at[s.HumanID]
	v.mu.Unlock()
	return ok && s.IssuedAt < cut.Unix()
}

// load merges the stored cut-offs and drops the expired ones. A failed read
// keeps what is known and retries at the next refresh.
func (v *revocations) load(ctx context.Context, now time.Time) {
	got, err := v.src.SessionRevocations(ctx, now.Add(-v.ttl))
	v.mu.Lock()
	defer v.mu.Unlock()
	v.loading = false
	v.loaded = now
	if err != nil {
		return
	}
	for hum, at := range got {
		if at.After(v.at[hum]) {
			v.at[hum] = at
		}
	}
	for hum, at := range v.at {
		if now.Sub(at) > v.ttl {
			delete(v.at, hum)
		}
	}
}

// RevokeSessions ends every session humanID holds now: at once on this
// instance, within revokeRefresh on the others.
func (h *Handler) RevokeSessions(ctx context.Context, humanID string, at time.Time) error {
	if humanID == "" || h.revoked == nil {
		return nil
	}
	if v := h.revoked; v.src != nil {
		if err := v.src.RevokeSessions(ctx, humanID, at); err != nil {
			return err
		}
	}
	h.revoked.mu.Lock()
	if at.After(h.revoked.at[humanID]) {
		h.revoked.at[humanID] = at
	}
	h.revoked.mu.Unlock()
	return nil
}
