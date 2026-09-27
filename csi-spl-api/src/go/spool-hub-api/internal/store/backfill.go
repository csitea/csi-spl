package store

import (
	"context"
	"time"
)

// Back-fill of a newly seated channel agent (SPL-987, specs/038 FR-020..,
// rdb 0066). An agent invited into a channel used to receive only the posts
// made AFTER the invite; the ones it was invited for never reached it. The
// hub now owes every invited seat one back-fill: the channel's recent posts,
// delivered to that agent alone, once.

// BackfillSeat is one invited agent seat whose back-fill is still owed.
type BackfillSeat struct {
	Channel string
	Box     string
	Agent   string
}

// BackfillMsg is one stored channel message a back-fill may deliver.
type BackfillMsg struct {
	MsgID      string
	TaskID     string
	FromID     string
	Env        []byte // canonical envelope bytes, forwarded unchanged
	ReceivedAt time.Time
}

// Backfills is the store side of the back-fill. Memory and Postgres
// implement it; the hub type-asserts it (a store without it back-fills
// nothing).
type Backfills interface {
	// PendingBackfills lists the invited seats of box whose back-fill is
	// still owed (backfilled_at NULL, origin invite, channel not deleted).
	PendingBackfills(ctx context.Context, tenantID, boxID string) ([]BackfillSeat, error)
	// ChannelBackfill returns the SIGNED messages of the channel's topics
	// that were active since `since` (any message of the topic received at
	// or after it), newest `limit` of them, oldest first. Expired and
	// archived rows are left out.
	ChannelBackfill(ctx context.Context, tenantID, channelID string, since, now time.Time, limit int) ([]BackfillMsg, error)
	// MarkBackfilled stamps the seat as done. A seat that is not pending
	// (already stamped, removed, or absent) is left alone.
	MarkBackfilled(ctx context.Context, tenantID, channelID, boxID, agentID string, now time.Time) error
}

var (
	_ Backfills = (*Memory)(nil)
	_ Backfills = (*Postgres)(nil)
)
