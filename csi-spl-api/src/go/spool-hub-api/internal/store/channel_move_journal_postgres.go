// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// TaskMoveState is one statement, one round trip: the send path spends it in
// place of TaskFirstChannel.
func (s *Postgres) TaskMoveState(ctx context.Context, tenant, taskID string) (TaskMoveState, error) {
	var out TaskMoveState
	var dst, ref, move *string
	var expires *time.Time
	err := s.queryRowTenant(ctx, tenant, `SELECT COALESCE(f.channel, ''), f.task_id IS NOT NULL,
			r.dst_tenant_id, r.new_ref, r.move_id::text, r.expires_at
		FROM (SELECT 1) one
		LEFT JOIN LATERAL (SELECT channel, task_id FROM messages WHERE tenant_id = $1 AND task_id = $2::uuid
			ORDER BY received_at, msg_id LIMIT 1) f ON true
		LEFT JOIN channel_move_redirects r ON r.src_tenant_id = $1 AND r.kind = 'task' AND r.old_ref = $3`,
		[]any{tenant, taskID, taskID}, &out.FirstChannel, &out.HasRows, &dst, &ref, &move, &expires)
	if err != nil {
		return TaskMoveState{}, err
	}
	if dst != nil {
		out.Redirect = &ChannelMoveRedirect{Dst: *dst, NewRef: *ref, MoveID: *move, ExpiresAt: expires.UTC()}
	}
	return out, nil
}

// IssueMoves implements IssueMoves: one read in <SRC>'s scope.
func (s *Postgres) IssueMoves(ctx context.Context, tenant string) ([]IssueMove, error) {
	out := []IssueMove{}
	err := s.queryTenant(ctx, tenant, `SELECT old_ref, dst_tenant_id, new_ref, expires_at FROM channel_move_redirects
		WHERE src_tenant_id = $1 AND kind = 'issue' ORDER BY old_ref`, []any{tenant}, func(r pgx.Rows) error {
		var m IssueMove
		if err := r.Scan(&m.OldKey, &m.Dst, &m.NewKey, &m.ExpiresAt); err != nil {
			return err
		}
		m.ExpiresAt = m.ExpiresAt.UTC()
		out = append(out, m)
		return nil
	})
	return out, err
}

// MessageCopied reads messages.copied_from; a row not there is not a copy.
func (s *Postgres) MessageCopied(ctx context.Context, tenant, msgID string) (bool, error) {
	var copied bool
	err := s.queryRowTenant(ctx, tenant, `SELECT EXISTS (SELECT 1 FROM messages WHERE tenant_id = $1 AND msg_id = $2::uuid AND copied_from IS NOT NULL)`,
		[]any{tenant, msgID}, &copied)
	return copied, err
}

// OpenChannelMove implements ChannelMoveJournals. Nothing of <SRC> is written.
func (s *Postgres) OpenChannelMove(ctx context.Context, open ChannelMoveOpen) (string, error) {
	frozen, err := json.Marshal(mvJournalBinds(open.Binds))
	if err != nil {
		return "", err
	}
	j, err := s.ChannelMoveJournal(ctx, open.Dst, open.Src, open.Channel)
	if err != nil {
		return "", err
	}
	id := open.MoveID
	switch {
	case j != nil && j.StepDone("P4"):
		return "", fmt.Errorf("move %s: P4 is already done: %w", j.MoveID, ErrConflict)
	case j != nil && !strings.EqualFold(j.GoMsgID, open.GoMsgID):
		return "", fmt.Errorf("move %s: its journal row has another GO: %w", j.MoveID, ErrConflict)
	case j != nil && id != "" && id != j.MoveID:
		return "", fmt.Errorf("move %s is the open one, not %s: %w", j.MoveID, id, ErrConflict)
	case j != nil:
		id = j.MoveID
	case id == "":
		id = uuid.NewString()
	}
	err = s.inTenant(ctx, open.Dst, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO channel_move_journal (tenant_id, move_id, mode, src_tenant_id, src_channel_id, channel_id, frozen, go_msg_id, started_by)
			VALUES ($1, $2::uuid, 'move', $3, $4, $4, $5::jsonb, $6::uuid, $7)
			ON CONFLICT (tenant_id, move_id) DO UPDATE SET frozen = EXCLUDED.frozen`,
			open.Dst, id, open.Src, open.Channel, string(frozen), open.GoMsgID, open.StartedBy); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO channel_move_steps (tenant_id, move_id, channel_id, step, done_at)
			VALUES ($1, $2::uuid, $3, 'P1', clock_timestamp())
			ON CONFLICT (tenant_id, move_id, step) DO UPDATE SET done_at = EXCLUDED.done_at`, open.Dst, id, open.Channel)
		return err
	})
	return id, err
}

// ChannelMoveJournal implements ChannelMoveJournals.
func (s *Postgres) ChannelMoveJournal(ctx context.Context, dst, src, channel string) (*ChannelMoveJournalRow, error) {
	j := ChannelMoveJournalRow{Src: src, Channel: channel, Steps: map[string]ChannelMoveStep{}}
	err := s.queryRowTenant(ctx, dst, `SELECT move_id::text, go_msg_id::text, frozen, done_at IS NOT NULL FROM channel_move_journal
		WHERE tenant_id = $1 AND src_tenant_id = $2 AND src_channel_id = $3 ORDER BY created_at DESC, move_id LIMIT 1`,
		[]any{dst, src, channel}, &j.MoveID, &j.GoMsgID, &j.Frozen, &j.Done)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	err = s.queryTenant(ctx, dst, `SELECT step, done_at, counts, proofs, detail FROM channel_move_steps
		WHERE tenant_id = $1 AND move_id = $2::uuid`, []any{dst, j.MoveID}, func(r pgx.Rows) error {
		var step string
		var st ChannelMoveStep
		var at *time.Time
		if err := r.Scan(&step, &at, &st.Counts, &st.Proofs, &st.Detail); err != nil {
			return err
		}
		if st.Done = at != nil; st.Done {
			st.DoneAt = *at
		}
		j.Steps[step] = st
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &j, nil
}

// StartChannelMoveStep implements ChannelMoveJournals.
func (s *Postgres) StartChannelMoveStep(ctx context.Context, dst, moveID, channel, step string, detail any) error {
	d, err := mvStepJSON(detail)
	if err != nil {
		return err
	}
	return s.inTenant(ctx, dst, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO channel_move_steps (tenant_id, move_id, channel_id, step, started_at, detail)
			VALUES ($1, $2::uuid, $3, $4, clock_timestamp(), $5::jsonb)
			ON CONFLICT (tenant_id, move_id, step) DO UPDATE SET started_at = EXCLUDED.started_at, done_at = NULL, detail = EXCLUDED.detail`,
			dst, moveID, channel, step, d)
		return err
	})
}

// mvStepJSON is a step's column: a nil field, or a nil map in it, stays {}.
func mvStepJSON(v any) (string, error) {
	b, err := json.Marshal(v)
	if err != nil || string(b) == "null" {
		return "{}", err
	}
	return string(b), nil
}

// FinishChannelMoveStep implements ChannelMoveJournals.
func (s *Postgres) FinishChannelMoveStep(ctx context.Context, dst, moveID, channel, step string, done ChannelMoveStepDone) error {
	counts, err := mvStepJSON(done.Counts)
	if err != nil {
		return err
	}
	proofs, err := mvStepJSON(done.Proofs)
	if err != nil {
		return err
	}
	detail, err := mvStepJSON(done.Detail)
	if err != nil {
		return err
	}
	return s.inTenant(ctx, dst, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO channel_move_steps (tenant_id, move_id, channel_id, step, counts, proofs, detail, done_at)
			VALUES ($1, $2::uuid, $3, $4, $5::jsonb, $6::jsonb, $7::jsonb, clock_timestamp())
			ON CONFLICT (tenant_id, move_id, step) DO UPDATE SET counts = EXCLUDED.counts, proofs = EXCLUDED.proofs,
				detail = EXCLUDED.detail, done_at = EXCLUDED.done_at`, dst, moveID, channel, step, counts, proofs, detail)
		return err
	})
}

// CloseChannelMove implements ChannelMoveJournals.
func (s *Postgres) CloseChannelMove(ctx context.Context, dst, moveID string) error {
	return s.inTenant(ctx, dst, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE channel_move_journal SET done_at = clock_timestamp() WHERE tenant_id = $1 AND move_id = $2::uuid`, dst, moveID)
		return err
	})
}

// ChannelMoveObjectLists implements ChannelMoveJournals: planFilesSQL's rows with
// their sizes, and the sha256 ids the docs' root items name in attrs.assets.
func (s *Postgres) ChannelMoveObjectLists(ctx context.Context, tenant string, msgs, docs []string) (ChannelMoveObjectList, error) {
	out := ChannelMoveObjectList{Files: []string{}, DocAssets: []string{}}
	err := s.queryTenant(ctx, tenant, `SELECT f->>'file_id', max(CASE WHEN f->>'bytes' ~ '^[0-9]+$' THEN (f->>'bytes')::bigint ELSE 0 END) FROM messages m
		CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(m.files) = 'array' THEN m.files ELSE '[]'::jsonb END) f
		WHERE f->>'mode' = 'blob' AND coalesce(f->>'file_id', '') <> '' AND m.tenant_id = $1 AND m.msg_id = ANY($2::uuid[]) GROUP BY 1 ORDER BY 1`,
		[]any{tenant, mpNonNil(msgs)}, func(r pgx.Rows) error {
			var id string
			var n int64
			err := r.Scan(&id, &n)
			out.Files = append(out.Files, id)
			out.FileBytes += n
			return err
		})
	if err != nil {
		return out, err
	}
	err = s.queryTenant(ctx, tenant, `SELECT DISTINCT a.value FROM workspace_doc_item i,
		jsonb_each_text(CASE WHEN jsonb_typeof(i.attrs->'assets') = 'object' THEN i.attrs->'assets' ELSE '{}'::jsonb END) a
		WHERE i.tenant_id = $1 AND i.parent_id IS NULL AND i.doc_id = ANY($2::uuid[]) ORDER BY 1`,
		[]any{tenant, mpNonNil(docs)}, func(r pgx.Rows) error {
			var id string
			err := r.Scan(&id)
			out.DocAssets = append(out.DocAssets, id)
			return err
		})
	return out, err
}

// ChannelMoveLanes implements ChannelMoveJournals.
func (s *Postgres) ChannelMoveLanes(ctx context.Context, src string, keys []string) ([]ChannelMoveLane, error) {
	out := []ChannelMoveLane{}
	err := s.queryTenant(ctx, src, `SELECT agent_id, topic, issue_key FROM fleet_lanes
		WHERE tenant_id = $1 AND state = 'live' AND issue_key = ANY($2::text[]) ORDER BY 1, 3`,
		[]any{src, mpNonNil(keys)}, func(r pgx.Rows) error {
			var l ChannelMoveLane
			err := r.Scan(&l.Agent, &l.Topic, &l.OldKey)
			out = append(out, l)
			return err
		})
	return out, err
}

// ChannelMoveProofRead implements ChannelMoveJournals. The scan reads every
// column of every table: the runtime login's 30 s ceiling (SPL-984) is P4's too.
func (s *Postgres) ChannelMoveProofRead(ctx context.Context, fn func(pgx.Tx) error) error {
	return s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SET LOCAL statement_timeout = '`+channelMoveTimeout+`'`); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `SET TRANSACTION READ ONLY`); err != nil {
			return err
		}
		return fn(tx)
	})
}
