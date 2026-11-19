package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// RepoSync on Postgres (repo_sync.go). Each call is in the operator scope:
// the sync loop is the hub's, of no workspace, and rdb 0266 lets only that
// scope write workspace_repos (operatorCallers lists each).

// RepoSyncTargets reads every synced repo of every workspace.
func (s *Postgres) RepoSyncTargets(ctx context.Context) ([]RepoSyncTarget, error) {
	out := []RepoSyncTarget{}
	err := s.asOperatorQuery(ctx, `SELECT tenant_id, repo_slug, trunk_branch, version_tag_glob, area_strip_prefix,
		auth_mode, coalesce(github_installation_id, 0), coalesce(last_synced_sha, ''), sync_status
		FROM workspace_repos WHERE auth_mode = ANY($1) ORDER BY tenant_id, repo_slug`,
		[]any{RepoSyncedModes}, func(rows pgx.Rows) error {
			var t RepoSyncTarget
			if err := rows.Scan(&t.Tenant, &t.Slug, &t.TrunkBranch, &t.VersionTagGlob, &t.AreaStripPrefix,
				&t.AuthMode, &t.InstallationID, &t.LastSyncedSHA, &t.SyncStatus); err != nil {
				return err
			}
			out = append(out, t)
			return nil
		})
	return out, err
}

// PutRepoSyncState writes the cursor and the outcome back on one row.
func (s *Postgres) PutRepoSyncState(ctx context.Context, tenant, slug string, st RepoSyncState) error {
	if err := checkRepoSyncState(tenant, slug, &st); err != nil {
		return err
	}
	return s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE workspace_repos SET
			last_synced_sha = coalesce(NULLIF($3, ''), last_synced_sha), last_synced_at = $4,
			sync_status = $5, sync_error = $6
			WHERE tenant_id = $1 AND repo_slug = $2`, tenant, slug, st.SHA, st.At.UTC(), st.Status, st.Error)
		if err == nil && tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return err
	})
}

// UnversionedReleaseNotes reads the repo's commits no tag covers yet.
func (s *Postgres) UnversionedReleaseNotes(ctx context.Context, tenant, repo string) ([]UnversionedNote, error) {
	if err := checkReleaseScope(tenant, repo); err != nil {
		return nil, err
	}
	out := []UnversionedNote{}
	err := s.asOperatorQuery(ctx, `SELECT sha, committed_at FROM (
			SELECT sha, committed_at FROM release_notes
			WHERE tenant_id = $1 AND repo_slug = $2 AND version IS NULL
			ORDER BY committed_at DESC, sha LIMIT $3) newest
		ORDER BY committed_at, sha`, []any{tenant, repo, repoSyncUnversionedMax}, func(rows pgx.Rows) error {
		var n UnversionedNote
		if err := rows.Scan(&n.SHA, &n.CommittedAt); err != nil {
			return err
		}
		out = append(out, n)
		return nil
	})
	return out, err
}

// SetReleaseVersions versions the rows that have no version yet.
func (s *Postgres) SetReleaseVersions(ctx context.Context, tenant, repo string, versions map[string]string, now time.Time) (int, error) {
	if err := checkReleaseVersions(tenant, repo, versions); err != nil {
		return 0, err
	}
	shas, vs := make([]string, 0, len(versions)), make([]string, 0, len(versions))
	for sha, v := range versions {
		shas, vs = append(shas, sha), append(vs, v)
	}
	var set int64
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE release_notes r SET version = v.version, released_at = $5
			FROM unnest($3::text[], $4::text[]) AS v(sha, version)
			WHERE r.tenant_id = $1 AND r.repo_slug = $2 AND r.sha = v.sha AND r.version IS NULL`,
			tenant, repo, shas, vs, now.UTC())
		set = tag.RowsAffected()
		return err
	})
	return int(set), err
}

// TryRepoSyncLock takes a session advisory lock on one extra connection
// outside the pool, as LockRepoDocWorker: the hub runs on several
// instances, and one repo is synced by one of them at a time.
func (s *Postgres) TryRepoSyncLock(ctx context.Context, slug string) (func(), bool, error) {
	conn, err := pgx.ConnectConfig(ctx, s.pool.Config().ConnConfig.Copy())
	if err != nil {
		return nil, false, err
	}
	var got bool
	err = conn.QueryRow(ctx, `SELECT pg_try_advisory_lock(hashtextextended('repo-sync/' || $1, 143))`, slug).Scan(&got)
	if err != nil || !got {
		_ = conn.Close(context.Background())
		return nil, false, err
	}
	return func() { _ = conn.Close(context.Background()) }, true, nil
}
