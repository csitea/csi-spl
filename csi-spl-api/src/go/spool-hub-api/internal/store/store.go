// Package store is the hub's durable state (specs/003 data-model.md): tenants,
// box pins, the roster, messages and the delivery queue. Two drivers implement
// one interface: Memory (unit tests) and Postgres (production), whose queries
// match the DDL in csi-spl-rdb/src/sql/postgres/spool-hub/. Every call is
// tenant-scoped (FR-015). Nothing here ever holds a private key.
package store

import (
	"context"
	"crypto/ed25519"
	"errors"
	"time"
)

// ErrNotFound is returned for an absent tenant, pin or message.
var ErrNotFound = errors.New("not found")

// ErrConflict is returned for a pin with a different key (without force), a
// tenant re-created with a different root key, or a msg_id re-used with a
// different canonical envelope (FR-010).
var ErrConflict = errors.New("conflict")

// Delivery states the hub persists (deliveries.state). The send-result values
// "local" and "pending" never reach the hub (data-model.md §2a).
const (
	StateQueued  = "queued"
	StateSent    = "sent"
	StateExpired = "expired"
)

// Tenant is one renter (006). Only the root PUBLIC key is kept.
type Tenant struct {
	ID            string
	RootPubKey    ed25519.PublicKey
	BillingStatus string
	PlanID        string
}

// Pin is one pinned box public key.
type Pin struct {
	BoxID  string
	PubKey ed25519.PublicKey
}

// Message is one stored envelope plus the columns derived from its inner v:1.
type Message struct {
	TenantID   string
	MsgID      string
	TaskID     string
	Channel    string // "" = NULL (M1 never sets it)
	TS         time.Time
	FromBox    string
	FromID     string
	ToBox      string
	ToID       string
	Kind       string
	Body       string
	Files      []byte // v:1 files[] JSON
	Msg        []byte // full inner v:1 JSON
	EnvSig     string
	Env        []byte // canonical envelope bytes, forwarded unchanged
	ReceivedAt time.Time
	ExpiresAt  time.Time
}

// Queued is one queued delivery ready to push to a box.
type Queued struct {
	MsgID string
	Env   []byte
}

// SweepResult counts what a retention sweep changed.
type SweepResult struct {
	Expired int // queued deliveries marked expired (TTL or per-box cap)
	Purged  int // messages deleted past retention
}

// Store is the hub's persistence contract.
type Store interface {
	// CreateTenant is idempotent: the same root key is a no-op, a different one
	// is ErrConflict.
	CreateTenant(ctx context.Context, t Tenant) error
	GetTenant(ctx context.Context, tenantID string) (Tenant, error)
	// SetBillingStatus writes tenants.billing_status (payment.md mapping).
	SetBillingStatus(ctx context.Context, tenantID, status string) error

	// PutPin pins box's key. Same key → no change; different key → ErrConflict
	// unless force (a history row records it). A revoked pin is re-activated.
	PutPin(ctx context.Context, tenantID, boxID string, pub ed25519.PublicKey, force bool, now time.Time) error
	RevokePin(ctx context.Context, tenantID, boxID string, now time.Time) error
	// GetPin returns an active pin, or ErrNotFound when absent or revoked.
	GetPin(ctx context.Context, tenantID, boxID string) (ed25519.PublicKey, error)
	ListPins(ctx context.Context, tenantID string) ([]Pin, error)

	// TouchBox records a verified hello (creates the boxes row).
	TouchBox(ctx context.Context, tenantID, boxID string, now time.Time) error
	// SetRoster replaces box's announced agent set.
	SetRoster(ctx context.Context, tenantID, boxID string, agents []string, now time.Time) error
	// Roster returns box_id → sorted agent ids for the tenant.
	Roster(ctx context.Context, tenantID string) (map[string][]string, error)

	// InsertMessage stores m idempotently on (tenant, msg_id): inserted=false
	// with nil error for an identical envelope; ErrConflict for a different one.
	InsertMessage(ctx context.Context, m Message) (inserted bool, err error)
	// Enqueue creates the delivery row (state queued) if absent, then marks the
	// oldest queued rows of to_box beyond maxPerBox as expired.
	Enqueue(ctx context.Context, tenantID, msgID, toBox string, now, expiresAt time.Time, maxPerBox int) error
	// ClaimSent moves a queued, unexpired delivery to sent. claimed=false when it
	// was not queued (already sent, expired, or absent) — the caller must not push.
	ClaimSent(ctx context.Context, tenantID, msgID, toBox string, now time.Time) (claimed bool, err error)
	// Unclaim returns a sent delivery to queued after a failed push.
	Unclaim(ctx context.Context, tenantID, msgID, toBox string) error
	// DeliveryState returns the delivery row's state (ErrNotFound if none).
	DeliveryState(ctx context.Context, tenantID, msgID, toBox string) (string, error)
	// QueuedFor returns to_box's queued, unexpired deliveries, oldest first.
	QueuedFor(ctx context.Context, tenantID, toBox string, now time.Time) ([]Queued, error)
	// TaskEnvelopes returns the stored envelopes of a task, oldest first.
	TaskEnvelopes(ctx context.Context, tenantID, taskID string) ([][]byte, error)

	// Sweep expires queued deliveries past TTL and deletes messages past retention.
	Sweep(ctx context.Context, now time.Time) (SweepResult, error)

	// CountMessagesSince is messages received at or after since (month quota).
	CountMessagesSince(ctx context.Context, tenantID string, since time.Time) (int, error)
	// HasMessage reports whether (tenant, msg_id) is already stored (idempotent send).
	HasMessage(ctx context.Context, tenantID, msgID string) (bool, error)

	Close()
}
