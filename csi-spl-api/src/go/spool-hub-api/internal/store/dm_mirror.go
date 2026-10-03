package store

import (
	"context"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 067 rules 3 and 4 (rdb 0112): a DM about a channel topic carries the
// topic's id (messages.ref_task_id), and a person's DM answer is also stored
// as a thread reply in that topic, the copy naming the DM (messages.mirror_of).
// The copy follows its DM: an edit or an archive of the DM is applied to the
// copy in the same transaction (edge case 3). Only the hub writes either.

// DMMirror is the store half of spec 067 L4. Postgres and Memory implement it.
type DMMirror interface {
	// DMRefTask is the ref_task_id of DM task taskID: the one its earliest
	// row carrying one names; "" = none. A DM reply inherits it.
	DMRefTask(ctx context.Context, tenantID, taskID string) (string, error)
	// InsertMirrored is InsertMessage for dm (InsertMessageSent when dmSent is
	// set) and, ONLY when dm is new, the insert of its channel copy cp with
	// cp's sent delivery row expiring at cpSent, in ONE transaction: the
	// answer is never stored without its copy, nor the copy without it. A
	// resend of dm stores no second copy; it answers as InsertMessage.
	InsertMirrored(ctx context.Context, dm Message, dmSent time.Time, cp Message, cpSent time.Time) (bool, error)
}

var (
	_ DMMirror = (*Memory)(nil)
	_ DMMirror = (*Postgres)(nil)
)

// mirrorEdit is the edit e of a DM as it applies to the DM's channel copy,
// whose envelope is copyEnv: the same body, editor and stamp, re-encoded into
// the copy's own (unsigned, box-wui) envelope.
func mirrorEdit(copyEnv []byte, e Edit) (Edit, error) {
	env, err := wire.ParseEnvelope(copyEnv)
	if err != nil {
		return Edit{}, err
	}
	inner, err := msg.Parse(env.Msg)
	if err != nil {
		return Edit{}, err
	}
	inner.Body = e.Body
	if env.Msg, err = msg.Canonical(inner); err != nil {
		return Edit{}, err
	}
	canon, err := env.Marshal()
	if err != nil {
		return Edit{}, err
	}
	return Edit{Body: e.Body, Msg: env.Msg, Env: canon, EditedBy: e.EditedBy, EditedAt: e.EditedAt}, nil
}

func (s *Memory) DMRefTask(_ context.Context, tenant, taskID string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var first *Message
	for k, m := range s.messages {
		if k[0] != tenant || m.TaskID != taskID || m.RefTaskID == "" || m.Channel != "" {
			continue
		}
		if first == nil || m.ReceivedAt.Before(first.ReceivedAt) ||
			(m.ReceivedAt.Equal(first.ReceivedAt) && m.MsgID < first.MsgID) {
			first = m
		}
	}
	if first == nil {
		return "", nil
	}
	return first.RefTaskID, nil
}

// InsertMirrored: see DMMirror. Memory has no sent delivery leg (it is not a
// SentInserter); the caller queues and claims both rows as for InsertMessage.
func (s *Memory) InsertMirrored(_ context.Context, dm Message, _ time.Time, cp Message, _ time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, taken := s.messages[[2]string{cp.TenantID, cp.MsgID}]; taken { // checked first: nothing to undo
		return false, ErrConflict
	}
	ok, err := s.insertMessageLocked(dm)
	if !ok || err != nil {
		return ok, err
	}
	return s.insertMessageLocked(cp)
}

// mirrorsLocked are the channel copies of msgID.
func (s *Memory) mirrorsLocked(tenant, msgID string) []*Message {
	var out []*Message
	for k, m := range s.messages {
		if k[0] == tenant && m.MirrorOf == msgID && m.MsgID != msgID {
			out = append(out, m)
		}
	}
	return out
}

// editMirrorsLocked applies the DM edit e to every copy of msgID.
func (s *Memory) editMirrorsLocked(tenant, msgID string, e Edit) {
	for _, m := range s.mirrorsLocked(tenant, msgID) {
		ce, err := mirrorEdit(m.Env, e)
		if err != nil { // a copy is hub-built; an envelope that does not parse keeps its old body
			continue
		}
		s.applyEditLocked(tenant, m.MsgID, ce)
	}
}

// archiveLocked is SetArchived's flag write on one row.
func archiveLocked(m *Message, by string, at time.Time, archived bool) {
	switch {
	case !archived:
		m.ArchivedAt, m.ArchivedBy = time.Time{}, ""
	case m.ArchivedAt.IsZero():
		m.ArchivedAt, m.ArchivedBy = at, by
	}
}
