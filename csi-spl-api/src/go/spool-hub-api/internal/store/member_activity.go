package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// MemberActivity is one member_activity row (rdb 0091, CLE-77799): a durable,
// tenant-scoped audit event ABOUT a member — a membership change (role change,
// removal) or, from the auth flow, a sign-in (with method) / sign-out / session
// expiry. It sits alongside member_clones (act-as, CLE-77797); the People-card
// Activity log unions the two.
//
// Privacy (owner rules): an auth row carries ONLY the event, time, method /
// outcome (Detail), a /24-masked IP and a coarse user agent (UA) — never a
// token, cookie, password, a full IP or a third party's email.
type MemberActivity struct {
	ActivityID int64
	TenantID   string
	SubjectHum string
	ActorHum   string
	Kind       string
	Detail     string
	IP         string
	UA         string
	CreatedAt  time.Time
}

// AppendMemberActivity records one event in the tenant's scope (RLS). Callers
// treat it as best-effort — a failure must never fail the operation it audits.
func (s *Postgres) AppendMemberActivity(ctx context.Context, a MemberActivity) error {
	_, err := s.execTenant(ctx, a.TenantID, `INSERT INTO member_activity
		(tenant_id, subject_hum, actor_hum, kind, detail, ip, ua, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		a.TenantID, a.SubjectHum, a.ActorHum, a.Kind, a.Detail, a.IP, a.UA, a.CreatedAt)
	return err
}

// ListMemberActivity is one member's audit trail, newest first (read behind
// audit.read or by the subject themself).
func (s *Postgres) ListMemberActivity(ctx context.Context, tenant, subject string) ([]MemberActivity, error) {
	out := []MemberActivity{}
	err := s.queryTenant(ctx, tenant, `SELECT activity_id, tenant_id, subject_hum, actor_hum, kind,
		detail, ip, ua, created_at FROM member_activity
		WHERE tenant_id = $1 AND subject_hum = $2 ORDER BY created_at DESC, activity_id DESC`, []any{tenant, subject},
		func(rows pgx.Rows) error {
			var a MemberActivity
			if err := rows.Scan(&a.ActivityID, &a.TenantID, &a.SubjectHum, &a.ActorHum, &a.Kind,
				&a.Detail, &a.IP, &a.UA, &a.CreatedAt); err != nil {
				return err
			}
			out = append(out, a)
			return nil
		})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// SweepMemberActivity prunes AUTH rows (sign_in / sign_out / session_expiry)
// older than before, across all tenants (operator scope, on the retention
// tick). Membership rows are kept — only the auth trail has the 90-day
// retention (owner rule). Returns the number deleted.
func (s *Postgres) SweepMemberActivity(ctx context.Context, before time.Time) (int, error) {
	n := 0
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM member_activity
			WHERE created_at < $1 AND kind IN ('sign_in', 'sign_out', 'session_expiry')`, before)
		if err != nil {
			return err
		}
		n = int(tag.RowsAffected())
		return nil
	})
	return n, err
}
