package store

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0108. release_notes has no tenant_id and no row
// security (estate-wide, like human_identities), so the statements run on the
// pool, not in a tenant or operator scope.

const releaseNoteCols = `sha, coalesce(version, ''), committed_at, kind, area, subject,
	lay_what, lay_how, lay_why, tech_what, tech_how, tech_why, state, coalesce(reverts, ''), link, ingested_at`

// releaseVersionSQL is a version column or parameter as int[] (v7.10.0 >
// v7.9.0), the expression rdb 0108's index is built on.
func releaseVersionSQL(expr string) string {
	return `string_to_array(substr(` + expr + `, 2), '.')::int[]`
}

func scanReleaseNote(row pgx.Row) (ReleaseNote, error) {
	var n ReleaseNote
	err := row.Scan(&n.SHA, &n.Version, &n.CommittedAt, &n.Kind, &n.Area, &n.Subject,
		&n.LayWhat, &n.LayHow, &n.LayWhy, &n.TechWhat, &n.TechHow, &n.TechWhy, &n.State, &n.Reverts, &n.Link, &n.IngestedAt)
	n.CommittedAt, n.IngestedAt = n.CommittedAt.UTC(), n.IngestedAt.UTC()
	return n, err
}

func (s *Postgres) queryReleaseNotes(ctx context.Context, sql string, args ...any) ([]ReleaseNote, error) {
	rows, err := s.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ReleaseNote{}
	for rows.Next() {
		n, err := scanReleaseNote(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

// PutReleaseNotes is ONE multi-row upsert per batch.
func (s *Postgres) PutReleaseNotes(ctx context.Context, batch []ReleaseNote, now time.Time) error {
	if len(batch) == 0 {
		return nil
	}
	if len(batch) > ReleaseBatchMax {
		return fmt.Errorf("release note batch of %d rows, max %d", len(batch), ReleaseBatchMax)
	}
	const cols = 16
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
		args = append(args, n.SHA, nullable(n.Version), n.CommittedAt.UTC(), n.Kind, n.Area, n.Subject,
			n.LayWhat, n.LayHow, n.LayWhy, n.TechWhat, n.TechHow, n.TechWhy, n.State, nullable(n.Reverts), n.Link, now.UTC())
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO release_notes (sha, version, committed_at, kind, area, subject,
		lay_what, lay_how, lay_why, tech_what, tech_how, tech_why, state, reverts, link, ingested_at)
		VALUES `+sb.String()+`
		ON CONFLICT (sha) DO UPDATE SET
			version = coalesce(release_notes.version, EXCLUDED.version),
			committed_at = EXCLUDED.committed_at, kind = EXCLUDED.kind, area = EXCLUDED.area,
			subject = EXCLUDED.subject, lay_what = EXCLUDED.lay_what, lay_how = EXCLUDED.lay_how,
			lay_why = EXCLUDED.lay_why, tech_what = EXCLUDED.tech_what, tech_how = EXCLUDED.tech_how,
			tech_why = EXCLUDED.tech_why, state = EXCLUDED.state, reverts = EXCLUDED.reverts,
			link = EXCLUDED.link, ingested_at = EXCLUDED.ingested_at`, args...)
	return err
}

func (s *Postgres) ReleaseNote(ctx context.Context, ref string) (ReleaseNote, error) {
	ref, err := CheckReleaseRef(ref)
	if err != nil {
		return ReleaseNote{}, err
	}
	// The ref is hex only, so it carries no LIKE wildcard.
	hit, err := s.queryReleaseNotes(ctx, `SELECT `+releaseNoteCols+` FROM release_notes
		WHERE sha LIKE $1 || '%' ORDER BY sha LIMIT 2`, ref)
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

func (s *Postgres) ListReleaseNotes(ctx context.Context, before string, versions int) ([]ReleaseNote, error) {
	if err := checkBefore(before); err != nil {
		return nil, err
	}
	vk := releaseVersionSQL("version")
	out, err := s.queryReleaseNotes(ctx, `WITH page AS (
			SELECT DISTINCT `+vk+` AS k FROM release_notes
			WHERE version IS NOT NULL AND ($1 = '' OR `+vk+` < `+releaseVersionSQL("$1::text")+`)
			ORDER BY k DESC LIMIT $2)
		SELECT `+releaseNoteCols+` FROM release_notes
		WHERE version IS NOT NULL AND `+vk+` IN (SELECT k FROM page)`, before, ClampReleaseVersions(versions))
	sortReleaseNotes(out)
	return out, err
}

func (s *Postgres) ReleaseNotesOfVersion(ctx context.Context, version string) ([]ReleaseNote, error) {
	if _, ok := releaseVersionKey(version); !ok {
		return nil, fmt.Errorf("version must be v<X.Y.Z>")
	}
	out, err := s.queryReleaseNotes(ctx, `SELECT `+releaseNoteCols+` FROM release_notes
		WHERE version = $1`, version)
	sortReleaseNotes(out)
	return out, err
}
