package agentid

import (
	"errors"
	"testing"
	"time"
)

// pin sets Now to t for one test.
func pin(t *testing.T, at time.Time) {
	t.Helper()
	old := Now
	Now = func() time.Time { return at }
	t.Cleanup(func() { Now = old })
}

func TestLegacyUntilTextMatchesInstant(t *testing.T) {
	got, err := time.Parse(time.RFC3339, LegacyUntilText)
	if err != nil || !got.Equal(LegacyUntil) {
		t.Fatalf("LegacyUntilText %q parses to %v (%v), want %v", LegacyUntilText, got, err, LegacyUntil)
	}
}

func TestDefaultClockUnderTestIsBeforeDeadline(t *testing.T) {
	if Expired() {
		t.Fatalf("under go test the default clock must stand before %s (FR-004)", LegacyUntilText)
	}
}

func TestGrammar(t *testing.T) {
	cases := []struct {
		id                         string
		isNew, legacy, agent, part bool
		kind                       string
	}{
		{"c-004", true, false, true, true, "claude"},
		{"a-999", true, false, true, true, "agy"},
		{"g-001", true, false, true, true, "grok"},
		{"q-010", true, false, true, true, "qwen"},
		{"c-000", false, false, false, false, ""},
		{"c-4", false, false, false, false, ""},
		{"c-0004", false, false, false, false, ""},
		{"x-004", false, false, false, false, ""},
		{"C-004", false, false, false, false, ""},
		{"CLE-77952", false, true, true, true, "claude"},
		{"AGY-02", false, true, true, true, "agy"},
		{"GRK-3", false, true, true, true, "grok"},
		{"QWN-100000", false, true, true, true, "qwen"},
		{"HUM-17", false, false, false, true, ""},
		{"LGC-0", false, false, false, true, ""},
		{"cle-1", false, false, false, false, ""},
		{"", false, false, false, false, ""},
	}
	for _, c := range cases {
		if IsNew(c.id) != c.isNew || IsLegacy(c.id) != c.legacy || IsAgent(c.id) != c.agent ||
			IsParticipant(c.id) != c.part || Kind(c.id) != c.kind {
			t.Errorf("%q: new=%v legacy=%v agent=%v participant=%v kind=%q; want %v %v %v %v %q", c.id,
				IsNew(c.id), IsLegacy(c.id), IsAgent(c.id), IsParticipant(c.id), Kind(c.id),
				c.isNew, c.legacy, c.agent, c.part, c.kind)
		}
	}
}

func TestAtBox(t *testing.T) {
	for s, want := range map[string]bool{
		"c-004@box-desk": true, "CLE-001@sat": true, "c-004": false,
		"c-004@Box": false, "c-004@": false, "@box": false,
	} {
		if IsAtBox(s) != want {
			t.Errorf("IsAtBox(%q) = %v, want %v", s, !want, want)
		}
	}
	if Kind("a-004@box-desk") != "agy" {
		t.Errorf("Kind of an @box id")
	}
}

func TestNormalize(t *testing.T) {
	for in, want := range map[string]string{
		"C-004": "c-004", " c-004 ": "c-004", "Q-123@box-a": "q-123@box-a",
		"CLE-7": "CLE-7", "HUM-17": "HUM-17",
	} {
		if got := Normalize(in); got != want {
			t.Errorf("Normalize(%q) = %q, want %q", in, got, want)
		}
	}
}

func table(m map[string]string) Lookup {
	t := Table{}
	for k, v := range m {
		id, box := SplitAtBox(k)
		t[[2]string{id, box}] = v
	}
	return t.Lookup
}

func TestTableKeyedOnBox(t *testing.T) {
	tb := Table{{"CLE-7", "box-a"}: "c-004", {"CLE-7", "box-b"}: "c-009", {"CLE-8", "box-a"}: "c-005"}
	if n, ok := tb.Lookup("CLE-7", "box-b"); !ok || n != "c-009" {
		t.Errorf("exact box: %q %v", n, ok)
	}
	if _, ok := tb.Lookup("CLE-7", ""); ok {
		t.Error("a bare id with two rows must not pick one")
	}
	if n, ok := tb.Lookup("CLE-8", ""); !ok || n != "c-005" {
		t.Errorf("a bare id with one row: %q %v", n, ok)
	}
	if _, ok := tb.Lookup("CLE-8", "box-b"); ok {
		t.Error("another box's row answered")
	}
	got, err := ResolveOn("CLE-7", "box-b", tb.Lookup)
	if err != nil || got != "c-009" {
		t.Errorf("ResolveOn: %q %v", got, err)
	}
}

func TestResolveBeforeDeadline(t *testing.T) {
	pin(t, LegacyUntil)
	lk := table(map[string]string{"CLE-77952@box-sat": "c-004"})
	for in, want := range map[string]string{
		"CLE-77952":         "c-004",
		"CLE-77952@box-sat": "c-004@box-sat",
		"CLE-1":             "CLE-1", // no alias row: accepted as itself (FR-002)
		"C-005":             "c-005",
		"HUM-17":            "HUM-17",
	} {
		got, err := Resolve(in, lk)
		if err != nil || got != want {
			t.Errorf("Resolve(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	if got, err := Resolve("CLE-77952", nil); err != nil || got != "CLE-77952" {
		t.Errorf("nil lookup: %q, %v", got, err)
	}
}

func TestResolveAfterDeadlineRefuses(t *testing.T) {
	pin(t, LegacyUntil.Add(time.Second))
	lk := table(map[string]string{"CLE-77952@box-sat": "c-004"})
	_, err := Resolve("CLE-77952", lk)
	var re *RetiredError
	if !errors.As(err, &re) || err.Error() != "CLE-77952 is retired as an id; use c-004" {
		t.Fatalf("after the deadline: %v", err)
	}
	if err := Check("GRK-9@box-a", lk); err == nil || err.Error() != "GRK-9 is retired as an id; use g-NNN" {
		t.Fatalf("no alias: %v", err)
	}
	for _, ok := range []string{"c-004", "HUM-17", "c-004@box-a", "LGC-0"} {
		if err := Check(ok, lk); err != nil {
			t.Errorf("%q refused after the deadline: %v", ok, err)
		}
	}
}

func TestNumberAndLetter(t *testing.T) {
	if Number("CLE-123") != "123" || Number("nodash") != "" {
		t.Error("Number")
	}
	if Letter("AGY-1") != 'a' || Letter("QWN-1") != 'q' || Letter("GRK-1") != 'g' || Letter("CLE-1") != 'c' {
		t.Error("Letter")
	}
}

func TestSplitAtBox(t *testing.T) {
	for in, want := range map[string][2]string{
		"c-004@box-a": {"c-004", "box-a"}, "c-004": {"c-004", ""}, "": {"", ""},
		"c-004@": {"c-004", ""}, "@box-a": {"", "box-a"}, "c-004@box-a@x": {"c-004", "box-a@x"},
	} {
		if id, box := SplitAtBox(in); id != want[0] || box != want[1] {
			t.Errorf("SplitAtBox(%q) = %q, %q, want %q, %q", in, id, box, want[0], want[1])
		}
	}
}
