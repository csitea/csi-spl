package store

import (
	"context"
	"time"
)

// The fallback responder (SPL-997, specs/038 FR-030..FR-038, rdb 0067). A
// human post whose agents are all offline is handed to ONE online agent of
// the tenant: the first online one of the tenant's responder list, else the
// longest-online one. The store keeps the list and a record of every
// fallback delivery.

// FallbackDelivery is one post handed to a fallback agent. Channel "" = a DM.
type FallbackDelivery struct {
	TenantID    string
	MsgID       string
	Channel     string
	Box         string
	Agent       string
	DeliveredAt time.Time
}

// FallbackSummary is a channel's fallback deliveries since some instant: how
// many, and the newest one (zero when Count is 0).
type FallbackSummary struct {
	Count int
	Last  FallbackDelivery
}

// MaxResponders is the most agent ids a tenant's responder list holds (the
// rdb 0067 CHECK).
const MaxResponders = 20

// Fallbacks is the store side of the fallback responder. Memory and Postgres
// implement it; the hub type-asserts it (a store without it falls back to
// nobody).
type Fallbacks interface {
	// TenantResponders is the tenant's ordered responder list; nil = unset.
	TenantResponders(ctx context.Context, tenantID string) ([]string, error)
	// SetTenantResponders replaces the list (nil or empty clears it).
	// ErrNotFound when the tenant does not exist.
	SetTenantResponders(ctx context.Context, tenantID string, agents []string) error
	// RecordFallback stores one fallback delivery; a second record of the
	// same (tenant, msg) is a no-op.
	RecordFallback(ctx context.Context, d FallbackDelivery) error
	// ChannelFallbacks summarises the channel's fallback deliveries at or
	// after since ("" channel = the DMs).
	ChannelFallbacks(ctx context.Context, tenantID, channelID string, since time.Time) (FallbackSummary, error)
}

var (
	_ Fallbacks = (*Memory)(nil)
	_ Fallbacks = (*Postgres)(nil)
)
