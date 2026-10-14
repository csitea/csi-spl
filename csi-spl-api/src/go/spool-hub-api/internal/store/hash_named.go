package store

import (
	"context"
	"encoding/json"
	"regexp"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// Naming the attachments still named by their own sha256 (SPL-1808): before
// SPL-1776 a blob attached by id was named by its 64-hex hash. A live box
// re-signs its own rows (spool attach-rename); the hub repairs the rows of a
// box whose pin is revoked (owner HUM-10, t1 b1af5f5c msg 8d4cf989: "Rename
// them on the hub; their old signature no longer matches"). This finds them.

// HashNamedFiles is the store side. Memory and Postgres implement it.
type HashNamedFiles interface {
	// HashNamedCarriers lists, oldest first and at most limit, the msg_ids of
	// the messages in retention at now whose files[] holds an attachment
	// named by its own lower-case 64-hex file_id or sha256.
	HashNamedCarriers(ctx context.Context, tenantID string, now time.Time, limit int) ([]string, error)
}

var (
	_ HashNamedFiles = (*Memory)(nil)
	_ HashNamedFiles = (*Postgres)(nil)
)

var hashNameRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// hasHashNamed: files JSON with an entry named by its own sha.
func hasHashNamed(files []byte) bool {
	var fs []struct {
		Name   string `json:"name"`
		FileID string `json:"file_id"`
		SHA256 string `json:"sha256"`
	}
	if json.Unmarshal(files, &fs) != nil {
		return false
	}
	for _, f := range fs {
		if hashNameRe.MatchString(f.Name) && (f.Name == f.FileID || f.Name == f.SHA256) {
			return true
		}
	}
	return false
}

func (s *Memory) HashNamedCarriers(_ context.Context, tenant string, now time.Time, limit int) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var ms []*Message
	for _, m := range s.liveLocked(tenant, now) {
		if hasHashNamed(m.Files) {
			ms = append(ms, m)
		}
	}
	sort.Slice(ms, func(i, j int) bool { return newer(ms[j].ReceivedAt, ms[j].MsgID, ms[i].ReceivedAt, ms[i].MsgID) })
	out := []string{}
	for _, m := range ms {
		if len(out) == limit {
			break
		}
		out = append(out, m.MsgID)
	}
	return out, nil
}

func (s *Postgres) HashNamedCarriers(ctx context.Context, tenant string, now time.Time, limit int) ([]string, error) {
	out := []string{}
	err := s.queryTenant(ctx, tenant, `SELECT m.msg_id::text FROM messages m
		WHERE m.tenant_id = $1 AND m.expires_at > $2 AND m.has_files
		  AND jsonb_typeof(m.files) = 'array'
		  AND EXISTS (SELECT 1 FROM jsonb_array_elements(m.files) f
		              WHERE f->>'name' ~ '^[0-9a-f]{64}$'
		                AND (f->>'name' = f->>'file_id' OR f->>'name' = f->>'sha256'))
		ORDER BY m.received_at, m.msg_id
		LIMIT $3`, []any{tenant, now, limit},
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
