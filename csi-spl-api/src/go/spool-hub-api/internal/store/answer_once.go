package store

import (
	"context"
	"errors"
	"strings"
	"time"
)

// Answer once (spec 068 section 4.2, rdb 0111): four peers per box share
// every message, the message's lock (rdb 0110: responsible, responsible_gen)
// decides WHO answers it, and this guard makes the answer happen once. An
// agent post that answers a message is accepted only from the message's
// responsible seat on its current gen, and only the first time.

// ErrAnswered: the message already has an answer; ClaimAnswer returns it.
var ErrAnswered = errors.New("already answered")

// ErrNotResponsible: the seat or gen is not the message's current lock;
// ClaimAnswer returns the current Seat and Gen.
var ErrNotResponsible = errors.New("not the responsible seat")

// AnswerSeatMax is rdb 0111's seat length cap.
const AnswerSeatMax = 100

// Answer is one row of message_answers: AnswerMsgID answered Answers, posted
// by Seat (<id>@<box>) while it held the message on Gen.
type Answer struct {
	Answers     string
	AnswerMsgID string
	Seat        string
	Gen         int64
	AnsweredAt  time.Time
}

// AnswerOnce is the store half of spec 068 4.2. Optional: the hub refuses an
// answers= post on a store without it.
type AnswerOnce interface {
	// ClaimAnswer records a as THE answer to a.Answers, in one statement:
	//   - ErrNotFound: no such message in tenant;
	//   - ErrAnswered: another post answered it first (that one is returned);
	//   - ErrNotResponsible: a.Seat / a.Gen is not the message's current
	//     responsible / responsible_gen (those are returned);
	//   - nil: recorded, or a.AnswerMsgID already is the answer (a resend).
	ClaimAnswer(ctx context.Context, tenant string, a Answer) (Answer, error)
	// ReleaseAnswer drops the row only while answerMsgID is the answer: the
	// undo when the answering post itself was not stored.
	ReleaseAnswer(ctx context.Context, tenant, answers, answerMsgID string) error
}

// checkAnswer is the Go side of rdb 0111's CHECKs, run by both stores before
// they touch a row. The messages are a backstop, not the client's answer: the
// hub (internal/hub/answer_once.go) refuses a missing or self-referencing
// answers and a negative if_gen with its own 400 first, so an error from here
// reaching the hub is logged and answered as 500 "answer not recorded".
func checkAnswer(a Answer) error {
	switch {
	case a.Answers == "" || a.AnswerMsgID == "":
		return errors.New("answers and the answering msg_id are required")
	case a.Answers == a.AnswerMsgID:
		return errors.New("a message cannot answer itself")
	case len(a.Seat) > AnswerSeatMax || !strings.Contains(strings.Trim(a.Seat, "@"), "@"):
		return errors.New("seat must be <id>@<box>")
	case a.Gen < 0:
		return errors.New("gen must be >= 0")
	}
	return nil
}

// Memory side: a per-store map beside the Memory struct, guarded by s.mu
// (the lock that guards s.messages, so the check and the write are one step).
var memAnswers = map[*Memory]map[[2]string]Answer{}

func (s *Memory) ClaimAnswer(_ context.Context, tenant string, a Answer) (Answer, error) {
	if err := checkTenant(tenant); err != nil {
		return Answer{}, err
	}
	if err := checkAnswer(a); err != nil {
		return Answer{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, a.Answers}
	m, ok := s.messages[k]
	if !ok {
		return Answer{}, ErrNotFound
	}
	rows := memAnswers[s]
	if rows == nil {
		rows = map[[2]string]Answer{}
		memAnswers[s] = rows
	}
	if first, ok := rows[k]; ok {
		if first.AnswerMsgID == a.AnswerMsgID {
			return first, nil
		}
		return first, ErrAnswered
	}
	if m.Responsible != a.Seat || m.ResponsibleGen != a.Gen {
		return Answer{Answers: a.Answers, Seat: m.Responsible, Gen: m.ResponsibleGen}, ErrNotResponsible
	}
	a.AnsweredAt = a.AnsweredAt.UTC()
	rows[k] = a
	return a, nil
}

func (s *Memory) ReleaseAnswer(_ context.Context, tenant, answers, answerMsgID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, answers}
	if a, ok := memAnswers[s][k]; ok && a.AnswerMsgID == answerMsgID {
		delete(memAnswers[s], k)
	}
	return nil
}
