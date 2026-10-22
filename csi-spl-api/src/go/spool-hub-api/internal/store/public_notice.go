package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// The #public notice (rdb 0173; owner, 2026-10-10, msg 69e2d25f: "always a
// new message which basically states that everything here is public and
// visible to the whole internet"). The hub posts it once per tenant, signed
// as box-wui (hub/public_notice.go). Its msg_id is fixed per tenant, so the
// messages primary key makes a second copy impossible.

// PublicNoticeBody is the notice's text.
const PublicNoticeBody = "**Everything posted in this channel is public and visible to the whole internet.**"

// PublicNoticeExpires is the notice's expires_at: the retention sweep never
// reaches it, so the notice stays as long as the channel does.
var PublicNoticeExpires = time.Date(9999, 12, 31, 0, 0, 0, 0, time.UTC)

// PublicNoticeID is the notice's msg_id (and task_id) in tenant: the first
// 128 bits of sha256("spool-public-notice:" + tenant) as a uuid, as rdb
// 0173's spool_public_notice_id computes it.
func PublicNoticeID(tenant string) string {
	h := sha256.Sum256([]byte("spool-public-notice:" + tenant))
	x := hex.EncodeToString(h[:])
	return x[0:8] + "-" + x[8:12] + "-" + x[12:16] + "-" + x[16:20] + "-" + x[20:32]
}

// PublicNotices lists the tenants whose #public notice is not stored, for
// the hub to post it. Postgres and Memory implement it.
type PublicNotices interface {
	TenantsMissingPublicNotice(ctx context.Context) ([]string, error)
}

// publicNoticeMissingSQL ($1: the system tenant) lists the tenants with no
// notice row. The ids are computed first (MATERIALIZED): under the operator
// RLS scope a key computed inside the probe by a non-leakproof function stays
// off the index, and the probe filtered the tenant's messages one by one (prd
// 2026-10-22, SPL-2868, n=3: 71..292 ms, 1 777 buffers -> 0.5..1.8 ms, 76; by
// TestMissingHubCardsProbeByPrimaryKey).
const publicNoticeMissingSQL = `WITH t AS MATERIALIZED (
		SELECT tenant_id, spool_public_notice_id(tenant_id) AS id FROM tenants WHERE tenant_id <> $1)
	SELECT t.tenant_id FROM t
	WHERE NOT EXISTS (SELECT 1 FROM messages m WHERE m.tenant_id = t.tenant_id AND m.msg_id = t.id)
	ORDER BY t.tenant_id`

// TenantsMissingPublicNotice is one operator read: a primary-key probe of
// messages per tenant, tenant ids in order.
func (s *Postgres) TenantsMissingPublicNotice(ctx context.Context) ([]string, error) {
	var out []string
	err := s.asOperatorQuery(ctx, publicNoticeMissingSQL, []any{SystemTenant}, func(r pgx.Rows) error {
		var id string
		if err := r.Scan(&id); err != nil {
			return err
		}
		out = append(out, id)
		return nil
	})
	return out, err
}

func (s *Memory) TenantsMissingPublicNotice(_ context.Context) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for id := range s.tenants {
		if _, ok := s.messages[[2]string{id, PublicNoticeID(id)}]; !ok {
			out = append(out, id)
		}
	}
	sort.Strings(out)
	return out, nil
}
