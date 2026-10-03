package hub

import (
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The ingest's commit parse (spec 065 4.1, 5.2) and hygiene filter (spec 3,
// option C: commit messages are outside the distribution-hygiene sweep, so a
// row is filtered before it is stored and shown).

// releaseNoteIn is one ingest row. The caller (L5, the deploy) sends the sha,
// its minted version, the commit date and either the full commit Message (the
// hub parses subject, kind, scope and trailers) or the fields already split.
// Note is a refs/notes/release-notes note (spec 6.1): its trailers win over
// the message's. A non-empty explicit field wins over both. State "" is
// derived; "backfill" marks a note written after the fact (Q6). DocOnly lets
// Lay-What + Lay-Why suffice (spec 5.2, Q5).
type releaseNoteIn struct {
	SHA         string    `json:"sha"`
	Version     string    `json:"version"`
	CommittedAt time.Time `json:"committed_at"`
	Message     string    `json:"message"`
	Note        string    `json:"note"`
	DocOnly     bool      `json:"doc_only"`
	State       string    `json:"state"`
	Area        string    `json:"area"`
	Link        string    `json:"link"`
	Kind        string    `json:"kind"`
	Subject     string    `json:"subject"`
	LayWhat     string    `json:"lay_what"`
	LayHow      string    `json:"lay_how"`
	LayWhy      string    `json:"lay_why"`
	TechWhat    string    `json:"tech_what"`
	TechHow     string    `json:"tech_how"`
	TechWhy     string    `json:"tech_why"`
	Reverts     string    `json:"reverts"`
}

var (
	releaseSubjectRe = regexp.MustCompile(`^([a-z]{1,16})(?:\(([^)]*)\))?!?:\s*`)
	releaseTrailerRe = regexp.MustCompile(`(?i)^(lay-what|lay-how|lay-why|tech-what|tech-how|tech-why|release-note):[ \t]*(.*?)\s*$`)
	releaseRevertRe  = regexp.MustCompile(`This reverts commit ([0-9a-f]{40})`)
)

// releaseTrailers reads the Lay-* / Tech-* / Release-Note trailers of a text,
// keyed lowercase; the last occurrence of a key wins.
func releaseTrailers(text string) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(text, "\n") {
		if m := releaseTrailerRe.FindStringSubmatch(strings.TrimRight(line, "\r")); m != nil && m[2] != "" {
			out[strings.ToLower(m[1])] = m[2]
		}
	}
	return out
}

// pick is the first non-empty value.
func pick(vs ...string) string {
	for _, v := range vs {
		if v != "" {
			return v
		}
	}
	return ""
}

// clip cuts s to max bytes on a rune boundary (a long subject or trailer is
// shortened, not lost).
func clip(s string, max int) string {
	if len(s) <= max {
		return s
	}
	s = s[:max]
	for !utf8.ValidString(s) {
		s = s[:len(s)-1]
	}
	return s
}

// row is the store row: parsed, overlaid, clipped and given its state.
func (in releaseNoteIn) row() store.ReleaseNote {
	subject, _, _ := strings.Cut(strings.TrimSpace(in.Message), "\n")
	subject = pick(in.Subject, strings.TrimSpace(subject))
	kind, area := "", in.Area
	if m := releaseSubjectRe.FindStringSubmatch(subject); m != nil {
		kind = m[1]
		area = pick(strings.TrimSpace(m[2]), area)
	}
	msg, note := releaseTrailers(in.Message), releaseTrailers(in.Note)
	tr := func(field, key string) string {
		return clip(pick(field, note[key], msg[key]), store.ReleaseTrailerMax)
	}
	n := store.ReleaseNote{
		SHA: strings.ToLower(in.SHA), Version: in.Version, CommittedAt: in.CommittedAt,
		Kind: pick(in.Kind, kind), Area: clip(area, store.ReleaseAreaMax),
		Subject: clip(subject, store.ReleaseSubjectMax), Link: in.Link,
		LayWhat: tr(in.LayWhat, "lay-what"), LayHow: tr(in.LayHow, "lay-how"), LayWhy: tr(in.LayWhy, "lay-why"),
		TechWhat: tr(in.TechWhat, "tech-what"), TechHow: tr(in.TechHow, "tech-how"), TechWhy: tr(in.TechWhy, "tech-why"),
		State: in.State, Reverts: strings.ToLower(in.Reverts),
	}
	if m := releaseRevertRe.FindStringSubmatch(in.Message); m != nil && n.Reverts == "" {
		n.Reverts = m[1]
	}
	if n.State == "" {
		n.State = releaseState(n, in.DocOnly, strings.EqualFold(pick(note["release-note"], msg["release-note"]), "skip"))
	}
	if n.State != "revert" {
		n.Reverts = ""
	}
	return n
}

// releaseState derives the state (spec 4.2, 5.2): a revert, then an explicit
// skip, then ok when the note is complete (doc-only: Lay-What + Lay-Why),
// else missing.
func releaseState(n store.ReleaseNote, docOnly, skip bool) string {
	switch {
	case n.Reverts != "" || strings.HasPrefix(n.Subject, `Revert "`):
		return "revert"
	case skip:
		return "skip"
	case n.LayWhat != "" && n.LayWhy != "" && (docOnly || (n.LayHow != "" && n.TechWhat != "" && n.TechHow != "" && n.TechWhy != "")):
		return "ok"
	}
	return "missing"
}

// releaseFilter is the hygiene filter: every match in a shown field becomes
// releaseRedacted. The built-in patterns carry no literal (mail addresses,
// home directories, URLs: a host); the configured ones are the sweep's bans.
type releaseFilter []*regexp.Regexp

var releaseBuiltinBans = []string{
	`[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}`,
	`/home/[a-z][a-z0-9_-]*`,
	`(?i)\b[a-z][a-z0-9+.-]*://\S+`,
}

// newReleaseFilter is the built-in bans plus one RE2 pattern per non-empty
// line of extra. A pattern that does not compile is reported to bad and
// skipped.
func newReleaseFilter(extra string, bad func(string, error)) releaseFilter {
	var f releaseFilter
	for _, p := range append(append([]string{}, releaseBuiltinBans...), strings.Split(extra, "\n")...) {
		if p = strings.TrimSpace(p); p == "" {
			continue
		}
		re, err := regexp.Compile(p)
		if err != nil {
			bad(p, err)
			continue
		}
		f = append(f, re)
	}
	return f
}

// apply redacts every shown text field of n; true when anything matched.
func (f releaseFilter) apply(n *store.ReleaseNote) bool {
	hit := false
	for _, p := range []*string{&n.Subject, &n.Area, &n.LayWhat, &n.LayHow, &n.LayWhy, &n.TechWhat, &n.TechHow, &n.TechWhy} {
		for _, re := range f {
			if re.MatchString(*p) {
				*p, hit = re.ReplaceAllLiteralString(*p, releaseRedacted), true
			}
		}
	}
	return hit
}
