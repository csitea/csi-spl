package store

import (
	"context"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 154 B6 (section 2.4, cases C13-C13e): the member match of a page of
// contacts. A contact's address names a member of the session's workspace
// only through a VERIFIED identity (human_identities.email with
// email_verified, P5): humans.email is informational and never matches
// (C13b). The read runs in the workspace scope, never in the person scope:
// the hub reads the contacts first (inPerson), then calls this in its own
// transaction (1.2 row 26), so personal_scope_test's realmTenantCallers
// stays empty. The file name does not start with "personal" on purpose: it
// is workspace code, not realm code.

// ContactMembers is implemented by Memory and Postgres.
type ContactMembers interface {
	// MembersByVerifiedEmail answers, for each address of emails that is a
	// verified identity of a member of tenant, that member's human id, keyed
	// by the lower-cased address. Not a member: a channel guest, a
	// technical human, a disabled human or a suspended membership. An
	// address of no member is absent, whether or not it is a human
	// elsewhere (C13c). One query for the whole page (C13e); no addresses,
	// no query.
	MembersByVerifiedEmail(ctx context.Context, tenant string, emails []string) (map[string]string, error)
}

var (
	_ ContactMembers = (*Memory)(nil)
	_ ContactMembers = (*Postgres)(nil)
)

// contactMatchKeys is emails lower-cased, trimmed, without "" and duplicates.
func contactMatchKeys(emails []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, e := range emails {
		e = strings.ToLower(strings.TrimSpace(e))
		if e != "" && !seen[e] {
			seen[e] = true
			out = append(out, e)
		}
	}
	return out
}

// MembersByVerifiedEmail is ContactMembers' match over the in-memory
// identities and memberships.
func (s *Memory) MembersByVerifiedEmail(_ context.Context, tenant string, emails []string) (map[string]string, error) {
	keys := contactMatchKeys(emails)
	out := map[string]string{}
	if len(keys) == 0 {
		return out, nil
	}
	want := map[string]bool{}
	for _, k := range keys {
		want[k] = true
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hum.init()
	// The identities map has no order: walk it by human id, so the lowest
	// one wins when two humans carry one verified address. Postgres breaks
	// that tie by the earliest identity instead: which of the two humans a
	// contact names is unspecified, and no caller depends on it.
	ids := make([]*memIdent, 0, len(s.hum.identities))
	for _, id := range s.hum.identities {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i].human < ids[j].human })
	for _, id := range ids {
		email := strings.ToLower(id.email)
		if !id.verified || !want[email] || out[email] != "" || !s.memMatchableLocked(tenant, id.human) {
			continue
		}
		out[email] = id.human
	}
	return out, nil
}

// memMatchableLocked: hum holds a live, non-guest membership of tenant and
// is not disabled. Caller holds s.mu.
func (s *Memory) memMatchableLocked(tenant, hum string) bool {
	m, ok := s.hum.members[[2]string{tenant, hum}]
	if !ok || m.disabled || m.role == rbac.ChannelGuest {
		return false
	}
	hm, ok := s.hum.humans[hum]
	return ok && !hm.disabled
}

// MembersByVerifiedEmail is ContactMembers' match: one query in tenant's
// scope for the whole page.
func (s *Postgres) MembersByVerifiedEmail(ctx context.Context, tenant string, emails []string) (map[string]string, error) {
	keys := contactMatchKeys(emails)
	out := map[string]string{}
	if len(keys) == 0 {
		return out, nil
	}
	err := s.queryTenant(ctx, tenant, `SELECT DISTINCT ON (lower(i.email)) lower(i.email), i.human_id
		FROM human_identities i
		JOIN humans h ON h.human_id = i.human_id
		JOIN tenant_memberships m ON m.human_id = i.human_id AND m.tenant_id = $1
		WHERE lower(i.email) = ANY($2) AND i.email_verified
		  AND h.disabled_at IS NULL AND NOT h.technical
		  AND m.disabled_at IS NULL AND m.role <> $3
		ORDER BY lower(i.email), i.created_at, i.provider, i.subject`,
		[]any{tenant, keys, rbac.ChannelGuest}, func(rows pgx.Rows) error {
			var email, hum string
			if err := rows.Scan(&email, &hum); err != nil {
				return err
			}
			out[email] = hum
			return nil
		})
	if err != nil {
		return nil, err
	}
	return out, nil
}
