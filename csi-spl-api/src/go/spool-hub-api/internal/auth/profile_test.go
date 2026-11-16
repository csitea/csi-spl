package auth

import (
	"strings"
	"testing"
)

// SPL-5707 (spec 154 section 12.5): the phone is the international form only,
// stored normalised; the name split is rdb 0290's backfill rule.
func TestValidPhone(t *testing.T) {
	for raw, want := range map[string]string{
		"+358 40 123 4567":  "+358401234567",
		"+1 (555) 000-1111": "+15550001111",
		"+44.20.7946.0958":  "+442079460958",
		" +3594000000 ":     "+3594000000",
		"+1234567":          "+1234567",         // 7 digits, the floor
		"+123456789012345":  "+123456789012345", // 15 digits, the ceiling
		"040 123 4567":      "",                 // national form: no country
		"00358401234567":    "",
		"+0401234567":       "",
		"+123456":           "",
		"+1234567890123456": "",
		"+358 40 abc":       "",
		"+358 40 1234567":   "+358401234567", // a no-break space is a space
		"":                  "",
		"+":                 "",
	} {
		got, ok := ValidPhone(raw)
		if got != want || ok != (want != "") {
			t.Errorf("ValidPhone(%q) = %q %v, want %q", raw, got, ok, want)
		}
	}
}

func TestSplitDisplayName(t *testing.T) {
	long := strings.Repeat("a", 120)
	for name, want := range map[string][2]string{
		"FirstName LastName":    {"FirstName", "LastName"},
		"Mary Ann Smith":        {"Mary", "Ann Smith"},
		"  Mary \t Ann  Smith ": {"Mary", "Ann  Smith"},
		"Solo":                  {"Solo", ""},
		"":                      {"", ""},
		long + " " + long:       {long[:100], long[:100]},
	} {
		f, l := SplitDisplayName(name)
		if f != want[0] || l != want[1] {
			t.Errorf("SplitDisplayName(%q) = %q %q, want %q %q", name, f, l, want[0], want[1])
		}
	}
	if JoinName("Solo", "") != "Solo" || JoinName("A", "B C") != "A B C" {
		t.Errorf("JoinName")
	}
}
