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
	// Attempts is how many times this post has been escalated (SPL-1225 miss
	// fix): 1 on the first, incremented by each BumpFallback re-escalation.
	Attempts int
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
	// ClaimFallback records d only when the post has no fallback yet, and
	// reports whether this call wrote it: the claim that keeps two hub
	// processes from both handing one post out (SPL-1004).
	ClaimFallback(ctx context.Context, d FallbackDelivery) (bool, error)
	// FallbackOf is the post's fallback record: the box and agent it was last
	// handed to (a re-escalation rewrites them). ErrNotFound when none took it.
	// A move reads it to tell that agent where the post lives now.
	FallbackOf(ctx context.Context, tenantID, msgID string) (FallbackDelivery, error)
	// UnheardPosts lists signed browser posts by a person (from_box box-wui,
	// from HUM-*) received in [since, until) that no agent box was sent and
	// no fallback took, oldest first, at most limit (SPL-1004). Only posts
	// that can fall back: a channel post in a channel that did not opt out,
	// or a DM to an agent. The hub that
	// holds a tenant's boxes sweeps them: the process a post was stored on
	// may hold none of them.
	UnheardPosts(ctx context.Context, tenantID string, since, until time.Time, limit int) ([]Queued, error)
	// UnansweredPosts lists signed browser posts by a person (from_box
	// box-wui, from HUM-*) received in [since, until) that NO agent replied
	// to in their topic and no fallback took, oldest first, at most limit
	// (SPL-1225). Unlike UnheardPosts it does NOT care whether an agent box
	// was "sent" the frame: a channel post is marked sent the instant it is
	// relayed to the shared box-desk, whose roster names every agent that
	// ever had a dir there - alive or long dead - so "sent" and "an agent is
	// online" both read true while no live agent acts. The ground truth that
	// survives a stale roster is a REPLY in the topic; its absence past the
	// grace is what escalates the post to the tenant's responder. A reply is
	// any later message in the same task from a sender that is not the human
	// browser (from_box <> box-wui and from_id not a HUM-/GST- id).
	UnansweredPosts(ctx context.Context, tenantID string, since, until time.Time, limit int) ([]Queued, error)
	// ReescalatablePosts lists posts that WERE escalated (have a fallback row)
	// whose last attempt is before escalatedBefore, with fewer than maxAttempts
	// attempts, received before until, and still no reply in the topic. The
	// relay re-poke + rotates the responder for these so one refused poke to a
	// busy responder is not permanent silence (SPL-1225 miss fix, 4b0ba40a).
	// The since lower bound keeps it from digging up ANCIENT posts (an old
	// SPL-997 fallback row on a days-old probe post) once re-escalation was
	// added: only posts received in [since, until) are re-escalated.
	ReescalatablePosts(ctx context.Context, tenantID string, since, escalatedBefore, until time.Time, maxAttempts, limit int) ([]Queued, error)
	// BumpFallback records a re-escalation: advances delivered_at, increments
	// attempts and rewrites the target, only while attempts < maxAttempts (the
	// claim that hands a re-escalation out once across hub processes). Reports
	// whether this call won the bump.
	BumpFallback(ctx context.Context, d FallbackDelivery, maxAttempts int) (bool, error)
	// ChannelFallbacks summarises the channel's fallback deliveries at or
	// after since ("" channel = the DMs).
	ChannelFallbacks(ctx context.Context, tenantID, channelID string, since time.Time) (FallbackSummary, error)
	// ChannelNoFallback reports whether the channel opted out (rdb 0068,
	// FR-039); an unknown channel reads false.
	ChannelNoFallback(ctx context.Context, tenantID, channelID string) (bool, error)
	// SetChannelNoFallback sets the opt-out. ErrNotFound when the channel
	// does not exist.
	SetChannelNoFallback(ctx context.Context, tenantID, channelID string, off bool) error
}

var (
	_ Fallbacks = (*Memory)(nil)
	_ Fallbacks = (*Postgres)(nil)
)
