package i18nmask

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fixtureDir is the shared fixture of the bash mask and this port, relative
// to this package (spec 123 section 16.6.5, row L3).
const fixtureDir = "../../../../../../csi-spl-orc/src/bash/tests/fixtures/i18n-mask"

func readFixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(fixtureDir, name))
	if err != nil {
		t.Fatalf("the shared fixture: %v", err)
	}
	return string(b)
}

// The Go mask and the bash mask give the same tokens on the fixture:
// input.txt masked with terms.txt is masked.txt, and the map is map.tsv,
// which the bash action wrote (csi-spl-orc/src/bash/tests/
// spl-i18n-mask-fixture.tst.sh pins the bash side on the same files).
func TestMaskSharedFixture(t *testing.T) {
	terms, err := ParseTerms(strings.NewReader(readFixture(t, "terms.txt")))
	if err != nil {
		t.Fatal(err)
	}
	masked, m := New(terms).Mask(readFixture(t, "input.txt"))
	if want := readFixture(t, "masked.txt"); masked != want {
		gl, wl := strings.Split(masked, "\n"), strings.Split(want, "\n")
		for i := range min(len(gl), len(wl)) {
			if gl[i] != wl[i] {
				t.Errorf("line %d:\n got  %q\n want %q", i+1, gl[i], wl[i])
			}
		}
		if len(gl) != len(wl) {
			t.Errorf("lines: got %d, want %d", len(gl), len(wl))
		}
	}
	var b strings.Builder
	for _, p := range m {
		b.WriteString(p.Token + "\t" + p.Value + "\n")
	}
	if want := readFixture(t, "map.tsv"); b.String() != want {
		t.Errorf("map:\n got\n%s want\n%s", b.String(), want)
	}
	if len(m) < 10 {
		t.Errorf("the fixture exercises %d tokens, want >= 10", len(m))
	}
}

// One label at a time, as the hub masks: the same text and list give the
// same masked text (the hub rebuilds the map, never stores it), the unmask
// gives the text back, and a token the answer dropped is named.
func TestMaskOneLabel(t *testing.T) {
	k := New([]Term{{Name, "Testi Henkilö"}, {Workspace, "fixture-acme-ws"}})
	text := "Salary Testi Henkilö, fixture-acme-ws, mail a.b@example.org"
	m1, map1 := k.Mask(text)
	m2, _ := k.Mask(text)
	if m1 != m2 || m1 != "Salary [NAME_1], [WORKSPACE_1], mail [EMAIL_1]" {
		t.Fatalf("mask: %q / %q", m1, m2)
	}
	if back, miss := map1.Unmask(m1); back != text || len(miss) != 0 {
		t.Errorf("unmask: %q missing %v", back, miss)
	}
	if _, miss := map1.Unmask("Palkka [NAME_1]"); strings.Join(miss, ",") != "[WORKSPACE_1],[EMAIL_1]" {
		t.Errorf("missing tokens: %v", miss)
	}
	if out, _ := map1.Unmask("x [NAME_9]"); out != "x [NAME_9]" {
		t.Errorf("an unknown token is left as it is: %q", out)
	}
}

// Remask: a draft made from the text carries its values again as the same
// tokens; an inflected form of a term is masked on, numbered after the map.
func TestRemask(t *testing.T) {
	k := New([]Term{{Name, "Testi"}})
	_, m := k.Mask("Salary Testi")
	got, m2 := k.Remask("Palkka Testi, Testille", m)
	if got != "Palkka [NAME_1], [NAME_2]" || len(m2) != 2 || m2[1].Value != "Testille" {
		t.Errorf("remask: %q %v", got, m2)
	}
}

func TestParseTermsRefusesABadLine(t *testing.T) {
	if _, err := ParseTerms(strings.NewReader("name Testi\nperson Other\n")); err == nil {
		t.Error("an unknown class is refused")
	}
	if _, err := ParseTerms(strings.NewReader("NAME Testi\n")); err == nil {
		t.Error("the class is lower case, as the bash action's")
	}
}
