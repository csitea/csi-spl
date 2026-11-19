package hub

import (
	"context"
	"errors"
	"os"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The hub's own GitHub sync of workspace repos (spec 143
// releases-projects.md row B-6b, spec 171 section 3.4.1 as section 5
// amends it, SPL-5808). Every repoSyncEvery the loop walks the
// workspace_repos rows it can read from GitHub, one repo at a time and one
// hub instance per repo (store.TryRepoSyncLock):
//
//   - the trunk commits newer than the row's last_synced_sha (a first sync:
//     the newest repoSyncBackfill), each one's area from its subject's
//     scope, else the top folder its files changed (one commit read each,
//     at most repoSyncDetailMax per sync), less the row's area_strip_prefix;
//   - its version: the nearest version tag at or after it on trunk, of this
//     repo only. A version tag is a tag matching the row's version_tag_glob
//     or the tag of a published GitHub Release. released_at is the time the
//     sync first saw it (the spec's fallback; a Release's own time needs a
//     store change, a later row);
//   - every row through buildRows (the ingest's checks and hygiene filter,
//     A7), then PutReleaseNotes; a tag that arrives after its commits were
//     stored versions them (store.SetReleaseVersions, only where none is
//     set), so no commit is read twice;
//   - last_synced_sha, last_synced_at, sync_status and sync_error written
//     back on the row.
//
// A repo is synced only as the workspace that registered it
// (ErrRepoSyncRefused), and through an App installation (the row's, else
// the hub's) or with no credential for auth_mode public. pat_kms has no
// sealed-token store yet: the row is written back as an error. Off unless
// Options.RepoSync is set (cnf, SPOOL_HUB_REPO_SYNC_ENABLED).

// repoSyncEvery is the loop's period (spec 171 Q2: "every 5 min").
const repoSyncEvery = 5 * time.Minute

// repoSyncBackfill caps a first sync's walk (spec 171 3.4.1).
const repoSyncBackfill = 2000

// repoSyncDetailMax caps the commit reads (top folder) of one sync.
const repoSyncDetailMax = 300

// repoSyncPATError is the sync_error of a pat_kms row.
const repoSyncPATError = "pat_kms: no sealed token store yet"

// ErrRepoSyncRefused: the repo is not one the workspace registered for the
// hub to sync (another workspace's slug, none, or ingest_only).
var ErrRepoSyncRefused = errors.New("repo sync: that repo is not registered for this workspace's sync")

// RepoSyncReader is the slice of github.RepoReader the sync reads.
type RepoSyncReader interface {
	CommitsSince(ctx context.Context, branch, since string, max int) ([]github.RepoCommit, bool, error)
	CommitTopFolder(ctx context.Context, sha string) (string, error)
	Tags(ctx context.Context) ([]github.RepoTag, error)
	Releases(ctx context.Context) ([]github.RepoRelease, error)
}

// RepoSync is the sync's wiring. Open gives the reader of one row; it
// answers an error for a row it cannot read (no App key, a bad slug).
type RepoSync struct {
	Open func(t store.RepoSyncTarget) (RepoSyncReader, error)
}

// GitHubRepoSync reads through app: auth_mode public with no credential,
// github_app through the row's installation, else defaultInstallation.
func GitHubRepoSync(app *github.RepoApp, defaultInstallation string) *RepoSync {
	return &RepoSync{Open: func(t store.RepoSyncTarget) (RepoSyncReader, error) {
		owner, name, _ := strings.Cut(t.Slug, "/")
		inst := ""
		if t.AuthMode == "github_app" {
			inst = defaultInstallation
			if t.InstallationID > 0 {
				inst = strconv.FormatInt(t.InstallationID, 10)
			}
			if inst == "" {
				return nil, github.ErrNoAppKey
			}
		}
		return app.Reader(owner, name, inst)
	}}
}

// RepoSyncResult is one repo's sync.
type RepoSyncResult struct {
	Stored    int
	Rejected  int
	Redacted  int
	Versioned int
	Cursor    string
}

// repoSyncStores is the store slices the sync needs.
type repoSyncStores struct {
	rs    store.RepoSync
	notes store.ReleaseNotes
	repos store.WorkspaceRepos
}

func (s *Server) repoSyncStores() (repoSyncStores, bool) {
	var st repoSyncStores
	var ok1, ok2, ok3 bool
	st.rs, ok1 = s.o.Store.(store.RepoSync)
	st.notes, ok2 = s.o.Store.(store.ReleaseNotes)
	st.repos, ok3 = s.o.Store.(store.WorkspaceRepos)
	return st, ok1 && ok2 && ok3 && s.o.RepoSync != nil && s.o.RepoSync.Open != nil
}

// RunRepoSync syncs every repo every repoSyncEvery until ctx ends; it
// returns at once while the sync is off.
func (s *Server) RunRepoSync(ctx context.Context) {
	if _, on := s.repoSyncStores(); !on {
		return
	}
	t := time.NewTicker(repoSyncEvery)
	defer t.Stop()
	for {
		if err := s.RepoSyncOnce(ctx); err != nil {
			s.o.Log.Warn().Str("err", err.Error()).Msg("repo sync: tick")
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// RepoSyncOnce syncs each synced repo once; a repo another instance holds
// is skipped, and one repo's failure never stops the others.
func (s *Server) RepoSyncOnce(ctx context.Context) error {
	st, on := s.repoSyncStores()
	if !on {
		return nil
	}
	targets, err := st.rs.RepoSyncTargets(ctx)
	if err != nil {
		return err
	}
	for _, t := range targets {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		res, err := s.SyncRepo(ctx, t.Tenant, t.Slug)
		if err != nil {
			s.o.Log.Warn().Str("repo", t.Slug).Str("err", err.Error()).Msg("repo sync")
			continue
		}
		s.o.Log.Info().Str("repo", t.Slug).Int("stored", res.Stored).Int("versioned", res.Versioned).
			Int("rejected", res.Rejected).Msg("repo sync")
	}
	return nil
}

// SyncRepo syncs tenant's repo slug once, under its lock. It refuses
// (ErrRepoSyncRefused) a slug tenant has not registered for the sync,
// before any GitHub call. A GitHub failure is written back on the row and
// returned.
func (s *Server) SyncRepo(ctx context.Context, tenant, slug string) (RepoSyncResult, error) {
	st, on := s.repoSyncStores()
	if !on {
		return RepoSyncResult{}, errors.New("repo sync is off")
	}
	t, err := s.repoSyncTarget(ctx, st, tenant, slug)
	if err != nil {
		return RepoSyncResult{}, err
	}
	release, held, err := st.rs.TryRepoSyncLock(ctx, slug)
	if err != nil || !held {
		return RepoSyncResult{}, errors.Join(errors.New("repo sync: another sync holds "+slug), err)
	}
	defer release()
	res, err := s.syncRepo(ctx, st, t)
	state := store.RepoSyncState{SHA: res.Cursor, At: s.o.Now(), Status: "ok"}
	if err != nil {
		state.SHA, state.Status, state.Error = "", "error", err.Error()
	}
	if perr := st.rs.PutRepoSyncState(ctx, tenant, slug, state); perr != nil {
		return res, errors.Join(err, perr)
	}
	return res, err
}

// repoSyncTarget is the row tenant registered for slug, else
// ErrRepoSyncRefused: the ingest's own check (WorkspaceRepo) first, then
// the row must be one the hub syncs.
func (s *Server) repoSyncTarget(ctx context.Context, st repoSyncStores, tenant, slug string) (store.RepoSyncTarget, error) {
	got, err := st.repos.WorkspaceRepo(ctx, tenant, slug)
	switch {
	case errors.Is(err, store.ErrRepoNotRegistered) || (err == nil && got != slug) || slug == "":
		return store.RepoSyncTarget{}, ErrRepoSyncRefused
	case err != nil:
		return store.RepoSyncTarget{}, err
	}
	targets, err := st.rs.RepoSyncTargets(ctx)
	if err != nil {
		return store.RepoSyncTarget{}, err
	}
	for _, t := range targets {
		if t.Tenant == tenant && t.Slug == slug {
			return t, nil
		}
	}
	return store.RepoSyncTarget{}, ErrRepoSyncRefused
}

// syncRepo is one sync of t: read, store, version. Cursor is the new
// last_synced_sha, "" to keep the old one.
func (s *Server) syncRepo(ctx context.Context, st repoSyncStores, t store.RepoSyncTarget) (RepoSyncResult, error) {
	if t.AuthMode == "pat_kms" {
		return RepoSyncResult{}, errors.New(repoSyncPATError)
	}
	rd, err := s.o.RepoSync.Open(t)
	if err != nil {
		return RepoSyncResult{}, err
	}
	rn := &releaseNotes{s: s, filter: newReleaseFilter(os.Getenv(ReleaseNoteBansEnv), func(string, error) {})}
	tags, err := repoVersionTags(ctx, rd, t.VersionTagGlob, rn.filter)
	if err != nil {
		return RepoSyncResult{}, err
	}
	commits, _, err := rd.CommitsSince(ctx, t.TrunkBranch, t.LastSyncedSHA, repoSyncBackfill)
	if err != nil {
		return RepoSyncResult{}, err
	}
	in, err := repoSyncRows(ctx, rd, t, commits, tags)
	if err != nil {
		return RepoSyncResult{}, err
	}
	res, err := s.storeRepoRows(ctx, st, rn, t, in)
	if err != nil {
		return res, err
	}
	if len(commits) > 0 {
		res.Cursor = commits[0].SHA
	}
	res.Versioned, err = s.versionLate(ctx, st, t, commits, tags)
	return res, err
}

// repoVersionTags is sha -> version: the tags matching glob and the tags
// of published Releases. A sha with several takes the lowest name; a tag
// the hygiene filter would redact is no version.
func repoVersionTags(ctx context.Context, rd RepoSyncReader, glob string, f releaseFilter) (map[string]string, error) {
	tags, err := rd.Tags(ctx)
	if err != nil {
		return nil, err
	}
	rels, err := rd.Releases(ctx)
	if err != nil {
		return nil, err
	}
	released := map[string]bool{}
	for _, r := range rels {
		released[r.TagName] = !r.Draft
	}
	out := map[string]string{}
	for _, tg := range tags {
		if ok, _ := path.Match(glob, tg.Name); !ok && !released[tg.Name] {
			continue
		}
		if f.bans(tg.Name) {
			continue
		}
		if old, has := out[tg.SHA]; !has || tg.Name < old {
			out[tg.SHA] = tg.Name
		}
	}
	return out, nil
}

// bans is whether any pattern of the hygiene filter matches s.
func (f releaseFilter) bans(s string) bool {
	for _, re := range f {
		if re.MatchString(s) {
			return true
		}
	}
	return false
}

// repoSyncRows is the ingest rows of commits (newest first): each one's
// version is the nearest version tag at or after it, its area the scope,
// else the top folder its files changed.
func repoSyncRows(ctx context.Context, rd RepoSyncReader, t store.RepoSyncTarget, commits []github.RepoCommit, tags map[string]string) ([]releaseNoteIn, error) {
	out := make([]releaseNoteIn, 0, len(commits))
	version, details := "", repoSyncDetailMax
	for _, c := range commits {
		if v, ok := tags[c.SHA]; ok {
			version = v
		}
		subject, _, _ := strings.Cut(strings.TrimSpace(c.Message), "\n")
		area := ""
		if m := releaseSubjectRe.FindStringSubmatch(strings.TrimSpace(subject)); (m == nil || m[2] == "") && details > 0 {
			details--
			top, err := rd.CommitTopFolder(ctx, c.SHA)
			if err != nil {
				return nil, err
			}
			area = strings.TrimPrefix(top, t.AreaStripPrefix)
		}
		out = append(out, releaseNoteIn{SHA: c.SHA, Version: version, CommittedAt: c.CommittedAt, Message: c.Message, Area: area})
	}
	return out, nil
}

// storeRepoRows stores the rows in batches, each through buildRows with
// the workspace's own issue prefix and trailer rule.
func (s *Server) storeRepoRows(ctx context.Context, st repoSyncStores, rn *releaseNotes, t store.RepoSyncTarget, in []releaseNoteIn) (RepoSyncResult, error) {
	var res RepoSyncResult
	prefix, err := rn.issuePrefix(ctx, t.Tenant)
	if err != nil {
		return res, err
	}
	optional, err := rn.trailersOptional(ctx, t.Tenant)
	if err != nil {
		return res, err
	}
	for len(in) > 0 {
		n := min(len(in), store.ReleaseBatchMax)
		rows, r := rn.buildRows(in[:n], t.Tenant, prefix, optional)
		if err := st.notes.PutReleaseNotes(ctx, t.Tenant, t.Slug, rows, s.o.Now()); err != nil {
			return res, err
		}
		res.Stored += len(rows)
		res.Rejected += len(r.Rejected)
		res.Redacted += r.Redacted
		in = in[n:]
	}
	return res, nil
}

// versionLate versions the stored commits no tag covered when they were
// stored: each takes the nearest tagged commit at or after it by commit
// time, among the repo's unversioned rows and this sync's commits.
func (s *Server) versionLate(ctx context.Context, st repoSyncStores, t store.RepoSyncTarget, commits []github.RepoCommit, tags map[string]string) (int, error) {
	un, err := st.rs.UnversionedReleaseNotes(ctx, t.Tenant, t.Slug)
	if err != nil || len(un) == 0 {
		return 0, err
	}
	type point struct {
		at      time.Time
		version string
	}
	var points []point
	for _, n := range un {
		if v, ok := tags[n.SHA]; ok {
			points = append(points, point{n.CommittedAt, v})
		}
	}
	for _, c := range commits {
		if v, ok := tags[c.SHA]; ok {
			points = append(points, point{c.CommittedAt, v})
		}
	}
	sort.SliceStable(points, func(i, j int) bool { return points[i].at.Before(points[j].at) })
	set := map[string]string{}
	for _, n := range un {
		i := sort.Search(len(points), func(i int) bool { return !points[i].at.Before(n.CommittedAt) })
		if i < len(points) {
			set[n.SHA] = points[i].version
		}
	}
	if len(set) == 0 {
		return 0, nil
	}
	return st.rs.SetReleaseVersions(ctx, t.Tenant, t.Slug, set, s.o.Now())
}
