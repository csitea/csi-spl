package repodocs

import (
	"strings"
	"testing"
)

// The samples are assembled at run time, so this file is itself no hit of
// the hygiene sweep or of the repo's secret scanners.
var (
	homeDir = "/ho" + "me/"
	osUser  = "ys" + "g"
)

// hygieneHits holds, per hygiene rule label, a line it must hit. A new rule
// in the workflow fails TestGateEachRuleHits until it gets a sample here.
var hygieneHits = map[string]string{
	"non-Csitea org or bank reference": "a branch of " + "Nord" + "ea",
	"personal name":                    "written by " + "Pet" + "ri",
	"literal OS user / box / AD id":    "run as " + osUser + " on the box",
	"personal home directory":          "see " + homeDir + "alice/notes",
	"owner mail address or domain":     "mail me at x@" + "gmail.com",
}

var secretHits = map[string]string{
	"PEM private key":            "-----BEGIN RSA " + "PRIVATE KEY-----",
	"cloud key JSON private_key": `{"private_` + `key": "x"}`,
	"GitHub token":               "token gh" + "p_" + strings.Repeat("a1", 18),
	"AWS access key id":          "AK" + "IA" + "ABCDEFGHIJKLMNOP",
	"Google API key":             "AI" + "za" + strings.Repeat("B", 35),
	"Google OAuth token":         "ya" + "29." + strings.Repeat("c", 24),
	"Slack token":                "xo" + "xb-" + "1234567890-abcdef",
	"payment live secret key":    "sk" + "_live_" + strings.Repeat("d", 24),
}

func TestRulesLoad(t *testing.T) {
	if rulesErr != nil {
		t.Fatal(rulesErr)
	}
	pats, _ := parsePatterns(hygienePatterns)
	if len(pats) < 5 || len(rules) != len(pats)+len(secretRules) {
		t.Fatalf("%d hygiene patterns, %d rules", len(pats), len(rules))
	}
}

func TestGateEachRuleHits(t *testing.T) {
	for _, r := range rules {
		sample, ok := hygieneHits[r.label]
		if r.kind == KindSecret {
			sample, ok = secretHits[r.label]
		}
		if !ok {
			t.Errorf("%s rule %q has no sample hit", r.kind, r.label)
			continue
		}
		next := []byte("# Title\n\nclean line\n" + sample + "\n")
		hits := Gate(nil, next)
		if !hasHit(hits, r.kind, r.label, 4) {
			t.Errorf("%s rule %q: no hit on line 4 of %q: %+v", r.kind, r.label, sample, hits)
		}
	}
}

func TestGateCleanTextPasses(t *testing.T) {
	clean := "# Runbook\n\nRun `./run -a do_publish_docs` as `$USER` from `$HOME/`.\n" +
		"The box user is `<DEV_USER>`; " + homeDir + "runner/work is the CI checkout.\n" +
		osUser + "-box is a hostname placeholder, not a user.\n" +
		"BEGIN PUBLIC KEY is fine; so is private_key_id in prose.\n"
	if hits := Gate(nil, []byte(clean)); len(hits) != 0 {
		t.Fatalf("clean text hit: %+v", hits)
	}
}

func TestGateOnlyNewLines(t *testing.T) {
	bad := hygieneHits["personal name"]
	old := []byte("# Doc\n" + bad + "\nend\n")
	if hits := Gate(old, []byte("# Doc\n"+bad+"\nend\nan added clean line\n")); len(hits) != 0 {
		t.Fatalf("a kept line was judged: %+v", hits)
	}
	if hits := Gate(old, []byte(bad+"\n# Doc moved below\nend\n")); len(hits) != 0 {
		t.Fatalf("a moved line was judged: %+v", hits)
	}
	hits := Gate(old, []byte("# Doc\n"+bad+"\nend\n"+bad+"\n"))
	if len(hits) != 1 || !hasHit(hits, KindHygiene, "personal name", 4) {
		t.Fatalf("a second copy of a kept line is new: %+v", hits)
	}
	if hits := Gate(old, []byte("# Doc\r\n"+bad+"\r\nend\r\n")); len(hits) != 0 {
		t.Fatalf("CRLF re-save of the same lines was judged: %+v", hits)
	}
}

func TestGateHitCarriesNoText(t *testing.T) {
	for _, h := range Gate(nil, []byte(secretHits["GitHub token"])) {
		if strings.Contains(h.Rule, "gh"+"p_") {
			t.Fatalf("hit echoes the secret: %+v", h)
		}
	}
}

func TestGateFailsClosed(t *testing.T) {
	saved, savedErr := rules, rulesErr
	defer func() { rules, rulesErr = saved, savedErr }()
	rules, rulesErr = loadRules("# nothing\n")
	if rulesErr == nil {
		t.Fatal("an empty pattern file loaded")
	}
	if hits := Gate(nil, []byte("clean\n")); len(hits) != 1 || hits[0].Kind != KindGate {
		t.Fatalf("broken rules did not fail closed: %+v", hits)
	}
	if _, err := loadRules("label\tnot base64!\n"); err == nil {
		t.Fatal("a bad pattern line loaded")
	}
}

func TestLookahead(t *testing.T) {
	m, err := compilePCRE(`(?i)\b` + osUser + `\b(?!-box)|\bzz\b`)
	if err != nil {
		t.Fatal(err)
	}
	for s, want := range map[string]bool{
		osUser:                           true,
		"x " + osUser + "-box y":         false,
		osUser + "-box and " + osUser:    true, // a refused start never hides a later one
		"my" + osUser:                    false,
		strings.ToUpper(osUser) + "-BOX": false,
		"zz top":                         true,
		"é" + osUser:                     true, // \b after a non-ASCII rune, as grep -P reads it
	} {
		if m.match(s) != want {
			t.Errorf("match(%q) != %v", s, want)
		}
	}
	h, err := compilePCRE(homeDir + `(?!runner\b)[a-z][a-z0-9_-]*/`)
	if err != nil {
		t.Fatal(err)
	}
	for s, want := range map[string]bool{
		homeDir + "runner/w":                false,
		homeDir + "runners/w":               true,
		homeDir + "runner" + homeDir + "b/": true,
	} {
		if h.match(s) != want {
			t.Errorf("match(%q) != %v", s, want)
		}
	}
	for _, bad := range []string{`a(?=b)`, `(?<=a)b`, `(?<!a)b`, `a(?!b)c(?!d)`, `(a(?!b))`, `a(`} {
		if _, err := compilePCRE(bad); err == nil {
			t.Errorf("compilePCRE(%q) accepted a construct it cannot honour", bad)
		}
	}
}

func hasHit(hits []Hit, kind, label string, line int) bool {
	for _, h := range hits {
		if h.Kind == kind && h.Rule == label && h.Line == line {
			return true
		}
	}
	return false
}
