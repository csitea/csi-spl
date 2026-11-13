package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0108 and 0267: every row names its workspace and repo.
// Row B-3's contract keys it on (tenant_id, repo_slug, sha) and forces row
// security: reads run in the tenant's scope, which its read policy and the
// WHERE tenant_id of each read both scope; writes run in the operator's.

const releaseNoteCols = `tenant_id, repo_slug, sha, coalesce(version, ''), committed_at, kind, area, subject,
	lay_what, lay_how, lay_why, tech_what, tech_how, tech_why, state, coalesce(reverts, ''), link, ingested_at,
	coalesce(issue_tenant, ''), issue_keys, coalesce(released_at, committed_at)`

// releaseKeySQL is a version column or parameter as int[] {cycle, X, Y, Z}
// (v1.0.1-c2 > v9.9.9 > v7.10.0 > v7.9.0), NULL for any other tag:
// releaseVersionKey in SQL and the expression rdb 0270's index is built on.
func releaseKeySQL(expr string) string {
	return `CASE WHEN ` + expr + ` ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c([2-9]|[1-9][0-9]{1,3}))?$'
          THEN array_prepend(coalesce(substring(` + expr + ` from '-c([0-9]+)$')::int, 1),
                    string_to_array(substring(` + expr + ` from '^v([0-9.]+)'), '.')::int[]) END`
}

// releaseRatSQL is the time a row ranks by: released, else committed.
const releaseRatSQL = `coalesce(released_at, committed_at)`

// releaseNumberedSQL is every versioned row of tenant $1 with its seq, the
// list order reversed (numberReleaseNotes in SQL): the oldest is 1.
func releaseNumberedSQL() string {
	vk := releaseKeySQL("version")
	return `SELECT n.*, row_number() OVER (ORDER BY k NULLS FIRST, vat, version DESC, rat, committed_at, sha DESC, repo_slug DESC) AS seq
		FROM (SELECT r.*, ` + vk + ` AS k, ` + releaseRatSQL + ` AS rat,
			CASE WHEN ` + vk + ` IS NULL THEN max(` + releaseRatSQL + `) OVER (PARTITION BY version) END AS vat
			FROM release_notes r WHERE tenant_id = $1 AND version IS NOT NULL) n`
}

// scanReleaseNote reads releaseNoteCols, and the seq after them when withSeq.
func scanReleaseNote(row pgx.Row, withSeq bool) (ReleaseNote, error) {
	var n ReleaseNote
	dest := []any{&n.TenantID, &n.RepoSlug, &n.SHA, &n.Version, &n.CommittedAt, &n.Kind, &n.Area, &n.Subject,
		&n.LayWhat, &n.LayHow, &n.LayWhy, &n.TechWhat, &n.TechHow, &n.TechWhy, &n.State, &n.Reverts, &n.Link, &n.IngestedAt,
		&n.IssueTenant, &n.IssueKeys, &n.ReleasedAt}
	if withSeq {
		dest = append(dest, &n.Seq)
	}
	err := row.Scan(dest...)
	n.CommittedAt, n.IngestedAt, n.ReleasedAt = n.CommittedAt.UTC(), n.IngestedAt.UTC(), n.ReleasedAt.UTC()
	if n.IssueKeys == nil {
		n.IssueKeys = []string{}
	}
	return n, err
}

func (s *Postgres) queryReleaseNotes(ctx context.Context, tenant string, withSeq bool, sql string, args ...any) ([]ReleaseNote, error) {
	out := []ReleaseNote{}
	err := s.queryTenant(ctx, tenant, sql, args, func(rows pgx.Rows) error {
		n, err := scanReleaseNote(rows, withSeq)
		out = append(out, n)
		return err
	})
	return out, err
}

// PutReleaseNotes is ONE multi-row upsert per batch, every row in repo of
// tenant. released_at (rdb 0177, spec 130 section 4) is set once: on the
// insert of a row that has a version, or when a stored row without one gets
// it; a re-sent row never restamps it.
func (s *Postgres) PutReleaseNotes(ctx context.Context, tenant, repo string, batch []ReleaseNote, now time.Time) error {
	if err := checkReleaseScope(tenant, repo); err != nil {
		return err
	}
	if len(batch) == 0 {
		return nil
	}
	if len(batch) > ReleaseBatchMax {
		return fmt.Errorf("release note batch of %d rows, max %d", len(batch), ReleaseBatchMax)
	}
	const cols = 21
	nullable := func(v string) any {
		if v == "" {
			return nil
		}
		return v
	}
	// One sha twice in a batch would be "ON CONFLICT ... cannot affect row a
	// second time": the last one wins, as in Memory.
	last := map[string]int{}
	for i, n := range batch {
		last[n.SHA] = i
	}
	var sb strings.Builder
	args := make([]any, 0, len(batch)*cols)
	for i, n := range batch {
		if last[n.SHA] != i {
			continue
		}
		if len(args) > 0 {
			sb.WriteString(", ")
		}
		sb.WriteString("(")
		for c := 1; c <= cols; c++ {
			if c > 1 {
				sb.WriteString(", ")
			}
			fmt.Fprintf(&sb, "$%d", len(args)+c)
		}
		sb.WriteString(")")
		args = append(args, tenant, repo, n.SHA, nullable(n.Version), n.CommittedAt.UTC(), n.Kind, n.Area, n.Subject,
			n.LayWhat, n.LayHow, n.LayWhy, n.TechWhat, n.TechHow, n.TechWhy, n.State, nullable(n.Reverts), n.Link, now.UTC(),
			releasedAt(n.Version, now), nullable(n.IssueTenant), issueKeysArg(n.IssueKeys))
	}
	return s.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO release_notes (tenant_id, repo_slug, sha, version, committed_at, kind, area, subject,
		lay_what, lay_how, lay_why, tech_what, tech_how, tech_why, state, reverts, link, ingested_at, released_at,
		issue_tenant, issue_keys)
		VALUES `+sb.String()+`
		ON CONFLICT (tenant_id, repo_slug, sha) DO UPDATE SET
			version = coalesce(release_notes.version, EXCLUDED.version),
			released_at = CASE WHEN release_notes.version IS NULL THEN EXCLUDED.released_at ELSE release_notes.released_at END,
			committed_at = EXCLUDED.committed_at, kind = EXCLUDED.kind, area = EXCLUDED.area,
			subject = EXCLUDED.subject, lay_what = EXCLUDED.lay_what, lay_how = EXCLUDED.lay_how,
			lay_why = EXCLUDED.lay_why, tech_what = EXCLUDED.tech_what, tech_how = EXCLUDED.tech_how,
			tech_why = EXCLUDED.tech_why, state = EXCLUDED.state, reverts = EXCLUDED.reverts,
			link = EXCLUDED.link, ingested_at = EXCLUDED.ingested_at,
			issue_tenant = coalesce(EXCLUDED.issue_tenant, release_notes.issue_tenant),
			issue_keys = CASE WHEN EXCLUDED.issue_tenant IS NULL THEN release_notes.issue_keys ELSE EXCLUDED.issue_keys END`, args...)
		return err
	})
}

// checkReleaseScope refuses a write that names no workspace or no repo.
func checkReleaseScope(tenant, repo string) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if strings.TrimSpace(repo) == "" {
		return errors.New("release notes need a repo")
	}
	return nil
}

// issueKeysArg is a row's keys as a text[] parameter, never NULL.
func issueKeysArg(keys []string) []string {
	if keys == nil {
		return []string{}
	}
	return keys
}

// releasedAt is the released_at of a row upserted at now: now when it
// carries a version, else NULL.
func releasedAt(version string, now time.Time) any {
	if version == "" {
		return nil
	}
	return now.UTC()
}

func (s *Postgres) ReleaseNote(ctx context.Context, tenant, ref string) (ReleaseNote, error) {
	ref, err := CheckReleaseRef(ref)
	if err != nil {
		return ReleaseNote{}, err
	}
	// The ref is hex only, so it carries no LIKE wildcard.
	hit, err := s.queryReleaseNotes(ctx, tenant, false, `SELECT `+releaseNoteCols+` FROM release_notes
		WHERE tenant_id = $1 AND sha LIKE $2 || '%' ORDER BY sha, repo_slug LIMIT 2`, tenant, ref)
	switch {
	case err != nil:
		return ReleaseNote{}, err
	case len(hit) == 0:
		return ReleaseNote{}, ErrNotFound
	case len(hit) > 1:
		return ReleaseNote{}, ErrAmbiguousRef
	}
	return hit[0], nil
}

// releaseListSQL is one page for a cursor of no kind, a keyed version ($3) or
// another tag ($3). $1 is the tenant and $2 the page size in versions. The
// keyed versions walk rdb 0270's index; the tags with no key, ranked by their
// newest row, follow them. The seq is the versioned count minus the rows newer
// than the page, minus the row's place in the page, which equals
// releaseNumberedSQL's row_number() (TestReleaseNotesPageSeqOracle) without
// sorting every row (perf round 5, P5-08).
func releaseListSQL(before string) string {
	const scope = `tenant_id = $1 AND version IS NOT NULL`
	vk, cut := releaseKeySQL("version"), releaseKeySQL("$3::text")
	_, keyed := releaseVersionKey(before)
	keyedFilter, tagFilter, newer := "", "", "0"
	switch {
	case before != "" && keyed:
		keyedFilter = ` AND ` + vk + ` < ` + cut
		newer = `(SELECT count(*) FROM release_notes WHERE ` + scope + ` AND ` + vk + ` >= ` + cut + `)`
	case before != "":
		keyedFilter = ` AND false`
		tagFilter = ` WHERE vat < (SELECT vat FROM cur) OR (vat = (SELECT vat FROM cur) AND version > $3)`
		newer = `(SELECT count(*) FROM release_notes WHERE ` + scope + ` AND (` + vk + ` IS NOT NULL OR version IN
			(SELECT version FROM uv WHERE vat > (SELECT vat FROM cur) OR (vat = (SELECT vat FROM cur) AND version <= $3))))`
	}
	cur := ""
	if tagFilter != "" {
		cur = ` cur AS (SELECT vat FROM uv WHERE version = $3),`
	}
	return `WITH uv AS (SELECT version, max(` + releaseRatSQL + `) AS vat FROM release_notes
			WHERE ` + scope + ` AND ` + vk + ` IS NULL GROUP BY version),` + cur + `
		kp AS (SELECT DISTINCT ` + vk + ` AS k FROM release_notes
			WHERE ` + scope + ` AND ` + vk + ` IS NOT NULL` + keyedFilter + `
			ORDER BY k DESC NULLS LAST LIMIT $2),
		up AS (SELECT version, vat FROM uv` + tagFilter + ` ORDER BY vat DESC, version LIMIT $2 - (SELECT count(*) FROM kp)),
		pg AS (SELECT r.*, ` + vk + ` AS k, NULL::timestamptz AS vat, ` + releaseRatSQL + ` AS rat FROM release_notes r
				WHERE ` + scope + ` AND ` + vk + ` >= (SELECT min(k) FROM kp) AND ` + vk + ` <= (SELECT max(k) FROM kp)
			UNION ALL
			SELECT r.*, NULL::int[], up.vat, ` + releaseRatSQL + ` FROM release_notes r JOIN up ON up.version = r.version
				WHERE r.tenant_id = $1 AND ` + releaseKeySQL("r.version") + ` IS NULL)
		SELECT ` + releaseNoteCols + `,
			(SELECT count(*) FROM release_notes WHERE ` + scope + `) - ` + newer + `
			+ 1 - row_number() OVER (ORDER BY k DESC NULLS LAST, vat DESC, version, rat DESC, committed_at DESC, sha, repo_slug)
		FROM pg`
}

// ListReleaseNotes reads only the page (see releaseListSQL).
func (s *Postgres) ListReleaseNotes(ctx context.Context, tenant, before string, versions int) ([]ReleaseNote, error) {
	if err := checkBefore(before); err != nil {
		return nil, err
	}
	args := []any{tenant, ClampReleaseVersions(versions)}
	if before != "" {
		args = append(args, before)
	}
	out, err := s.queryReleaseNotes(ctx, tenant, true, releaseListSQL(before), args...)
	sortReleaseNotes(out)
	return out, err
}

func (s *Postgres) ReleaseNotesOfVersion(ctx context.Context, tenant, version string) ([]ReleaseNote, error) {
	if !releaseVersionRe.MatchString(version) {
		return nil, errReleaseVersionShape
	}
	out, err := s.queryReleaseNotes(ctx, tenant, true, `WITH numbered AS (`+releaseNumberedSQL()+`)
		SELECT `+releaseNoteCols+`, seq FROM numbered WHERE version = $2`, tenant, version)
	sortReleaseNotes(out)
	return out, err
}
