package store

import (
	"context"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

// The Releases report of the Reporting section (spec 143 section 2.4, tasks
// T020 and T021): two reads over release_notes (rdb 0108) and estate_deploys
// (rdb 0202). Both tables are estate-wide, so no call takes a tenant id.
// estate_deploys is written by spec 143 row 4 (T025, T027); until then it is
// empty and every day answers with no deploys, never an error.

// Releases report limits.
const (
	ReleaseReportLimitMax     = 200 // commits one page carries at most (T021)
	ReleaseReportLimitDefault = 50
	ReleaseReportSearchMax    = 200 // bytes of the free-text search
	ReleaseReportDeploysMax   = 1000
)

// releaseAreaRe is one area filter value: a scope's first word.
var releaseAreaRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)

// ReleaseReportFilter is one report query: the commits with From <=
// committed_at < To, of one of Kinds and Areas when set, matching Search.
// Limit and Offset page ReleaseCommits only.
type ReleaseReportFilter struct {
	From, To      time.Time
	Kinds, Areas  []string
	Search        string
	Limit, Offset int
}

// ReleaseDeploy is one estate_deploys row as the report shows it (EstateDeploy less its run and writer fields).
type ReleaseDeploy struct {
	Env        string    `json:"env"`
	Component  string    `json:"component"`
	Version    string    `json:"version"`
	CommitSHA  string    `json:"commit_sha"`
	DeployedAt time.Time `json:"deployed_at"`
	Status     string    `json:"status"`
	Source     string    `json:"source"`
}

// ReleaseDay is one UTC day of the report: its commits counted by kind and by
// area, and the deploys made that day, newest first.
type ReleaseDay struct {
	Date         string          `json:"date"`
	CommitsCount int             `json:"commits_count"`
	Kinds        map[string]int  `json:"kinds"`
	Areas        map[string]int  `json:"areas"`
	Deploys      []ReleaseDeploy `json:"deploys"`
}

// ReleaseDaily is the daily report: days newest first, the commit total and
// the count of distinct versions those commits carry.
type ReleaseDaily struct {
	Days          []ReleaseDay `json:"days"`
	TotalCommits  int          `json:"total_commits"`
	TotalVersions int          `json:"total_versions"`
}

// ReleaseReports is the store half of the Releases tab. Optional: the hub's
// routes answer as off on a store without it.
type ReleaseReports interface {
	// ReleaseDaily aggregates the filtered commits per UTC day of
	// committed_at and joins the deploys of the same window per UTC day of
	// deployed_at. A day with deploys and no matching commit is listed too.
	ReleaseDaily(ctx context.Context, f ReleaseReportFilter) (ReleaseDaily, error)
	// ReleaseCommits is one page of the filtered commits, newest first, and
	// the count of every match.
	ReleaseCommits(ctx context.Context, f ReleaseReportFilter) ([]ReleaseNote, int, error)
}

// ReleaseArea is a note's area as the report groups it: the first word of
// its scope ("wui, SPL-2782" -> "wui"), lowercased, a csi-spl- prefix
// dropped (the ingest's directory form, "csi-spl-wui" -> "wui").
func ReleaseArea(area string) string {
	a, _, _ := strings.Cut(area, ",")
	return strings.TrimPrefix(strings.ToLower(strings.TrimSpace(a)), "csi-spl-")
}

// releaseAreaSQL is ReleaseArea in SQL.
const releaseAreaSQL = `regexp_replace(lower(btrim(split_part(area, ',', 1))), '^csi-spl-', '')`

// CheckReleaseReportFilter names the first thing the filter may not carry.
func CheckReleaseReportFilter(f ReleaseReportFilter) error {
	switch {
	case f.From.IsZero() || f.To.IsZero() || !f.From.Before(f.To):
		return fmt.Errorf("from must be before to")
	case f.Limit < 0 || f.Limit > ReleaseReportLimitMax:
		return fmt.Errorf("limit must be 1..%d", ReleaseReportLimitMax)
	case f.Offset < 0:
		return fmt.Errorf("offset must be 0 or more")
	case len(f.Search) > ReleaseReportSearchMax || hasControl(f.Search):
		return fmt.Errorf("search must be one line of up to %d bytes", ReleaseReportSearchMax)
	case slices.ContainsFunc(f.Kinds, func(k string) bool { return k == "" || !releaseKindRe.MatchString(k) }):
		return fmt.Errorf("kind must be lowercase subject prefixes")
	case slices.ContainsFunc(f.Areas, func(a string) bool { return !releaseAreaRe.MatchString(a) }):
		return fmt.Errorf("area must be lowercase scope words")
	}
	return nil
}

// releaseMatch is the filter on one note, the Go side of releaseReportWhere.
func releaseMatch(f ReleaseReportFilter, n ReleaseNote) bool {
	if n.CommittedAt.Before(f.From) || !n.CommittedAt.Before(f.To) {
		return false
	}
	if len(f.Kinds) > 0 && !slices.Contains(f.Kinds, n.Kind) {
		return false
	}
	if len(f.Areas) > 0 && !slices.Contains(f.Areas, ReleaseArea(n.Area)) {
		return false
	}
	q := strings.ToLower(f.Search)
	if q == "" || strings.HasPrefix(n.SHA, q) {
		return true
	}
	hay := strings.ToLower(strings.Join([]string{n.Subject, n.Version, n.LayWhat, n.LayHow, n.LayWhy,
		n.TechWhat, n.TechHow, n.TechWhy}, "\n"))
	return strings.Contains(hay, q)
}

// releaseReportWhere is the filter as a WHERE clause over release_notes, its
// arguments numbered from $1.
func releaseReportWhere(f ReleaseReportFilter) (string, []any) {
	kinds, areas := f.Kinds, f.Areas
	if kinds == nil {
		kinds = []string{}
	}
	if areas == nil {
		areas = []string{}
	}
	return `committed_at >= $1 AND committed_at < $2
		AND (cardinality($3::text[]) = 0 OR kind = ANY($3::text[]))
		AND (cardinality($4::text[]) = 0 OR ` + releaseAreaSQL + ` = ANY($4::text[]))
		AND ($5::text = '' OR starts_with(sha, lower($5::text)) OR strpos(lower(concat_ws(chr(10), subject, version,
			lay_what, lay_how, lay_why, tech_what, tech_how, tech_why)), lower($5::text)) > 0)`,
		[]any{f.From.UTC(), f.To.UTC(), kinds, areas, f.Search}
}

// releaseDayOf is a time's UTC day, the key both drivers group by.
func releaseDayOf(t time.Time) string { return t.UTC().Format(time.DateOnly) }

// releaseDays builds the daily report from counted rows and deploys.
type releaseDays struct {
	byDate   map[string]*ReleaseDay
	versions map[string]bool
	total    int
}

func newReleaseDays() *releaseDays {
	return &releaseDays{byDate: map[string]*ReleaseDay{}, versions: map[string]bool{}}
}

func (d *releaseDays) day(date string) *ReleaseDay {
	day := d.byDate[date]
	if day == nil {
		day = &ReleaseDay{Date: date, Kinds: map[string]int{}, Areas: map[string]int{}, Deploys: []ReleaseDeploy{}}
		d.byDate[date] = day
	}
	return day
}

// add counts n commits of one day, kind, area and version.
func (d *releaseDays) add(date, kind, area, version string, n int) {
	day := d.day(date)
	day.CommitsCount += n
	if kind != "" {
		day.Kinds[kind] += n
	}
	if area != "" {
		day.Areas[area] += n
	}
	if version != "" {
		d.versions[version] = true
	}
	d.total += n
}

// result is the report, days newest first; deploys must come newest first.
func (d *releaseDays) result(deploys []ReleaseDeploy) ReleaseDaily {
	for _, dp := range deploys {
		day := d.day(releaseDayOf(dp.DeployedAt))
		day.Deploys = append(day.Deploys, dp)
	}
	out := ReleaseDaily{Days: []ReleaseDay{}, TotalCommits: d.total, TotalVersions: len(d.versions)}
	for _, day := range d.byDate {
		out.Days = append(out.Days, *day)
	}
	slices.SortFunc(out.Days, func(a, b ReleaseDay) int { return strings.Compare(b.Date, a.Date) })
	return out
}

// sortEstateDeploys is newest first, the order both drivers return.
func sortEstateDeploys(ds []ReleaseDeploy) {
	slices.SortStableFunc(ds, func(a, b ReleaseDeploy) int { return b.DeployedAt.Compare(a.DeployedAt) })
}

// ReleaseDaily is ReleaseReports.ReleaseDaily: one GROUP BY over release_notes,
// then the window's deploys.
func (s *Postgres) ReleaseDaily(ctx context.Context, f ReleaseReportFilter) (ReleaseDaily, error) {
	if err := CheckReleaseReportFilter(f); err != nil {
		return ReleaseDaily{}, err
	}
	where, args := releaseReportWhere(f)
	rows, err := s.pool.Query(ctx, `SELECT to_char(committed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD'), kind,
		`+releaseAreaSQL+`, coalesce(version, ''), count(*)
		FROM release_notes WHERE `+where+` GROUP BY 1, 2, 3, 4`, args...)
	if err != nil {
		return ReleaseDaily{}, err
	}
	days := newReleaseDays()
	var date, kind, area, version string
	var n int
	_, err = pgx.ForEachRow(rows, []any{&date, &kind, &area, &version, &n}, func() error {
		days.add(date, kind, area, version, n)
		return nil
	})
	if err != nil {
		return ReleaseDaily{}, err
	}
	deploys, err := s.estateDeploys(ctx, f.From, f.To)
	if err != nil {
		return ReleaseDaily{}, err
	}
	return days.result(deploys), nil
}

// estateDeploys reads the deploys of [from, to), newest first. The read
// policy of rdb 0202 lets every scope see them, so it runs on the pool.
func (s *Postgres) estateDeploys(ctx context.Context, from, to time.Time) ([]ReleaseDeploy, error) {
	rows, err := s.pool.Query(ctx, `SELECT env, component, version, commit_sha, deployed_at, status, source
		FROM estate_deploys WHERE deployed_at >= $1 AND deployed_at < $2
		ORDER BY deployed_at DESC LIMIT $3`, from.UTC(), to.UTC(), ReleaseReportDeploysMax)
	if err != nil {
		return nil, err
	}
	out := []ReleaseDeploy{}
	var d ReleaseDeploy
	_, err = pgx.ForEachRow(rows, []any{&d.Env, &d.Component, &d.Version, &d.CommitSHA, &d.DeployedAt, &d.Status, &d.Source}, func() error {
		d.DeployedAt = d.DeployedAt.UTC()
		out = append(out, d)
		return nil
	})
	return out, err
}

// ReleaseCommits is ReleaseReports.ReleaseCommits: the match count, then the page.
func (s *Postgres) ReleaseCommits(ctx context.Context, f ReleaseReportFilter) ([]ReleaseNote, int, error) {
	if err := CheckReleaseReportFilter(f); err != nil {
		return nil, 0, err
	}
	where, args := releaseReportWhere(f)
	var total int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM release_notes WHERE `+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	out, err := s.queryReleaseNotes(ctx, false, `SELECT `+releaseNoteCols+` FROM release_notes WHERE `+where+`
		ORDER BY committed_at DESC, sha LIMIT $6 OFFSET $7`, append(args, releaseReportLimit(f.Limit), f.Offset)...)
	return out, total, err
}

// releaseReportLimit is a page size, 0 = the default.
func releaseReportLimit(n int) int {
	if n <= 0 {
		return ReleaseReportLimitDefault
	}
	return min(n, ReleaseReportLimitMax)
}

// Memory side: the deploys a test seeds, per store, beside memReleases.
var (
	memDeployMu sync.Mutex
	memDeploys  = map[*Memory][]ReleaseDeploy{}
)

// ReleaseDaily is ReleaseReports.ReleaseDaily over the memory notes and the
// deploys a test seeded.
func (s *Memory) ReleaseDaily(_ context.Context, f ReleaseReportFilter) (ReleaseDaily, error) {
	if err := CheckReleaseReportFilter(f); err != nil {
		return ReleaseDaily{}, err
	}
	days := newReleaseDays()
	memReleaseMu.Lock()
	for _, n := range s.releases() {
		if releaseMatch(f, n) {
			days.add(releaseDayOf(n.CommittedAt), n.Kind, ReleaseArea(n.Area), n.Version, 1)
		}
	}
	memReleaseMu.Unlock()
	memDeployMu.Lock()
	deploys := []ReleaseDeploy{}
	for _, d := range memDeploys[s] {
		if !d.DeployedAt.Before(f.From) && d.DeployedAt.Before(f.To) {
			deploys = append(deploys, d)
		}
	}
	memDeployMu.Unlock()
	sortEstateDeploys(deploys)
	return days.result(deploys[:min(len(deploys), ReleaseReportDeploysMax)]), nil
}

// ReleaseCommits is ReleaseReports.ReleaseCommits over the memory notes.
func (s *Memory) ReleaseCommits(_ context.Context, f ReleaseReportFilter) ([]ReleaseNote, int, error) {
	if err := CheckReleaseReportFilter(f); err != nil {
		return nil, 0, err
	}
	memReleaseMu.Lock()
	hit := []ReleaseNote{}
	for _, n := range s.releases() {
		if releaseMatch(f, n) {
			hit = append(hit, n)
		}
	}
	memReleaseMu.Unlock()
	slices.SortFunc(hit, func(a, b ReleaseNote) int {
		if c := b.CommittedAt.Compare(a.CommittedAt); c != 0 {
			return c
		}
		return strings.Compare(a.SHA, b.SHA)
	})
	lo := min(f.Offset, len(hit))
	return hit[lo:min(lo+releaseReportLimit(f.Limit), len(hit))], len(hit), nil
}
