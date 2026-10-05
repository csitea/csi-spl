package store

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0131. The identity is read in the same INSERT: the
// display name from humans and the most recently used identity from
// human_identities (both hub-wide, no RLS), the email only when the
// provider verified it. A human with no rows still gets its audit row, with
// the identity fields empty: the post is recorded either way.
const appendDemoAuditSQL = `INSERT INTO demo_post_audit (tenant_id, at, action, human_id, pseudonym,
	provider, subject, email, msg_id, task_id, channel, to_id, body)
	SELECT $1, $2, $3, $4, COALESCE(h.display_name, ''), COALESCE(i.provider, ''), COALESCE(i.subject, ''),
	       COALESCE(CASE WHEN i.email_verified THEN i.email END, ''), $5, $6, $7, $8, $9
	  FROM (SELECT 1) one
	  LEFT JOIN humans h ON h.human_id = $4
	  LEFT JOIN LATERAL (SELECT provider, subject, email, email_verified FROM human_identities
	                      WHERE human_id = $4
	                      ORDER BY last_login_at DESC NULLS LAST, created_at DESC, provider, subject
	                      LIMIT 1) i ON true
	ON CONFLICT (tenant_id, msg_id) WHERE action = 'post' DO NOTHING`

func (s *Postgres) AppendDemoAudit(ctx context.Context, e DemoAudit) error {
	if err := checkDemoAudit(e); err != nil {
		return err
	}
	_, err := s.execTenant(ctx, e.TenantID, appendDemoAuditSQL, e.TenantID, e.At.UTC(), e.Action, e.HumanID,
		e.MsgID, e.TaskID, e.Channel, e.To, e.Body)
	return err
}

func (s *Postgres) DemoAuditRows(ctx context.Context, tenant string, before int64, limit int) ([]DemoAudit, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	var out []DemoAudit
	err := s.queryTenant(ctx, tenant, `SELECT audit_id, at, tenant_id, action, human_id, pseudonym, provider,
		subject, email, msg_id::text, task_id, channel, to_id, body FROM demo_post_audit
		WHERE tenant_id = $1 AND ($2 <= 0 OR audit_id < $2) ORDER BY audit_id DESC LIMIT $3`,
		[]any{tenant, before, demoAuditLimit(limit)}, func(rows pgx.Rows) error {
			var r DemoAudit
			if err := rows.Scan(&r.ID, &r.At, &r.TenantID, &r.Action, &r.HumanID, &r.Pseudonym, &r.Provider,
				&r.Subject, &r.Email, &r.MsgID, &r.TaskID, &r.Channel, &r.To, &r.Body); err != nil {
				return err
			}
			out = append(out, r)
			return nil
		})
	return out, err
}
