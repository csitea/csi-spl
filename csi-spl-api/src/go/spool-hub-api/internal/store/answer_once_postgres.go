package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0111. The check and the insert are one statement: the
// answered row is read FOR SHARE, so a claim (rdb 0110's UPDATE of
// responsible_gen) cannot move the lock between the check and the insert,
// and the primary key settles two answers racing on the same gen.
const claimAnswerSQL = `WITH tgt AS (
		SELECT coalesce(responsible, '') AS r, responsible_gen AS g FROM messages
		WHERE tenant_id = $1 AND msg_id = $2::uuid FOR SHARE),
	ins AS (
		INSERT INTO message_answers (tenant_id, answers, answer_msg_id, seat, gen, answered_at)
		SELECT $1, $2::uuid, $3::uuid, $4, $5, $6 FROM tgt WHERE r = $4 AND g = $5
		ON CONFLICT (tenant_id, answers) DO NOTHING RETURNING 1)
	SELECT EXISTS (SELECT 1 FROM tgt), coalesce((SELECT r FROM tgt), ''),
		coalesce((SELECT g FROM tgt), 0), EXISTS (SELECT 1 FROM ins)`

func (s *Postgres) ClaimAnswer(ctx context.Context, tenant string, a Answer) (Answer, error) {
	if err := checkTenant(tenant); err != nil {
		return Answer{}, err
	}
	if err := checkAnswer(a); err != nil {
		return Answer{}, err
	}
	a.AnsweredAt = a.AnsweredAt.UTC()
	var found, inserted bool
	var seat string
	var gen int64
	if err := s.queryRowTenant(ctx, tenant, claimAnswerSQL,
		[]any{tenant, a.Answers, a.AnswerMsgID, a.Seat, a.Gen, a.AnsweredAt},
		&found, &seat, &gen, &inserted); err != nil {
		return Answer{}, err
	}
	switch {
	case inserted:
		return a, nil
	case !found:
		return Answer{}, ErrNotFound
	}
	// Lost the key, or not the lock. A concurrent winner committed after this
	// statement's snapshot (ON CONFLICT waited for it), so read it afresh.
	var first Answer
	err := s.queryRowTenant(ctx, tenant, `SELECT answers::text, answer_msg_id::text, seat, gen, answered_at
		FROM message_answers WHERE tenant_id = $1 AND answers = $2::uuid`, []any{tenant, a.Answers},
		&first.Answers, &first.AnswerMsgID, &first.Seat, &first.Gen, &first.AnsweredAt)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return Answer{Answers: a.Answers, Seat: seat, Gen: gen}, ErrNotResponsible
	case err != nil:
		return Answer{}, err
	}
	first.AnsweredAt = first.AnsweredAt.UTC()
	if first.AnswerMsgID == a.AnswerMsgID {
		return first, nil
	}
	return first, ErrAnswered
}

func (s *Postgres) ReleaseAnswer(ctx context.Context, tenant, answers, answerMsgID string) error {
	_, err := s.execTenant(ctx, tenant, `DELETE FROM message_answers
		WHERE tenant_id = $1 AND answers = $2::uuid AND answer_msg_id = $3::uuid`, tenant, answers, answerMsgID)
	return err
}
