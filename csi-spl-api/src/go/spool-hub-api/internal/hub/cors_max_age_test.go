// SPDX-License-Identifier: AGPL-3.0-only

package hub

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestCORSPreflightsShareOneMaxAge: every preflight the hub answers takes its
// Access-Control-Max-Age from corsMaxAge (CLE-35076), so no route drifts back
// to a short cache that costs an OPTIONS round trip per write.
func TestCORSPreflightsShareOneMaxAge(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	set := regexp.MustCompile(`"Access-Control-Max-Age",\s*([^)]+)\)`)
	seen := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range set.FindAllSubmatch(b, -1) {
			seen++
			if got := strings.TrimSpace(string(m[1])); got != "corsMaxAge" {
				t.Errorf("%s: Access-Control-Max-Age set to %s, want corsMaxAge", f, got)
			}
		}
	}
	if seen < 10 {
		t.Fatalf("found %d preflight Max-Age sites, expected the hub's >= 10", seen)
	}
	if corsMaxAge != "7200" {
		t.Fatalf("corsMaxAge = %q, want 7200 (Chrome's ceiling)", corsMaxAge)
	}
}
