package store

import (
	"context"
	"time"
)

// UnsignedReplay is the store side of the operator replay of a workspace's
// unsigned browser posts (CLE-77876, prd 2026-10-01). A workspace without a
// box-wui pin gets every browser post stored UNSIGNED, and the hub fans an
// unsigned post out to no box: csitea's people posted for two days and no
// agent received a line. Once the pin is there, the replay re-signs those
// rows and routes them as if they had been signed at post time.
type UnsignedReplay interface {
	// UnsignedWUIPosts lists the unsigned human channel posts of box-wui
	// received at or after since, not expired or archived, oldest first, at
	// most limit of them.
	UnsignedWUIPosts(ctx context.Context, tenantID string, since, now time.Time, limit int) ([]UnsignedPost, error)
	// ResignMessage replaces a still-unsigned box-wui row's envelope with
	// its signed one. ok=false when the row is gone or already signed (a
	// second replay, or another hub process, got there first).
	ResignMessage(ctx context.Context, tenantID, msgID string, env []byte, sig string) (bool, error)
}

// UnsignedPost is one row UnsignedWUIPosts returns.
type UnsignedPost struct {
	MsgID      string
	Channel    string
	FromID     string
	Env        []byte
	ReceivedAt time.Time
}

var (
	_ UnsignedReplay = (*Memory)(nil)
	_ UnsignedReplay = (*Postgres)(nil)
)
