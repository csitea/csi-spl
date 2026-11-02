// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"time"
)

// ChannelMoveRedirect is one channel_move_redirects row of a moved task (rdb
// 0249, spec 169 Q2 = A): the workspace it went to and the same uuid there.
// Past ExpiresAt it redirects nothing, but it still refuses: a post to a moved
// task must never open a new <SRC> topic (C8).
type ChannelMoveRedirect struct {
	Dst, NewRef, MoveID string
	ExpiresAt           time.Time
}

// Live says the row still redirects.
func (r ChannelMoveRedirect) Live(now time.Time) bool { return now.Before(r.ExpiresAt) }

// TaskMoveState is what the send path learns of a task in one read: the
// channel of its earliest row, whether it has rows, and its redirect row.
type TaskMoveState struct {
	FirstChannel string
	HasRows      bool
	Redirect     *ChannelMoveRedirect
}

// Moved is the redirect of a task that has left: its rows are gone. A task
// with rows here is at home whatever the table says (it moved back).
func (t TaskMoveState) Moved() *ChannelMoveRedirect {
	if t.HasRows {
		return nil
	}
	return t.Redirect
}

// ChannelMoveRedirects reads the redirect of a moved task in <SRC>'s own scope
// (the table's src_read policy). TaskMoveState answers TaskFirstChannel's
// question too, so the send path spends one read, not two.
type ChannelMoveRedirects interface {
	TaskMoveState(ctx context.Context, tenant, taskID string) (TaskMoveState, error)
	// MessageCopied says a stored row is a copy (messages.copied_from, rdb 0250).
	MessageCopied(ctx context.Context, tenant, msgID string) (bool, error)
}

var (
	_ ChannelMoveRedirects = (*Postgres)(nil)
	_ ChannelMoveRedirects = (*Memory)(nil)
)
