package store

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"sort"
	"strings"
	"time"
)

// Agent join tokens (rdb 0119, spec 073 4.1-4.3): a workspace admin mints a
// one-use, short-lived token; redeeming it pins one box key with no tenant
// root key on the box. Only sha256(secret) hex is stored.

// JoinToken is one agent_join_tokens row. ForHuman and BoxID "" = unset.
type JoinToken struct {
	Hash        string
	TenantID    string
	CreatedBy   string
	ForHuman    string
	Label       string
	BoxID       string
	CreatedAt   time.Time
	ExpiresAt   time.Time
	ConsumedAt  *time.Time
	ConsumedBox string
	RevokedAt   *time.Time
}

// JoinTokenIDLen is the length of a token's public id: the first hex of its hash.
const JoinTokenIDLen = 8

// ID is the token's public id (spec 4.3: the first 8 hex of the hash).
func (t JoinToken) ID() string {
	if len(t.Hash) < JoinTokenIDLen {
		return t.Hash
	}
	return t.Hash[:JoinTokenIDLen]
}

// State is open, used or revoked (spec 4.3 list answer).
func (t JoinToken) State() string {
	switch {
	case t.RevokedAt != nil:
		return "revoked"
	case t.ConsumedAt != nil:
		return "used"
	}
	return "open"
}

// The refusals of a redeem (spec 4.3 table). The hub maps each to its code.
var (
	ErrJoinTokenInvalid     = errors.New("store: unknown join token")
	ErrJoinTokenUsed        = errors.New("store: join token already used")
	ErrJoinTokenExpired     = errors.New("store: join token expired")
	ErrJoinTokenRevoked     = errors.New("store: join token revoked")
	ErrJoinTokenBoxMismatch = errors.New("store: join token is bound to another box id")
)

// redeemable is the token half of a redeem, in the refusal table's order.
func (t JoinToken) redeemable(box string, now time.Time) error {
	switch {
	case t.RevokedAt != nil:
		return ErrJoinTokenRevoked
	case t.ConsumedAt != nil:
		return ErrJoinTokenUsed
	case !now.Before(t.ExpiresAt):
		return ErrJoinTokenExpired
	case t.BoxID != "" && t.BoxID != box:
		return ErrJoinTokenBoxMismatch
	}
	return nil
}

// JoinTokens is the store half of spec 073 T003.
type JoinTokens interface {
	// CreateJoinToken stores a minted token (Hash, TenantID, CreatedBy,
	// ExpiresAt required).
	CreateJoinToken(ctx context.Context, t JoinToken) error
	// ListJoinTokens is the tenant's tokens not yet expired at now, newest first.
	ListJoinTokens(ctx context.Context, tenant string, now time.Time) ([]JoinToken, error)
	// RevokeJoinToken revokes the unused token whose ID is id. ErrNotFound
	// when none (or the prefix is ambiguous), ErrJoinTokenUsed when it seated
	// a box already; revoking a revoked token is a no-op.
	RevokeJoinToken(ctx context.Context, tenant, id string, now time.Time) (JoinToken, error)
	// RedeemJoinToken consumes the token and pins box to pub in ONE
	// transaction, with PutPin's rules and no force: the same key on the
	// active pin is a no-op pin, another key is ErrConflict. A revoked pin is
	// re-seated (the admin minted a new token for it). The key must not be
	// live on any other box of any workspace (spec 108 3.1): ErrConflict. On
	// any refusal the token stays unused. The token row is answered when it
	// was found, so a refusal can name its expiry or its bound box.
	RedeemJoinToken(ctx context.Context, tenant, hash, box string, pub ed25519.PublicKey, now time.Time) (JoinToken, error)
	// RevokeSeat revokes box's active pin from a member session
	// (pins_history.reason wui-revoke). ErrNotFound when absent; an already
	// revoked pin is a no-op.
	RevokeSeat(ctx context.Context, tenant, box string, now time.Time) error
}

var (
	_ JoinTokens = (*Memory)(nil)
	_ JoinTokens = (*Postgres)(nil)
)

// wuiBox is the hub's browser box, pinned to the hub's own key in every
// workspace (hub.WUIBox): the one box whose key is not unique (spec 108 3.1).
const wuiBox = "box-wui"

// joinListMax caps a list answer: tokens live at most a day.
const joinListMax = 500

func (s *Memory) CreateJoinToken(_ context.Context, t JoinToken) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[t.TenantID]; !ok {
		return ErrNotFound
	}
	if s.joins == nil {
		s.joins = map[string]*JoinToken{}
	}
	if _, ok := s.joins[t.Hash]; ok {
		return ErrConflict
	}
	if t.CreatedAt.IsZero() {
		t.CreatedAt = s.now()
	}
	s.joins[t.Hash] = &t
	return nil
}

func (s *Memory) ListJoinTokens(_ context.Context, tenant string, now time.Time) ([]JoinToken, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []JoinToken
	for _, t := range s.joins {
		if t.TenantID == tenant && now.Before(t.ExpiresAt) {
			out = append(out, *t)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	if len(out) > joinListMax {
		out = out[:joinListMax]
	}
	return out, nil
}

func (s *Memory) RevokeJoinToken(_ context.Context, tenant, id string, now time.Time) (JoinToken, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var hit *JoinToken
	for _, t := range s.joins {
		if t.TenantID == tenant && len(id) == JoinTokenIDLen && strings.HasPrefix(t.Hash, id) {
			if hit != nil {
				return JoinToken{}, ErrNotFound
			}
			hit = t
		}
	}
	switch {
	case hit == nil:
		return JoinToken{}, ErrNotFound
	case hit.RevokedAt != nil:
		return *hit, nil
	case hit.ConsumedAt != nil:
		return *hit, ErrJoinTokenUsed
	}
	at := now
	hit.RevokedAt = &at
	return *hit, nil
}

func (s *Memory) RedeemJoinToken(_ context.Context, tenant, hash, box string, pub ed25519.PublicKey, now time.Time) (JoinToken, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.joins[hash]
	if !ok || t.TenantID != tenant {
		return JoinToken{}, ErrJoinTokenInvalid
	}
	if err := t.redeemable(box, now); err != nil {
		return *t, err
	}
	for k, p := range s.pins {
		if !p.revoked && k[1] != wuiBox && k != [2]string{tenant, box} && bytes.Equal(p.pub, pub) {
			return *t, ErrConflict
		}
	}
	k := [2]string{tenant, box}
	p, had := s.pins[k]
	switch {
	case had && !p.revoked && bytes.Equal(p.pub, pub):
	case had && !p.revoked:
		return *t, ErrConflict
	default:
		cp := append(ed25519.PublicKey(nil), pub...)
		last := now
		if had && p.lastOp.After(last) {
			last = p.lastOp
		}
		s.pins[k] = &memPin{pub: cp, lastOp: last}
		s.history = append(s.history, memHist{tenant: tenant, box: box, reason: "join", pub: cp, at: now})
	}
	at := now
	t.ConsumedAt, t.ConsumedBox = &at, box
	return *t, nil
}

func (s *Memory) RevokeSeat(_ context.Context, tenant, box string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.pins[[2]string{tenant, box}]
	if !ok {
		return ErrNotFound
	}
	if p.revoked {
		return nil
	}
	p.revoked = true
	if now.After(p.lastOp) {
		p.lastOp = now
	}
	s.history = append(s.history, memHist{
		tenant: tenant, box: box, reason: "wui-revoke",
		pub: append(ed25519.PublicKey(nil), p.pub...), at: now,
	})
	return nil
}
