package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Message moderation (rdb 0128, specs/077 3.6 T016 part A). A report is a
// reaction (message_reactions, the hub's report glyph), so one reporter
// counts once; message_moderation holds the decision per message. The hub
// reads it only for the demo workspace (hub/demo_moderation.go).

// ModerationByReports is set_by of a hide the reports made, not a person.
const ModerationByReports = "reports"

// HiddenMessage is one hidden, live message: where it lives and its body, so
// the hub can also drop a topic row whose subject is that body.
type HiddenMessage struct {
	MsgID, TaskID, Body string
	SetBy               string
	SetAt               time.Time
}

// MessageModeration is implemented by Memory and Postgres.
type MessageModeration interface {
	// ReportHide hides msgID, set_by ModerationByReports, when at least
	// threshold distinct actors hold emoji on it AND no decision exists yet
	// (a moderator's unhide sticks). true = this call hid it. Never
	// ErrNotFound: a message that is gone has no reports to count.
	ReportHide(ctx context.Context, tenant, msgID, emoji string, threshold int, now time.Time) (bool, error)
	// SetHidden is a moderator's decision: hidden or not, by whom, replacing
	// any earlier one. ErrNotFound when the message is gone or past retention.
	SetHidden(ctx context.Context, tenant, msgID string, hidden bool, by string, now time.Time) error
	// HiddenMessages is every hidden message of tenant still live at now,
	// keyed by msg id.
	HiddenMessages(ctx context.Context, tenant string, now time.Time) (map[string]HiddenMessage, error)
}

var (
	_ MessageModeration = (*Memory)(nil)
	_ MessageModeration = (*Postgres)(nil)
)

type memModeration struct {
	hidden bool
	by     string
	at     time.Time
}

// Memory side: a per-store map beside the Memory struct, guarded by s.mu.
var memModerations = map[*Memory]map[[2]string]memModeration{}

func (s *Memory) ReportHide(_ context.Context, tenant, msgID, emoji string, threshold int, now time.Time) (bool, error) {
	if err := checkTenant(tenant); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, msgID}
	if m, ok := s.messages[k]; !ok || !m.ExpiresAt.After(now) {
		return false, nil
	}
	n := 0
	for _, r := range s.reactions[k] {
		if r.emoji == emoji {
			n++
		}
	}
	rows := s.moderations()
	if _, decided := rows[k]; decided || n < threshold {
		return false, nil
	}
	rows[k] = memModeration{hidden: true, by: ModerationByReports, at: now}
	return true, nil
}

func (s *Memory) SetHidden(_ context.Context, tenant, msgID string, hidden bool, by string, now time.Time) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k := [2]string{tenant, msgID}
	if m, ok := s.messages[k]; !ok || !m.ExpiresAt.After(now) {
		return ErrNotFound
	}
	s.moderations()[k] = memModeration{hidden: hidden, by: by, at: now}
	return nil
}

func (s *Memory) HiddenMessages(_ context.Context, tenant string, now time.Time) (map[string]HiddenMessage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]HiddenMessage{}
	for k, d := range memModerations[s] {
		m, ok := s.messages[k] // a deleted message takes its decision with it
		if k[0] != tenant || !d.hidden || !ok || !m.ExpiresAt.After(now) {
			continue
		}
		out[k[1]] = HiddenMessage{MsgID: k[1], TaskID: m.TaskID, Body: m.Body, SetBy: d.by, SetAt: d.at}
	}
	return out, nil
}

// moderations is this store's decision map, made on first use. Caller holds s.mu.
func (s *Memory) moderations() map[[2]string]memModeration {
	rows := memModerations[s]
	if rows == nil {
		rows = map[[2]string]memModeration{}
		memModerations[s] = rows
	}
	return rows
}

// Postgres side: one statement each, in the tenant scope.

func (s *Postgres) ReportHide(ctx context.Context, tenant, msgID, emoji string, threshold int, now time.Time) (bool, error) {
	if !canonUUIDRe.MatchString(msgID) {
		return false, nil
	}
	var hid bool
	err := s.queryRowTenant(ctx, tenant, `WITH n AS (
			SELECT count(*) AS c FROM message_reactions r
			JOIN messages m ON m.tenant_id = r.tenant_id AND m.msg_id = r.msg_id AND m.expires_at > $5
			WHERE r.tenant_id = $1 AND r.msg_id = $2 AND r.emoji = $3
		), ins AS (
			INSERT INTO message_moderation (tenant_id, msg_id, hidden, set_by, set_at)
			SELECT $1, $2, true, $6, $5 FROM n WHERE n.c >= $4
			ON CONFLICT DO NOTHING
			RETURNING 1
		)
		SELECT EXISTS (SELECT 1 FROM ins)`, []any{tenant, msgID, emoji, threshold, now, ModerationByReports}, &hid)
	return hid, err
}

func (s *Postgres) SetHidden(ctx context.Context, tenant, msgID string, hidden bool, by string, now time.Time) error {
	if !canonUUIDRe.MatchString(msgID) {
		return ErrNotFound
	}
	var live bool
	err := s.queryRowTenant(ctx, tenant, `WITH m AS (
			SELECT 1 FROM messages WHERE tenant_id = $1 AND msg_id = $2 AND expires_at > $5
		), up AS (
			INSERT INTO message_moderation (tenant_id, msg_id, hidden, set_by, set_at)
			SELECT $1, $2, $3, $4, $5 FROM m
			ON CONFLICT (tenant_id, msg_id) DO UPDATE
			SET hidden = EXCLUDED.hidden, set_by = EXCLUDED.set_by, set_at = EXCLUDED.set_at
		)
		SELECT EXISTS (SELECT 1 FROM m)`, []any{tenant, msgID, hidden, by, now}, &live)
	if err != nil {
		return err
	}
	if !live {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) HiddenMessages(ctx context.Context, tenant string, now time.Time) (map[string]HiddenMessage, error) {
	out := map[string]HiddenMessage{}
	err := s.queryTenant(ctx, tenant, `SELECT d.msg_id::text, m.task_id::text, m.body, d.set_by, d.set_at
		FROM message_moderation d
		JOIN messages m ON m.tenant_id = d.tenant_id AND m.msg_id = d.msg_id AND m.expires_at > $2
		WHERE d.tenant_id = $1 AND d.hidden`, []any{tenant, now}, func(rows pgx.Rows) error {
		var h HiddenMessage
		if err := rows.Scan(&h.MsgID, &h.TaskID, &h.Body, &h.SetBy, &h.SetAt); err != nil {
			return err
		}
		out[h.MsgID] = h
		return nil
	})
	return out, err
}
