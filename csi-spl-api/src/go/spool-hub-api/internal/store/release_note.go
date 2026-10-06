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
// release tag that carries it and a state. Estate-wide, not per tenant: every
// tenant runs the same code, so no call takes a tenant id.

// ReleaseNoteStates is rdb 0108's state CHECK (TestReleaseNotesPinRdbChecks):
// ok = the six trailers; missing = written before 065 or bypassed the rule;
// skip = `Release-Note: skip` (spec 5.2); revert = a git revert, linking the
// row it reverts; backfill = written after the fact by a backfill lane (Q6).
var ReleaseNoteStates = []string{"ok", "missing", "skip", "revert", "backfill"}

// The shapes rdb 0108's CHECKs enforce, so a refusal is a 400, not a 500.
var (
	releaseSHARe     = regexp.MustCompile(`^[0-9a-f]{40}$`)
	releaseRefRe     = regexp.MustCompile(`^[0-9a-f]{7,40}$`)
	releaseVersionRe = regexp.MustCompile(`^v([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})(?:-c([2-9]|[1-9][0-9]{1,3}))?$`)
	releaseKindRe    = regexp.MustCompile(`^[a-z]{0,16}$`)
	releaseLinkRe    = regexp.MustCompile(`^https://\S+$`)
)

// Release note limits (rdb 0108).
const (
	ReleaseSubjectMax  = 300
	ReleaseAreaMax     = 64
	ReleaseTrailerMax  = 500 // one Lay-* / Tech-* line; the rule asks ~200
	ReleaseLinkMax     = 300
	ReleaseBatchMax    = 500 // rows one put takes at most
	ReleaseVersionsMax = 50  // versions one list page carries at most (spec 7.1 item 4)
)

// ErrAmbiguousRef: a sha prefix matches more than one release note.
var ErrAmbiguousRef = errors.New("ambiguous sha prefix")

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
	PutReleaseNotes(ctx context.Context, batch []ReleaseNote, now time.Time) error
	// ReleaseNote reads one row by its full sha or a prefix of 7+ hex chars.
	// ErrNotFound when none matches, ErrAmbiguousRef when several do.
	ReleaseNote(ctx context.Context, ref string) (ReleaseNote, error)
	// ListReleaseNotes is every row of the newest `versions` versions
	// (capped at ReleaseVersionsMax) strictly older than before ("" = from
	// the newest): version newest first (numeric: cycle, then X.Y.Z), then
	// newest commit first, each with its Seq.
	// Rows with no version yet are not listed.
	ListReleaseNotes(ctx context.Context, before string, versions int) ([]ReleaseNote, error)
	// ReleaseNotesOfVersion is one version's rows, newest commit first, each
	// with its Seq (spec 7.2: /releases/v<X.Y.Z>[-c<N>]); version is the full key.
	ReleaseNotesOfVersion(ctx context.Context, version string) ([]ReleaseNote, error)
}

// CheckReleaseNote names the first field a row may not carry ("" = fine):
// the Go side of rdb 0108's CHECKs, so the ingest refuses before the insert.
func CheckReleaseNote(n ReleaseNote) string {
	trailers := []string{n.LayWhat, n.LayHow, n.LayWhy, n.TechWhat, n.TechHow, n.TechWhy}
	switch {
	case !releaseSHARe.MatchString(n.SHA):
		return "sha must be a full lowercase commit sha"
	case n.Version != "" && !releaseVersionRe.MatchString(n.Version):
		return "version must be v<X.Y.Z> or v<X.Y.Z>-c<N>"
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
	}
	return ""
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
	m := releaseVersionRe.FindStringSubmatch(v)
	if m == nil {
		return [4]int{}, false
	}
	// The Atoi errors are safe to drop: releaseVersionRe matched, so every
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
// the cycle dropped (owner, t1 e82eea7c: "version is just a number").
func ReleaseDisplay(version string) string {
	if i := strings.Index(version, "-c"); i >= 0 {
		return version[:i]
	}
	return version
}

// checkBefore is a list's before cursor: "" or a version.
func checkBefore(before string) error {
	if _, ok := releaseVersionKey(before); before != "" && !ok {
		return fmt.Errorf("before must be v<X.Y.Z> or v<X.Y.Z>-c<N>")
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

// sortReleaseNotes is the list order both drivers share.
func sortReleaseNotes(ns []ReleaseNote) {
	slices.SortStableFunc(ns, func(x, y ReleaseNote) int {
		a, _ := releaseVersionKey(x.Version)
		b, _ := releaseVersionKey(y.Version)
		return cmp.Or(slices.Compare(b[:], a[:]), y.CommittedAt.Compare(x.CommittedAt), cmp.Compare(x.SHA, y.SHA))
	})
}

// numberReleaseNotes sets Seq on the rows of out from every versioned row of
// all: the list order reversed, so the oldest is 1.
func numberReleaseNotes(all map[string]ReleaseNote, out []ReleaseNote) {
	var versioned []ReleaseNote
	for _, n := range all {
		if _, ok := releaseVersionKey(n.Version); ok {
			versioned = append(versioned, n)
		}
	}
	sortReleaseNotes(versioned)
	seq := make(map[string]int, len(versioned))
	for i, n := range versioned {
		seq[n.SHA] = len(versioned) - i
	}
	for i := range out {
		out[i].Seq = seq[out[i].SHA]
	}
}

// Memory side: a per-store map beside the Memory struct, as the perf samples
// keep their own.
var (
	memReleaseMu sync.Mutex
	memReleases  = map[*Memory]map[string]ReleaseNote{}
)

func (s *Memory) releases() map[string]ReleaseNote {
	r := memReleases[s]
	if r == nil {
		r = map[string]ReleaseNote{}
		memReleases[s] = r
	}
	return r
}

func (s *Memory) PutReleaseNotes(_ context.Context, batch []ReleaseNote, now time.Time) error {
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
		if old, ok := r[n.SHA]; ok && old.Version != "" {
			n.Version = old.Version
		}
		n.CommittedAt, n.IngestedAt = n.CommittedAt.UTC(), now.UTC()
		r[n.SHA] = n
	}
	return nil
}

func (s *Memory) ReleaseNote(_ context.Context, ref string) (ReleaseNote, error) {
	ref, err := CheckReleaseRef(ref)
	if err != nil {
		return ReleaseNote{}, err
	}
	memReleaseMu.Lock()
	defer memReleaseMu.Unlock()
	var hit []ReleaseNote
	for sha, n := range s.releases() {
		if strings.HasPrefix(sha, ref) {
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

func (s *Memory) ListReleaseNotes(_ context.Context, before string, versions int) ([]ReleaseNote, error) {
	if err := checkBefore(before); err != nil {
		return nil, err
	}
	cut, _ := releaseVersionKey(before)
	memReleaseMu.Lock()
	defer memReleaseMu.Unlock()
	keep := map[string]bool{}
	var keys [][4]int
	for _, n := range s.releases() {
		k, ok := releaseVersionKey(n.Version)
		if !ok || keep[n.Version] || (before != "" && slices.Compare(k[:], cut[:]) >= 0) {
			continue
		}
		keep[n.Version] = true
		keys = append(keys, k)
	}
	slices.SortFunc(keys, func(a, b [4]int) int { return slices.Compare(b[:], a[:]) })
	page := map[[4]int]bool{}
	for _, k := range keys[:min(len(keys), ClampReleaseVersions(versions))] {
		page[k] = true
	}
	out := []ReleaseNote{}
	for _, n := range s.releases() {
		if k, ok := releaseVersionKey(n.Version); ok && page[k] {
			out = append(out, n)
		}
	}
	sortReleaseNotes(out)
	numberReleaseNotes(s.releases(), out)
	return out, nil
}

func (s *Memory) ReleaseNotesOfVersion(_ context.Context, version string) ([]ReleaseNote, error) {
	if _, ok := releaseVersionKey(version); !ok {
		return nil, fmt.Errorf("version must be v<X.Y.Z> or v<X.Y.Z>-c<N>")
	}
	memReleaseMu.Lock()
	defer memReleaseMu.Unlock()
	out := []ReleaseNote{}
	for _, n := range s.releases() {
		if n.Version == version {
			out = append(out, n)
		}
	}
	sortReleaseNotes(out)
	numberReleaseNotes(s.releases(), out)
	return out, nil
}
