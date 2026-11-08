package store

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The release notes table (spec 065 section 4.2, rdb 0108): one row per trunk
// commit, the six Lay-* / Tech-* trailers of its message (spec 4.1), the first
// release tag that carries it and a state. Each row belongs to one repo of one
// workspace (rdb 0267, spec 143 releases-projects.md row B-2), so every call
// names the tenant.

// ReleaseNoteStates is rdb 0108's state CHECK (TestReleaseNotesPinRdbChecks):
// ok = the six trailers; missing = written before 065 or bypassed the rule;
// skip = `Release-Note: skip` (spec 5.2); revert = a git revert, linking the
// row it reverts; backfill = written after the fact by a backfill lane (Q6).
var ReleaseNoteStates = []string{"ok", "missing", "skip", "revert", "backfill"}

// The shapes rdb 0108's CHECKs enforce, so a refusal is a 400, not a 500.
var (
	releaseSHARe = regexp.MustCompile(`^[0-9a-f]{40}$`)
	releaseRefRe = regexp.MustCompile(`^[0-9a-f]{7,40}$`)
	// releaseVersionRe is any tag a repo may use (rdb 0267); releaseKeyRe is
	// csi-spl's own shape, the only one with a numeric sort key.
	releaseVersionRe  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$`)
	releaseKeyRe      = regexp.MustCompile(`^v([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})(?:-c([2-9]|[1-9][0-9]{1,3}))?$`)
	releaseCycleRe    = regexp.MustCompile(`-c([2-9]|[1-9][0-9]{1,3})$`)
	releaseKindRe     = regexp.MustCompile(`^[a-z]{0,16}$`)
	releaseLinkRe     = regexp.MustCompile(`^https://\S+$`)
	releaseIssueKeyRe = regexp.MustCompile(`^[A-Z][A-Z0-9]{0,9}-[0-9]{1,9}$`)
)

// Release note limits (rdb 0108).
const (
	ReleaseSubjectMax   = 300
	ReleaseAreaMax      = 64
	ReleaseTrailerMax   = 500 // one Lay-* / Tech-* line; the rule asks ~200
	ReleaseLinkMax      = 300
	ReleaseBatchMax     = 500 // rows one put takes at most
	ReleaseVersionsMax  = 50  // versions one list page carries at most (spec 7.1 item 4)
	ReleaseIssueKeysMax = 20  // issue keys one row names at most (rdb 0261)
)

// ErrAmbiguousRef: a sha prefix matches more than one release note.
var ErrAmbiguousRef = errors.New("ambiguous sha prefix")

// errReleaseVersionShape refuses a before cursor or a version outside rdb 0267.
var errReleaseVersionShape = errors.New("version must be 1..64 letters, digits or . _ + -, starting with a letter or digit")

// ReleaseNote is one row of release_notes. Version is the release key, the
// full tag (rdb 0114): v<X.Y.Z> in cycle 1, v<X.Y.Z>-c<N> from cycle 2 on
// (after 9.9.9 the mint starts over at 1.0.1), so two cycles' same X.Y.Z
// stay two versions; ReleaseDisplay is what a reader sees. Version "" is
// NULL: the commit is on trunk but no deploy has minted a tag over it yet. Reverts is the sha a
// revert row reverts ("" otherwise). Seq is the row's rolling number among
// the versioned rows, 1 = the oldest (the list order reversed), so the
// newest row carries n (owner, t1 55b6de46: "# rolling id, starting from
// the oldest"); set by ListReleaseNotes and ReleaseNotesOfVersion, 0 elsewhere.
type ReleaseNote struct {
	TenantID    string    `json:"-"`
	RepoSlug    string    `json:"-"`
	SHA         string    `json:"sha"`
	Version     string    `json:"version,omitempty"`
	CommittedAt time.Time `json:"committed_at"`
	Kind        string    `json:"kind"`
	Area        string    `json:"area"`
	Subject     string    `json:"subject"`
	LayWhat     string    `json:"lay_what"`
	LayHow      string    `json:"lay_how"`
	LayWhy      string    `json:"lay_why"`
	TechWhat    string    `json:"tech_what"`
	TechHow     string    `json:"tech_how"`
	TechWhy     string    `json:"tech_why"`
	State       string    `json:"state"`
	Reverts     string    `json:"reverts,omitempty"`
	Link        string    `json:"link"`
	IngestedAt  time.Time `json:"ingested_at"`
	Seq         int       `json:"seq,omitempty"`
	// IssueTenant is the workspace whose issues IssueKeys are (rdb 0261,
	// SPL-4789); "" until an ingest names it. IssueKeys are the keys of its
	// issue prefix the message cites, subject first (ReleaseIssueKeys).
	IssueTenant string   `json:"-"`
	IssueKeys   []string `json:"issue_keys"`
	// ReleasedAt is the time the row ranks by, released_at else committed_at;
	// set by reads.
	ReleasedAt time.Time `json:"-"`
}

// ReleaseNotes is the store half of spec 065. Optional: the hub's routes
// answer as off on a store without it.
type ReleaseNotes interface {
	// PutReleaseNotes upserts the batch (at most ReleaseBatchMax rows, each
	// already checked by CheckReleaseNote) in one transaction, stamping
	// ingested_at = now. A row already stored keeps its version once it has
	// one (the FIRST tag that carries the commit, spec 4.2); every other
	// column takes the new value, so a re-ingest or a correction note
	// (spec 6.1) replaces the text.
	PutReleaseNotes(ctx context.Context, tenant, repo string, batch []ReleaseNote, now time.Time) error
	// ReleaseNote reads one row of tenant by its full sha or a prefix of 7+
	// hex chars. ErrNotFound when none matches, ErrAmbiguousRef when several
	// do, which includes one sha stored in two repos of the workspace.
	ReleaseNote(ctx context.Context, tenant, ref string) (ReleaseNote, error)
	// ListReleaseNotes is every row of the newest `versions` versions
	// (capped at ReleaseVersionsMax) strictly older than before ("" = from
	// the newest), of tenant: version newest first (numeric: cycle, then
	// X.Y.Z; a tag with no key after those, by its newest row), then newest
	// row first, each with its Seq.
	// Rows with no version yet are not listed.
	ListReleaseNotes(ctx context.Context, tenant, before string, versions int) ([]ReleaseNote, error)
	// ReleaseNotesOfVersion is one version's rows of tenant, newest row first,
	// each with its Seq (spec 7.2: /releases/<version>); version is the full tag.
	ReleaseNotesOfVersion(ctx context.Context, tenant, version string) ([]ReleaseNote, error)
}

// CheckReleaseNote names the first field a row may not carry ("" = fine):
// the Go side of rdb 0108's CHECKs, so the ingest refuses before the insert.
func CheckReleaseNote(n ReleaseNote) string {
	trailers := []string{n.LayWhat, n.LayHow, n.LayWhy, n.TechWhat, n.TechHow, n.TechWhy}
	switch {
	case !releaseSHARe.MatchString(n.SHA):
		return "sha must be a full lowercase commit sha"
	case n.Version != "" && !releaseVersionRe.MatchString(n.Version):
		return errReleaseVersionShape.Error()
	case n.CommittedAt.IsZero():
		return "committed_at is required"
	case !releaseKindRe.MatchString(n.Kind):
		return "kind must be a lowercase subject prefix (up to 16)"
	case len(n.Area) > ReleaseAreaMax || hasControl(n.Area):
		return "area must be one line of up to 64 bytes"
	case n.Subject == "" || len(n.Subject) > ReleaseSubjectMax || hasControl(n.Subject):
		return "subject must be one line of 1..300 bytes"
	case slices.ContainsFunc(trailers, func(s string) bool { return len(s) > ReleaseTrailerMax || hasControl(s) }):
		return "each Lay-* / Tech-* field must be one line of up to 500 bytes"
	case !slices.Contains(ReleaseNoteStates, n.State):
		return "state must be one of " + strings.Join(ReleaseNoteStates, ", ")
	case n.Reverts != "" && (n.State != "revert" || !releaseSHARe.MatchString(n.Reverts)):
		return "reverts must be a full sha, on a revert row only"
	case n.Link != "" && (len(n.Link) > ReleaseLinkMax || !releaseLinkRe.MatchString(n.Link)):
		return "link must be an https URL"
	case len(n.IssueTenant) > 64:
		return "issue_tenant must be up to 64 bytes"
	case len(n.IssueKeys) > ReleaseIssueKeysMax || slices.ContainsFunc(n.IssueKeys, func(k string) bool { return !releaseIssueKeyRe.MatchString(k) }):
		return "issue_keys must be up to 20 keys <PREFIX>-<n>"
	}
	return ""
}

// ReleaseIssueKeys is every <prefix>-<n> key a commit message cites, in the
// order it first appears (the subject comes first in a message), at most
// ReleaseIssueKeysMax, never nil. A key is a whole word: SPL-12 in
// "xSPL-12" or "SPL-12a" is not one. prefix "" finds none.
func ReleaseIssueKeys(prefix, message string) []string {
	out := []string{}
	if prefix == "" {
		return out
	}
	re := regexp.MustCompile(`(?:^|[^A-Za-z0-9_-])(` + regexp.QuoteMeta(prefix) + `-[1-9][0-9]{0,8})(?:$|[^A-Za-z0-9_])`)
	seen := map[string]bool{}
	for i := 0; i < len(message) && len(out) < ReleaseIssueKeysMax; {
		m := re.FindStringSubmatchIndex(message[i:])
		if m == nil {
			break
		}
		k := message[i+m[2] : i+m[3]]
		if !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
		i += m[3]
	}
	return out
}

// CheckReleaseRef is a sha or sha prefix as ReleaseNote takes it, lowercased.
func CheckReleaseRef(ref string) (string, error) {
	ref = strings.ToLower(ref)
	if !releaseRefRe.MatchString(ref) {
		return "", fmt.Errorf("ref must be 7..40 hex chars of a commit sha")
	}
	return ref, nil
}

// releaseVersionKey is a release key as numbers {cycle, X, Y, Z} (no -c<N>
// = cycle 1): the order both drivers page by. ok false when it is not one.
func releaseVersionKey(v string) ([4]int, bool) {
	m := releaseKeyRe.FindStringSubmatch(v)
	if m == nil {
		return [4]int{}, false
	}
	// The Atoi errors are safe to drop: releaseKeyRe matched, so every
	// group is 1..6 ASCII digits, which always parse and fit an int.
	k := [4]int{1}
	if m[4] != "" {
		k[0], _ = strconv.Atoi(m[4])
	}
	for i := 1; i < 4; i++ {
		k[i], _ = strconv.Atoi(m[i])
	}
	return k, true
}

// ReleaseDisplay is a release key as a reader sees it: the plain v<X.Y.Z>,
// the cycle dropped (owner, t1 e82eea7c: "version is just a number"). Only a
// real trailing cycle goes, so v1.0.0-cool stays whole.
func ReleaseDisplay(version string) string {
	return releaseCycleRe.ReplaceAllString(version, "")
}

// checkBefore is a list's before cursor: "" or a version.
func checkBefore(before string) error {
	if before != "" && !releaseVersionRe.MatchString(before) {
		return errReleaseVersionShape
	}
	return nil
}

// ClampReleaseVersions is a page size within 1..ReleaseVersionsMax (0 = the max).
func ClampReleaseVersions(n int) int {
	if n <= 0 || n > ReleaseVersionsMax {
		return ReleaseVersionsMax
	}
	return n
}

// sortReleaseNotes is the list order both drivers share: the keyed versions
// newest first, then the other tags by their newest row, and within a version
// the newest row first. A version's rows stay together because a tag with no
// key ranks by its newest row, so every row of ns must carry its ReleasedAt
// and ns must hold each version whole.
func sortReleaseNotes(ns []ReleaseNote) {
	newest := map[string]time.Time{}
	for _, n := range ns {
		if n.ReleasedAt.After(newest[n.Version]) {
			newest[n.Version] = n.ReleasedAt
		}
	}
	slices.SortStableFunc(ns, func(x, y ReleaseNote) int {
		a, aKeyed := releaseVersionKey(x.Version)
		b, bKeyed := releaseVersionKey(y.Version)
		order := 0
		switch {
		case aKeyed && !bKeyed:
			order = -1
		case !aKeyed && bKeyed:
			order = 1
		case aKeyed:
			order = slices.Compare(b[:], a[:])
		default:
			order = newest[y.Version].Compare(newest[x.Version])
		}
		return cmp.Or(order, cmp.Compare(x.Version, y.Version), y.ReleasedAt.Compare(x.ReleasedAt),
			y.CommittedAt.Compare(x.CommittedAt), cmp.Compare(x.SHA, y.SHA), cmp.Compare(x.RepoSlug, y.RepoSlug))
	})
}

// numberReleaseNotes sets Seq on the rows of out from every versioned row of
// all: the list order reversed, so the oldest is 1.
func numberReleaseNotes(all, out []ReleaseNote) {
	var versioned []ReleaseNote
	for _, n := range all {
		if n.Version != "" {
			versioned = append(versioned, n)
		}
	}
	sortReleaseNotes(versioned)
	seq := make(map[[2]string]int, len(versioned))
	for i, n := range versioned {
		seq[[2]string{n.RepoSlug, n.SHA}] = len(versioned) - i
	}
	for i := range out {
		out[i].Seq = seq[[2]string{out[i].RepoSlug, out[i].SHA}]
	}
}

// memReleaseKey is rdb 0267's unique index release_notes_tenant_repo_sha.
type memReleaseKey struct{ tenant, repo, sha string }

// Memory side: a per-store map beside the Memory struct, as the perf samples
// keep their own.
var (
	memReleaseMu sync.Mutex
	memReleases  = map[*Memory]map[memReleaseKey]ReleaseNote{}
	// memReleased is released_at per row (rdb 0177), set once.
	memReleased = map[*Memory]map[memReleaseKey]time.Time{}
)

func (s *Memory) releases() map[memReleaseKey]ReleaseNote {
	r := memReleases[s]
	if r == nil {
		r = map[memReleaseKey]ReleaseNote{}
		memReleases[s] = r
	}
	return r
}

// tenantReleases is tenant's rows, ReleasedAt set as releaseNoteCols sets it.
// The caller holds memReleaseMu.
func (s *Memory) tenantReleases(tenant string) []ReleaseNote {
	out := []ReleaseNote{}
	for k, n := range s.releases() {
		if k.tenant != tenant {
			continue
		}
		n.ReleasedAt = n.CommittedAt
		if at, ok := memReleased[s][k]; ok {
			n.ReleasedAt = at
		}
		out = append(out, n)
	}
	return out
}

func (s *Memory) PutReleaseNotes(_ context.Context, tenant, repo string, batch []ReleaseNote, now time.Time) error {
	if err := checkReleaseScope(tenant, repo); err != nil {
		return err
	}
	if len(batch) > ReleaseBatchMax {
		return fmt.Errorf("release note batch of %d rows, max %d", len(batch), ReleaseBatchMax)
	}
	memReleaseMu.Lock()
	defer memReleaseMu.Unlock()
	r := s.releases()
	last := map[string]int{}
	for i, n := range batch {
		last[n.SHA] = i
	}
	for i, n := range batch {
		if last[n.SHA] != i {
			continue // the last row of a sha wins, as in Postgres
		}
		k := memReleaseKey{tenant, repo, n.SHA}
		n.TenantID, n.RepoSlug = tenant, repo
		if old, ok := r[k]; ok && old.Version != "" {
			n.Version = old.Version
		}
		if old, ok := r[k]; ok && n.IssueTenant == "" {
			n.IssueTenant, n.IssueKeys = old.IssueTenant, old.IssueKeys
		}
		if n.IssueKeys == nil {
			n.IssueKeys = []string{}
		}
		if rel := memReleased[s]; n.Version != "" && rel[k].IsZero() {
			if rel == nil {
				rel = map[memReleaseKey]time.Time{}
				memReleased[s] = rel
			}
			rel[k] = now.UTC()
		}
		n.CommittedAt, n.IngestedAt = n.CommittedAt.UTC(), now.UTC()
		r[k] = n
	}
	return nil
}

func (s *Memory) ReleaseNote(_ context.Context, tenant, ref string) (ReleaseNote, error) {
	ref, err := CheckReleaseRef(ref)
	if err != nil {
		return ReleaseNote{}, err
	}
	if err := checkTenant(tenant); err != nil {
		return ReleaseNote{}, err
	}
	memReleaseMu.Lock()
	defer memReleaseMu.Unlock()
	var hit []ReleaseNote
	for _, n := range s.tenantReleases(tenant) {
		if strings.HasPrefix(n.SHA, ref) {
			hit = append(hit, n)
		}
	}
	switch len(hit) {
	case 0:
		return ReleaseNote{}, ErrNotFound
	case 1:
		return hit[0], nil
	}
	return ReleaseNote{}, ErrAmbiguousRef
}

func (s *Memory) ListReleaseNotes(_ context.Context, tenant, before string, versions int) ([]ReleaseNote, error) {
	if err := checkBefore(before); err != nil {
		return nil, err
	}
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	memReleaseMu.Lock()
	defer memReleaseMu.Unlock()
	all := s.tenantReleases(tenant)
	sorted := slices.DeleteFunc(slices.Clone(all), func(n ReleaseNote) bool { return n.Version == "" })
	sortReleaseNotes(sorted)
	page := releasePage(sorted, before, ClampReleaseVersions(versions))
	out := slices.DeleteFunc(sorted, func(n ReleaseNote) bool { return !page[n.Version] })
	numberReleaseNotes(all, out)
	return out, nil
}

// releasePage is the versions of one page of sorted, the rows past before.
func releasePage(sorted []ReleaseNote, before string, limit int) map[string]bool {
	cut, cutKeyed := releaseVersionKey(before)
	passed := before == ""
	page := map[string]bool{}
	for _, n := range sorted {
		k, keyed := releaseVersionKey(n.Version)
		if before != "" && n.Version == before {
			passed = true
			continue
		}
		if cutKeyed && (!keyed || slices.Compare(k[:], cut[:]) < 0) {
			passed = true
		}
		if !passed || page[n.Version] {
			continue
		}
		if len(page) == limit {
			break
		}
		page[n.Version] = true
	}
	return page
}

func (s *Memory) ReleaseNotesOfVersion(_ context.Context, tenant, version string) ([]ReleaseNote, error) {
	if !releaseVersionRe.MatchString(version) {
		return nil, errReleaseVersionShape
	}
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	memReleaseMu.Lock()
	defer memReleaseMu.Unlock()
	all := s.tenantReleases(tenant)
	out := slices.DeleteFunc(slices.Clone(all), func(n ReleaseNote) bool { return n.Version != version })
	// A tag with no key ranks by its newest row; out holds that version whole.
	sortReleaseNotes(out)
	numberReleaseNotes(all, out)
	return out, nil
}
