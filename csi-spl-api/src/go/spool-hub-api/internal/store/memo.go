package store

import (
	"context"
	"sync"
)

// Request memo (CLE-34985, specs/027 P2). One browser read asks for the same
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
}

type memoRole struct {
	role string
	err  error // nil or ErrNotFound; any other error is never memoised
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
	if err == nil || err == ErrNotFound {
		m.mu.Lock()
		m.roles[k] = memoRole{role, err}
		m.mu.Unlock()
	}
	return role, err
}
