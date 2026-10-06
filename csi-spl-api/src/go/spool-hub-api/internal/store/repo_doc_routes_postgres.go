package store

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// What the Repo Docs edit routes (spec 075 repo-edit, task T08) read besides
// the queue methods of repo_doc_edits_postgres.go: the person an author is
// resolved from, the member a join token seated an agent for, and the
// overlays GET /v1/docs serves.

// RepoDocPerson is a human as the edit routes see them in one workspace.
// MemberSince is zero when they hold no membership row there.
type RepoDocPerson struct {
	HumanID     string
	DisplayName string
	// Email is the sign-in email (humans.email); EmailVerified: a sign-in
	// identity of theirs carries exactly this address as verified.
	Email         string
	EmailVerified bool
	MemberSince   time.Time
}

// RepoDocPerson reads humanID's name, sign-in email and its verified flag,
// and when they joined tenant (ErrNotFound for an unknown human).
func (s *Postgres) RepoDocPerson(ctx context.Context, tenant, humanID string) (RepoDocPerson, error) {
	p := RepoDocPerson{HumanID: humanID}
	var since *time.Time
	err := s.queryRowTenant(ctx, tenant, `SELECT coalesce(h.display_name, ''), coalesce(h.email, ''),
		h.email IS NOT NULL AND EXISTS (SELECT 1 FROM human_identities i
		                                 WHERE i.human_id = h.human_id AND i.email = h.email AND i.email_verified),
		(SELECT m.created_at FROM tenant_memberships m WHERE m.tenant_id = $1 AND m.human_id = h.human_id)
		FROM humans h WHERE h.human_id = $2`, []any{tenant, humanID},
		&p.DisplayName, &p.Email, &p.EmailVerified, &since)
	if errors.Is(err, pgx.ErrNoRows) {
		return RepoDocPerson{}, ErrNotFound
	}
	if since != nil {
		p.MemberSince = since.UTC()
	}
	return p, err
}

// RepoDocSeatHuman is the for_human of the newest join token consumed by box
// in tenant (rdb 0119): the member that seat was made for; "" when it was
// made without one.
func (s *Postgres) RepoDocSeatHuman(ctx context.Context, tenant, box string) (string, error) {
	var hum string
	err := s.queryRowTenant(ctx, tenant, `SELECT coalesce((SELECT for_human FROM agent_join_tokens
		WHERE tenant_id = $1 AND consumed_box = $2 AND consumed_at IS NOT NULL AND for_human IS NOT NULL
		ORDER BY consumed_at DESC LIMIT 1), '')`, []any{tenant, strings.TrimSpace(box)}, &hum)
	return hum, err
}

// RepoDocOverlays is the newest edit of each repo doc path, of every
// workspace (the docs bucket is the env's, one for all), that is neither
// superseded nor failed; path "" = every path. GET /v1/docs serves the
// overlay of a queued, pushing or pushed one (and of a conflict to its own
// editor), and the published main key otherwise.
func (s *Postgres) RepoDocOverlays(ctx context.Context, path string) ([]RepoDocEdit, error) {
	out := []RepoDocEdit{}
	err := s.asOperatorQuery(ctx, `SELECT DISTINCT ON (path) `+repoDocEditCols+` FROM repo_doc_edits
		WHERE ($1 = '' OR path = $1) AND status NOT IN ('superseded', 'failed')
		ORDER BY path, created_at DESC, edit_id DESC`, []any{path}, collectRepoDocEdits(&out))
	return out, err
}
