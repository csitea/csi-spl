package store

import (
	"context"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// Removing an attachment from the system (SPL-1560, owner HUM-10 t1
// d74ecae5: "remove attached images from the system, from message cards, from
// issues, from comments, everywhere where there are attachments").
//
// An attachment is a files[] entry on a message row (an issue comment is a
// message row, and an issue description's file rides on a note in its
// discussion, utils/issue-files.mjs). So removing it is: find every row that
// carries the file, rewrite each one without it, and delete the blob once no
// row carries it any more. The hub decides who may rewrite which row and
// re-signs the envelope; the store only finds the rows and writes the bytes.

// FileDetach is one row's new bytes with a file taken off: the inner object,
// the canonical envelope, its sig ("" keeps the stored env_sig) and the new
// files[] JSON (has_files follows it, rdb 0075).
type FileDetach struct {
	Msg    []byte
	Env    []byte
	EnvSig string
	Files  []byte
}

// FileDetacher is the store side. Memory and Postgres implement it.
type FileDetacher interface {
	// FileCarriers lists the msg_ids of every message in retention at now
	// that carries fileID (by file_id or sha256), oldest first. A DM's mirror
	// copy carries it too and is listed on its own.
	FileCarriers(ctx context.Context, tenantID, fileID string, now time.Time) ([]string, error)
	// DetachFile writes d onto one row. ErrNotFound when the row is gone.
	DetachFile(ctx context.Context, tenantID, msgID string, d FileDetach) error
}

var (
	_ FileDetacher = (*Memory)(nil)
	_ FileDetacher = (*Postgres)(nil)
)

// ---- Memory ---------------------------------------------------------------

func (s *Memory) FileCarriers(_ context.Context, tenant, fileID string, now time.Time) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var ms []*Message
	for _, m := range s.liveLocked(tenant, now) {
		if carriesFile(m.Files, fileID) {
			ms = append(ms, m)
		}
	}
	sort.Slice(ms, func(i, j int) bool { return newer(ms[j].ReceivedAt, ms[j].MsgID, ms[i].ReceivedAt, ms[i].MsgID) })
	out := make([]string, 0, len(ms))
	for _, m := range ms {
		out = append(out, m.MsgID)
	}
	return out, nil
}

func (s *Memory) DetachFile(_ context.Context, tenant, msgID string, d FileDetach) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.messages[[2]string{tenant, msgID}]
	if !ok {
		return ErrNotFound
	}
	m.Msg, m.Env, m.Files = d.Msg, d.Env, d.Files
	if d.EnvSig != "" {
		m.EnvSig = d.EnvSig
	}
	return nil
}

// ---- Postgres -------------------------------------------------------------

func (s *Postgres) FileCarriers(ctx context.Context, tenant, fileID string, now time.Time) ([]string, error) {
	out := []string{}
	err := s.queryTenant(ctx, tenant, `SELECT m.msg_id::text FROM messages m
		WHERE m.tenant_id = $1 AND m.expires_at > $3 AND `+fileCarrier+`
		ORDER BY m.received_at, m.msg_id`, []any{tenant, fileID, now},
		func(rows pgx.Rows) error {
			var id string
			if err := rows.Scan(&id); err != nil {
				return err
			}
			out = append(out, id)
			return nil
		})
	return out, err
}

func (s *Postgres) DetachFile(ctx context.Context, tenant, msgID string, d FileDetach) error {
	if !canonUUIDRe.MatchString(msgID) {
		return ErrNotFound
	}
	n := int64(0)
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE messages SET msg = $3::jsonb, env = $4, files = $5::jsonb,
			env_sig = COALESCE(NULLIF($6, ''), env_sig)
			WHERE tenant_id = $1 AND msg_id = $2`,
			tenant, msgID, string(d.Msg), d.Env, string(d.Files), d.EnvSig)
		if err != nil {
			return err
		}
		n = tag.RowsAffected()
		return nil
	})
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
