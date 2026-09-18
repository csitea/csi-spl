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
	"fmt"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
)

// ErrNotFound is returned for an absent tenant, pin or message.
var ErrNotFound = errors.New("not found")

// ErrConflict is returned for a pin with a different key (without force), a
// tenant re-created with a different root key, or a msg_id re-used with a
// different canonical envelope (FR-010).
var ErrConflict = errors.New("conflict")

// ErrStale is returned for a tenant-root-signed pin op whose ts is not later
// than the last op that changed the pin: a replay (004 pin-semantics §5).
var ErrStale = errors.New("stale pin op")

// Delivery states the hub persists (deliveries.state). The send-result values
// "local" and "pending" never reach the hub (data-model.md §2a).
const (
	StateQueued  = "queued"
	StateSent    = "sent"
	StateExpired = "expired"
)

// Tenant is one renter (006). Only the root PUBLIC key is kept. Quotas are
// the plan's (cnf), not per-row columns (006 FR-008, OQ-006-1).
type Tenant struct {
	ID            string
	RootPubKey    ed25519.PublicKey
	BillingStatus string
	PlanID        string
}

func normalizeTenant(t *Tenant) error {
	if len(t.RootPubKey) != ed25519.PublicKeySize {
		return fmt.Errorf("root pubkey must be %d bytes (private key is never stored)", ed25519.PublicKeySize)
	}
	if t.BillingStatus == "" {
		t.BillingStatus = billing.StatusInternal
	}
	if !billing.ValidStatus(t.BillingStatus) {
		return fmt.Errorf("billing_status %q is not a tenants.billing_status value", t.BillingStatus)
	}
	if t.PlanID == "" {
		t.PlanID = "default"
	}
	return nil
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

	// PutPin pins box's key (004 contracts/pin-semantics.md §2). The same key on
	// an active pin is a no-op with no write. A different key, or any key on a
	// revoked pin, is ErrConflict unless force. A state change needs opTS (the
	// signed client ts) later than the pin's last op, else ErrStale.
	PutPin(ctx context.Context, tenantID, boxID string, pub ed25519.PublicKey, force bool, opTS, now time.Time) error
	// RevokePin revokes an active pin (ErrStale as for PutPin). Revoking an
	// already revoked pin is a no-op; an absent pin is ErrNotFound.
	RevokePin(ctx context.Context, tenantID, boxID string, opTS, now time.Time) error
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
