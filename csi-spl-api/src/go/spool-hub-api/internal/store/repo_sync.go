package store

import (
	"context"
	"errors"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
)

// The hub's own GitHub sync, its store side (spec 143 releases-projects.md
// row B-6b, spec 171 section 3.4.1, SPL-5808). The sync walks every
// workspace_repos row it can read from GitHub, stores the new commits
// through the ingest's buildRows and PutReleaseNotes, versions the commits a
// later tag covers, and writes its cursor and outcome back on the row. Every
// call here runs in the operator scope: the loop belongs to no workspace,
// and rdb 0266 lets only that scope write workspace_repos. No migration: the
// columns are 0266's.

// RepoSyncTarget is one workspace_repos row as the sync reads it. It holds
// no credential: the installation id is a public id, and a sealed token has
// no store yet (auth_mode pat_kms is written back as an error).
type RepoSyncTarget struct {
	Tenant          string
	Slug            string
	TrunkBranch     string
	VersionTagGlob  string
	AreaStripPrefix string
	AuthMode        string
	InstallationID  int64
	LastSyncedSHA   string
	SyncStatus      string
}

// RepoSyncState is what one sync writes back. SHA "" keeps the cursor.
type RepoSyncState struct {
	SHA    string
	At     time.Time
	Status string // ok | error
	Error  string
}

// UnversionedNote is a stored commit no tag covers yet.
type UnversionedNote struct {
	SHA         string
	CommittedAt time.Time
}

// RepoSyncErrorMax clips a written-back sync_error.
const RepoSyncErrorMax = 500

// repoSyncUnversionedMax caps the unversioned rows one read answers.
const repoSyncUnversionedMax = 5000

// RepoSync is the sync's store.
type RepoSync interface {
	// RepoSyncTargets is every repo of every workspace whose auth_mode the
	// hub syncs (github_app, public, pat_kms), workspace then slug order.
	RepoSyncTargets(ctx context.Context) ([]RepoSyncTarget, error)
	// PutRepoSyncState writes st back on tenant's repo slug. ErrNotFound
	// when tenant has no such repo.
	PutRepoSyncState(ctx context.Context, tenant, slug string, st RepoSyncState) error
	// UnversionedReleaseNotes is the repo's stored commits with no version,
	// oldest first.
	UnversionedReleaseNotes(ctx context.Context, tenant, repo string) ([]UnversionedNote, error)
	// SetReleaseVersions sets the version of each sha that has none yet,
	// released at now (first seen); it answers how many rows it set.
	SetReleaseVersions(ctx context.Context, tenant, repo string, versions map[string]string, now time.Time) (int, error)
	// TryRepoSyncLock holds slug's sync for this hub instance; ok false when
	// another holds it. The caller calls release once done.
	TryRepoSyncLock(ctx context.Context, slug string) (release func(), ok bool, err error)
}

var (
	_ RepoSync = (*Postgres)(nil)
	_ RepoSync = (*Memory)(nil)
)

// RepoSyncedModes are the auth modes the hub syncs; ingest_only rows are
// pushed by a box (row B-6) and never read from GitHub.
var RepoSyncedModes = []string{"github_app", "public", "pat_kms"}

// checkRepoSyncState refuses a state the row's CHECK would.
func checkRepoSyncState(tenant, slug string, st *RepoSyncState) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if strings.TrimSpace(slug) == "" {
		return errors.New("repo sync state needs a repo")
	}
	if st.Status != "ok" && st.Status != "error" {
		return errors.New("sync status must be ok or error")
	}
	if st.SHA != "" && !releaseSHARe.MatchString(st.SHA) {
		return errors.New("last synced sha must be a full lowercase commit sha")
	}
	st.Error = clipText(st.Error, RepoSyncErrorMax)
	return nil
}

// clipText cuts s to max bytes on a rune boundary.
func clipText(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return strings.ToValidUTF8(s[:max], "")
}

// checkReleaseVersions refuses a version the row's check would.
func checkReleaseVersions(tenant, repo string, versions map[string]string) error {
	if err := checkReleaseScope(tenant, repo); err != nil {
		return err
	}
	for sha, v := range versions {
		if !releaseSHARe.MatchString(sha) || !releaseVersionRe.MatchString(v) {
			return errors.New("release versions need full shas and tag-shaped versions")
		}
	}
	return nil
}

// Memory side: the sync's view of each registered repo, beside memRepos.
var (
	memRepoSyncMu sync.Mutex
	memRepoSync   = map[*Memory]map[[2]string]RepoSyncTarget{}
	memRepoLocks  = map[*Memory]map[string]bool{}
)

// SeedRepoSync sets the sync fields of a repo SeedWorkspaceRepo registered
// (the memory store has no registration route). Empty fields keep rdb
// 0266's defaults: trunk main, glob v*, auth github_app, status pending.
func (s *Memory) SeedRepoSync(t RepoSyncTarget) {
	memRepoSyncMu.Lock()
	defer memRepoSyncMu.Unlock()
	if memRepoSync[s] == nil {
		memRepoSync[s] = map[[2]string]RepoSyncTarget{}
	}
	memRepoSync[s][[2]string{t.Tenant, t.Slug}] = t
}

// memRepoTarget is a registered repo with its seeded fields and defaults.
// The caller holds memRepoSyncMu.
func (s *Memory) memRepoTarget(tenant, slug string) RepoSyncTarget {
	t := memRepoSync[s][[2]string{tenant, slug}]
	t.Tenant, t.Slug = tenant, slug
	t.TrunkBranch = cmpOr(t.TrunkBranch, "main")
	t.VersionTagGlob = cmpOr(t.VersionTagGlob, "v*")
	t.AuthMode = cmpOr(t.AuthMode, "github_app")
	t.SyncStatus = cmpOr(t.SyncStatus, "pending")
	return t
}

func cmpOr(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

// RepoSyncTargets is RepoSync on the memory store.
func (s *Memory) RepoSyncTargets(_ context.Context) ([]RepoSyncTarget, error) {
	memRepoMu.Lock()
	type key struct{ tenant, slug string }
	var keys []key
	for tenant, repos := range memRepos[s] {
		for slug := range repos {
			keys = append(keys, key{tenant, slug})
		}
	}
	memRepoMu.Unlock()
	sort.Slice(keys, func(i, j int) bool {
		return keys[i].tenant < keys[j].tenant || (keys[i].tenant == keys[j].tenant && keys[i].slug < keys[j].slug)
	})
	memRepoSyncMu.Lock()
	defer memRepoSyncMu.Unlock()
	out := []RepoSyncTarget{}
	for _, k := range keys {
		if t := s.memRepoTarget(k.tenant, k.slug); slices.Contains(RepoSyncedModes, t.AuthMode) {
			out = append(out, t)
		}
	}
	return out, nil
}

// PutRepoSyncState is RepoSync on the memory store.
func (s *Memory) PutRepoSyncState(_ context.Context, tenant, slug string, st RepoSyncState) error {
	if err := checkRepoSyncState(tenant, slug, &st); err != nil {
		return err
	}
	memRepoMu.Lock()
	_, known := memRepos[s][tenant][slug]
	memRepoMu.Unlock()
	if !known {
		return ErrNotFound
	}
	memRepoSyncMu.Lock()
	defer memRepoSyncMu.Unlock()
	t := s.memRepoTarget(tenant, slug)
	if st.SHA != "" {
		t.LastSyncedSHA = st.SHA
	}
	t.SyncStatus = st.Status
	if memRepoSync[s] == nil {
		memRepoSync[s] = map[[2]string]RepoSyncTarget{}
	}
	memRepoSync[s][[2]string{tenant, slug}] = t
	return nil
}

// UnversionedReleaseNotes is RepoSync on the memory store.
func (s *Memory) UnversionedReleaseNotes(_ context.Context, tenant, repo string) ([]UnversionedNote, error) {
	if err := checkReleaseScope(tenant, repo); err != nil {
		return nil, err
	}
	memReleaseMu.Lock()
	defer memReleaseMu.Unlock()
	out := []UnversionedNote{}
	for _, n := range s.repoReleases(tenant, repo) {
		if n.Version == "" {
			out = append(out, UnversionedNote{SHA: n.SHA, CommittedAt: n.CommittedAt})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CommittedAt.Before(out[j].CommittedAt) })
	if len(out) > repoSyncUnversionedMax {
		out = out[len(out)-repoSyncUnversionedMax:]
	}
	return out, nil
}

// SetReleaseVersions is RepoSync on the memory store.
func (s *Memory) SetReleaseVersions(_ context.Context, tenant, repo string, versions map[string]string, now time.Time) (int, error) {
	if err := checkReleaseVersions(tenant, repo, versions); err != nil {
		return 0, err
	}
	memReleaseMu.Lock()
	defer memReleaseMu.Unlock()
	r, set := s.releases(), 0
	for sha, v := range versions {
		k := memReleaseKey{tenant, repo, sha}
		n, ok := r[k]
		if !ok || n.Version != "" {
			continue
		}
		n.Version = v
		r[k] = n
		if memReleased[s] == nil {
			memReleased[s] = map[memReleaseKey]time.Time{}
		}
		memReleased[s][k] = now.UTC()
		set++
	}
	return set, nil
}

// TryRepoSyncLock is RepoSync on the memory store: a set of held slugs.
func (s *Memory) TryRepoSyncLock(_ context.Context, slug string) (func(), bool, error) {
	memRepoSyncMu.Lock()
	defer memRepoSyncMu.Unlock()
	if memRepoLocks[s] == nil {
		memRepoLocks[s] = map[string]bool{}
	}
	if memRepoLocks[s][slug] {
		return nil, false, nil
	}
	memRepoLocks[s][slug] = true
	return func() {
		memRepoSyncMu.Lock()
		delete(memRepoLocks[s], slug)
		memRepoSyncMu.Unlock()
	}, true, nil
}
