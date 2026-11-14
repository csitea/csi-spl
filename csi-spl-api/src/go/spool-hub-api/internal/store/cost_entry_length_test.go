package store

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// SPL-5488: the label and note limits count characters, as rdb 0245's
// length() CHECKs and the error text do, not UTF-8 bytes. 34 prd HR rows
// with Cyrillic labels of 59..74 characters (105..127 bytes) were refused.
func TestCheckCostEntryCountsCharacters(t *testing.T) {
	cyr := func(n int) string { return strings.Repeat("Я", n) }
	// 53 Cyrillic (2 bytes each) + 21 ASCII = 74 characters, 127 bytes.
	hr74 := cyr(53) + strings.Repeat("a", 21)
	if c, b := utf8.RuneCountInString(hr74), len(hr74); c != 74 || b != 127 {
		t.Fatalf("fixture: %d characters, %d bytes; want 74 and 127", c, b)
	}
	cases := []struct {
		name, label, note, want string
	}{
		{"cyrillic label 74 chars 127 bytes", hr74, "", ""},
		{"cyrillic label 100 chars", cyr(100), "", ""},
		{"cyrillic label 101 chars", cyr(101), "", "label must be 1..100 characters"},
		{"ascii label 100 chars", strings.Repeat("a", 100), "", ""},
		{"ascii label 101 chars", strings.Repeat("a", 101), "", "label must be 1..100 characters"},
		{"cyrillic note 2000 chars", "label", cyr(2000), ""},
		{"cyrillic note 2001 chars", "label", cyr(2001), "note must be at most 2000 characters"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := costEntry("op", "cloud", c.label, 10, "EUR", "2026-10")
			e.Note = c.note
			if got := CheckCostEntry(e); got != c.want {
				t.Fatalf("CheckCostEntry = %q, want %q", got, c.want)
			}
		})
	}
}
