// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"
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

// ChannelMoveJournals is the journal of a move (rdb 0249, spec 169 section 8.3),
// the hub's step driver reads and writes through it (T7). Every row lives in
// <DST>. Only Postgres has it: P4 does too, so a Memory hub answers 501.
type ChannelMoveJournals interface {
	// OpenChannelMove is P1: it writes the journal row, or freezes the set again
	// on the open row of this GO, and answers the move id. Another GO on the open
	// row, or a P4 already done, is ErrConflict.
	OpenChannelMove(ctx context.Context, open ChannelMoveOpen) (string, error)
	// ChannelMoveJournal reads the newest journal of src/channel in dst; nil = none.
	ChannelMoveJournal(ctx context.Context, dst, src, channel string) (*ChannelMoveJournalRow, error)
	// StartChannelMoveStep marks a step running: done_at goes back to NULL, so a
	// step that dies is resumed (C17). detail, if not nil, is what it must not lose.
	StartChannelMoveStep(ctx context.Context, dst, moveID, channel, step string, detail any) error
	// FinishChannelMoveStep marks it done, with what it did.
	FinishChannelMoveStep(ctx context.Context, dst, moveID, channel, step string, done ChannelMoveStepDone) error
	// CloseChannelMove sets the journal's done_at, after P7 held.
	CloseChannelMove(ctx context.Context, dst, moveID string) error
	// ChannelMoveObjectLists are the set's objects as tenant's rows list them.
	ChannelMoveObjectLists(ctx context.Context, tenant string, msgs, docs []string) (ChannelMoveObjectList, error)
	// ChannelMoveLanes are src's live lanes on these issue keys. W4 reads them
	// BEFORE P4: after it a new key can equal a staying issue's key in <SRC>.
	ChannelMoveLanes(ctx context.Context, src string, keys []string) ([]ChannelMoveLane, error)
	// ChannelMoveProofRead runs fn in one READ ONLY transaction under the operator
	// scope, for the proofs of P7 (the store cannot import channelmove).
	ChannelMoveProofRead(ctx context.Context, fn func(pgx.Tx) error) error
}

var _ ChannelMoveJournals = (*Postgres)(nil)

// ChannelMoveOpen is P1's row. MoveID "" = the open row's, or a new one.
type ChannelMoveOpen struct {
	Dst, Src, Channel, MoveID, GoMsgID, StartedBy string
	Binds                                         ChannelMoveBinds
}

// ChannelMoveJournalRow is one journal with its steps.
type ChannelMoveJournalRow struct {
	MoveID, Src, Channel, GoMsgID string
	Frozen                        json.RawMessage
	Done                          bool
	Steps                         map[string]ChannelMoveStep
}

// StepDone says the step finished.
func (j ChannelMoveJournalRow) StepDone(step string) bool { return j.Steps[step].Done }

// ChannelMoveStep is one channel_move_steps row.
type ChannelMoveStep struct {
	Done                   bool
	Counts, Proofs, Detail json.RawMessage
}

// ChannelMoveStepDone is what a finished step writes; a nil field = {}.
type ChannelMoveStepDone struct {
	Counts, Proofs, Detail any
}

// ChannelMoveObjectList is M4 and M8, and M4's bytes for P2's quota check.
type ChannelMoveObjectList struct {
	Files, DocAssets []string
	FileBytes        int64
}

// ChannelMoveLane is one row of the journal's .lanes, the P5 note's input (W4).
// The caller fills NewKey from P4's map.
type ChannelMoveLane struct {
	Agent  string `json:"agent"`
	Topic  string `json:"topic"`
	OldKey string `json:"old_key"`
	NewKey string `json:"new_key,omitempty"`
}
