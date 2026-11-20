// SPDX-License-Identifier: AGPL-3.0-only

package topicpdf

import (
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// Every printSlug case of csi-spl-wui/tests/unit/msg-print.test.mjs, in Go
// (spec 183 row P2). printSlug(null) is the empty string here: Go has no null.
func TestSlugMatchesPrintSlug(t *testing.T) {
	cases := map[string]string{
		"  Deploy: WUI v1.2 -- failed!  ": "deploy-wui-v1-2-failed",
		"Тема за износ":                   "тема-за-износ", // any script keeps its letters
		"":                                "topic",
		"!!!":                             "topic",
		"Ｆｕｌｌｗｉｄｔｈ ①":                     "fullwidth-1", // NFKC, as printSlug's normalize
	}
	for in, want := range cases {
		if got := Slug(in); got != want {
			t.Errorf("Slug(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSlugCutsLongTitleNeverOnDash(t *testing.T) {
	slug := Slug(strings.Repeat("word ", 40))
	if utf8.RuneCountInString(slug) > SlugMax {
		t.Fatalf("Slug is %d characters, cap %d: %q", utf8.RuneCountInString(slug), SlugMax, slug)
	}
	if strings.HasSuffix(slug, "-") {
		t.Fatalf("Slug ends on a dash: %q", slug)
	}
	// "word-" * 12 is exactly 60 with the dash last: the cut drops it
	if want := strings.TrimSuffix(strings.Repeat("word-", 12), "-"); slug != want {
		t.Fatalf("Slug = %q, want %q", slug, want)
	}
}

func TestFileName(t *testing.T) {
	at := time.Date(2026, 11, 20, 9, 5, 7, 0, time.FixedZone("EET", 2*3600))
	got := FileName("Release notes", "5D1F2A9C-0b1e-4c4a-9d7e-2f0a1b2c3d4e", at)
	if want := "release-notes-5d1f2a9c-20261120T070507Z.pdf"; got != want {
		t.Fatalf("FileName = %q, want %q", got, want)
	}
}
