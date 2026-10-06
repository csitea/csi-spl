package repodocs

import (
	_ "embed"
	"encoding/base64"
	"fmt"
	"strings"
)

// Hit is one rule matching one new line of a save (spec §5.1: 422
// rejected_text names the rule and the line). It never carries the matched
// text: a secret-scan hit must not echo the secret back.
type Hit struct {
	Kind string `json:"kind"` // "hygiene", "secret", or "gate" when the gate cannot run
	Rule string `json:"rule"` // the rule's label
	Line int    `json:"line"` // 1-based line of the new text; 0 for a "gate" hit
}

// Rule kinds.
const (
	KindHygiene = "hygiene"
	KindSecret  = "secret"
	KindGate    = "gate"
)

// hygienePatterns is the distribution-hygiene sweep's pattern list, copied
// out of .github/workflows/10_ci-quality.yml by sync-hygiene.sh so the hub
// image needs no other tree; TestHygienePatternsInSync fails while the copy
// differs. Each pattern is base64 so this file is not itself a sweep hit.
//
//go:embed hygiene-patterns.tsv
var hygienePatterns string

// secretRules are spec §5.1's secret scan: PEM private-key blocks, cloud key
// JSON, common token prefixes.
var secretRules = []struct{ label, pattern string }{
	{"PEM private key", `-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----`},
	{"cloud key JSON private_key", `"private_key"\s*:`},
	{"GitHub token", `\b(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,})`},
	{"AWS access key id", `\b(?:AKIA|ASIA)[0-9A-Z]{16}\b`},
	{"Google API key", `\bAIza[0-9A-Za-z_-]{35}`},
	{"Google OAuth token", `\bya29\.[0-9A-Za-z_-]{20,}`},
	{"Slack token", `\bxox[abposr]-[0-9A-Za-z-]{10,}`},
	{"payment live secret key", `\b[rs]k_live_[0-9A-Za-z]{16,}`},
}

type rule struct {
	kind, label string
	m           *matcher
}

var rules, rulesErr = loadRules(hygienePatterns)

func loadRules(tsv string) ([]rule, error) {
	hyg, err := parsePatterns(tsv)
	if err != nil {
		return nil, err
	}
	if len(hyg) == 0 {
		return nil, fmt.Errorf("repodocs: hygiene-patterns.tsv holds no pattern")
	}
	var out []rule
	for _, p := range hyg {
		m, err := compilePCRE(p.pattern)
		if err != nil {
			return nil, fmt.Errorf("repodocs: hygiene rule %q: %w", p.label, err)
		}
		out = append(out, rule{KindHygiene, p.label, m})
	}
	for _, s := range secretRules {
		m, err := compilePCRE(s.pattern)
		if err != nil {
			return nil, fmt.Errorf("repodocs: secret rule %q: %w", s.label, err)
		}
		out = append(out, rule{KindSecret, s.label, m})
	}
	return out, nil
}

type pattern struct{ label, pattern string }

// parsePatterns reads hygiene-patterns.tsv: "#" comments, then one
// "<label>\t<base64 pattern>" per line.
func parsePatterns(tsv string) ([]pattern, error) {
	var out []pattern
	for i, ln := range strings.Split(tsv, "\n") {
		if ln = strings.TrimRight(ln, "\r"); ln == "" || strings.HasPrefix(ln, "#") {
			continue
		}
		label, enc, ok := strings.Cut(ln, "\t")
		raw, err := base64.StdEncoding.DecodeString(enc)
		if !ok || label == "" || err != nil || len(raw) == 0 {
			return nil, fmt.Errorf("repodocs: hygiene-patterns.tsv line %d is not <label>\\t<base64>", i+1)
		}
		out = append(out, pattern{label, string(raw)})
	}
	return out, nil
}

// Gate runs the text gates of spec §5.1 over the lines of next that old does
// not already hold (a line kept, or moved, from the published text is never
// re-judged), and returns one Hit per rule and line. Empty = clean. When the
// rules cannot load, every save gets one "gate" hit: the gate fails closed.
func Gate(old, next []byte) []Hit {
	if rulesErr != nil {
		return []Hit{{Kind: KindGate, Rule: "gate_unavailable"}}
	}
	var hits []Hit
	for _, nl := range newLines(old, next) {
		for _, r := range rules {
			if r.m.match(nl.text) {
				hits = append(hits, Hit{Kind: r.kind, Rule: r.label, Line: nl.n})
			}
		}
	}
	return hits
}

type line struct {
	n    int
	text string
}

// newLines are next's lines that old does not hold, counted as a multiset: a
// line old has twice may appear twice in next unjudged, a third copy is new.
func newLines(old, next []byte) []line {
	have := map[string]int{}
	for _, l := range splitLines(old) {
		have[l]++
	}
	var out []line
	for i, l := range splitLines(next) {
		if have[l] > 0 {
			have[l]--
			continue
		}
		out = append(out, line{i + 1, l})
	}
	return out
}

func splitLines(b []byte) []string {
	if len(b) == 0 {
		return nil
	}
	ls := strings.Split(string(b), "\n")
	for i := range ls {
		ls[i] = strings.TrimRight(ls[i], "\r")
	}
	return ls
}
