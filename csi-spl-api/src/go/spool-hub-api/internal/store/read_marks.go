package store

import (
	"context"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// ReadMarks keeps a member's read position per channel, thread and DM on the
// hub (rdb 0098, CLE-77930), so what they have seen follows them across
// devices and tabs instead of living in one browser's storage. A key is the
// WUI cursor key: ch:<channel>, t:<task_id> or dm:<peer>.
type ReadMarks interface {
	// ReadMarksOf is every mark the member has in the tenant.
	ReadMarksOf(ctx context.Context, tenant, humanID string) (map[string]ReadMark, error)
	// SaveReadMarks moves marks forward: a key's (At, MsgID) only ever grows
	// and Seen only ever rises, so an older device's write never rewinds a
	// newer one. The caller validated the keys (ValidReadMarkKey).
	SaveReadMarks(ctx context.Context, tenant, humanID string, marks map[string]ReadMark, now time.Time) error
}

var (
	_ ReadMarks = (*Memory)(nil)
	_ ReadMarks = (*Postgres)(nil)
)

// MaxReadMarks bounds one write: a sync sends the keys that moved.
const MaxReadMarks = 200

var readMarkKeyRe = regexp.MustCompile(`^(ch|t|dm):[^\s]{1,200}$`)

// ValidReadMarkKey: ch:/t:/dm: and 1..200 non-space characters (rdb 0098 CHECK).
func ValidReadMarkKey(k string) bool { return readMarkKeyRe.MatchString(k) }

// ThreadMarkKey is the read_marks key of a thread.
func ThreadMarkKey(taskID string) string { return "t:" + taskID }

// forward is mark b moved forward by a: the later (At, MsgID), the higher Seen.
func forward(b, a ReadMark) ReadMark {
	out := b
	if newer(a.At, a.MsgID, b.At, b.MsgID) {
		out.At, out.MsgID = a.At, a.MsgID
	}
	out.Seen = max(b.Seen, a.Seen)
	return out
}

func (s *Memory) ReadMarksOf(_ context.Context, tenant, humanID string) (map[string]ReadMark, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]ReadMark{}
	for k, m := range s.readMarks {
		if k[0] == tenant && k[1] == humanID {
			out[k[2]] = m
		}
	}
	return out, nil
}

func (s *Memory) SaveReadMarks(_ context.Context, tenant, humanID string, marks map[string]ReadMark, _ time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.readMarks == nil {
		s.readMarks = map[[3]string]ReadMark{}
	}
	for key, m := range marks {
		k := [3]string{tenant, humanID, key}
		if was, ok := s.readMarks[k]; ok {
			m = forward(was, m)
		}
		s.readMarks[k] = m
	}
	return nil
}

func (s *Postgres) ReadMarksOf(ctx context.Context, tenant, humanID string) (map[string]ReadMark, error) {
	out := map[string]ReadMark{}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT mark_key, at, msg_id, seen FROM read_marks WHERE tenant_id = $1 AND member_id = $2`, tenant, humanID)
		if err != nil {
			return err
		}
		return scanRows(rows, func(r pgx.Rows) error {
			var k string
			var m ReadMark
			if err := r.Scan(&k, &m.At, &m.MsgID, &m.Seen); err != nil {
				return err
			}
			out[k] = m
			return nil
		})
	})
	return out, err
}

func (s *Postgres) SaveReadMarks(ctx context.Context, tenant, humanID string, marks map[string]ReadMark, now time.Time) error {
	if len(marks) == 0 {
		return nil
	}
	keys := make([]string, 0, len(marks))
	ats := make([]time.Time, 0, len(marks))
	ids := make([]string, 0, len(marks))
	seen := make([]int32, 0, len(marks))
	for k, m := range marks {
		keys, ats, ids, seen = append(keys, k), append(ats, m.At), append(ids, strings.TrimSpace(m.MsgID)), append(seen, int32(max(0, m.Seen)))
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO read_marks (tenant_id, member_id, mark_key, at, msg_id, seen, updated_at)
			SELECT $1, $2, k, a, i, n, $7 FROM unnest($3::text[], $4::timestamptz[], $5::text[], $6::int[]) AS u(k, a, i, n)
			ON CONFLICT (tenant_id, member_id, mark_key) DO UPDATE SET
				at = CASE WHEN (EXCLUDED.at, EXCLUDED.msg_id) > (read_marks.at, read_marks.msg_id) THEN EXCLUDED.at ELSE read_marks.at END,
				msg_id = CASE WHEN (EXCLUDED.at, EXCLUDED.msg_id) > (read_marks.at, read_marks.msg_id) THEN EXCLUDED.msg_id ELSE read_marks.msg_id END,
				seen = GREATEST(read_marks.seen, EXCLUDED.seen),
				updated_at = EXCLUDED.updated_at`,
			tenant, humanID, keys, ats, ids, seen, now)
		return err
	})
}
