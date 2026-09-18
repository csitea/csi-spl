package msg

import (
	"strings"
	"testing"
	"time"
)

func sample() *Message {
	return &Message{
		V: 1, MsgID: "11111111-2222-4333-8444-555555555555",
		TaskID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
		TS:     "2026-09-18T12:00:00Z", From: "GRK-03", To: "CLE-07",
		Kind: "task", Body: "review this", Files: []Attachment{},
	}
}

func TestCanonicalDeterministicAndSorted(t *testing.T) {
	m := sample()
	a, err := Canonical(m)
	if err != nil {
		t.Fatal(err)
	}
	// Deterministic: setting a sig must not change the canonical payload.
	m.Sig = "somesig"
	b, err := Canonical(m)
	if err != nil {
		t.Fatal(err)
	}
	if string(a) != string(b) {
		t.Fatalf("canonical changed when sig set:\n%s\n%s", a, b)
	}
	// Sorted keys, compact: no spaces, and "body" is the first key.
	if strings.Contains(string(a), ": ") || strings.Contains(string(a), ", ") {
		t.Fatalf("not compact: %s", a)
	}
	if !strings.HasPrefix(string(a), `{"body":`) {
		t.Fatalf("keys not sorted (want body first): %s", a)
	}
	// sig must be excluded from the canonical payload.
	if strings.Contains(string(a), `"sig"`) {
		t.Fatalf("sig leaked into canonical: %s", a)
	}
	// files:[] must be present (jq -cS del(.sig) keeps empty arrays).
	if !strings.Contains(string(a), `"files":[]`) {
		t.Fatalf("empty files not preserved: %s", a)
	}
}

func TestValidate(t *testing.T) {
	m := sample()
	if err := m.Validate(); err != nil {
		t.Fatalf("valid message rejected: %v", err)
	}
	bad := sample()
	bad.Kind = "bogus"
	if err := bad.Validate(); err == nil {
		t.Fatal("bad kind accepted")
	}
	bad = sample()
	bad.From = "lowercase-1"
	if err := bad.Validate(); err == nil {
		t.Fatal("bad from id accepted")
	}
}

func TestValidateLimits(t *testing.T) {
	big := sample()
	big.Body = strings.Repeat("x", MaxBodyBytes+1)
	if err := big.Validate(); err == nil {
		t.Fatal("oversized body accepted")
	}
	many := sample()
	for i := 0; i <= MaxFiles; i++ {
		many.Files = append(many.Files, Attachment{Mode: "path", Kind: "file", Path: "/x", Name: "x"})
	}
	if err := many.Validate(); err == nil {
		t.Fatal("too many files accepted")
	}
	huge := sample()
	huge.Files = []Attachment{{Mode: "blob", Kind: "file", FileID: "a", SHA256: "a", Name: "big", Bytes: MaxFileBytes + 1}}
	if err := huge.Validate(); err == nil {
		t.Fatal("oversized file accepted")
	}
}

func TestParseRejectsUnknownFields(t *testing.T) {
	_, err := Parse([]byte(`{"v":1,"msg_id":"x","task_id":"y","ts":"t","from":"GRK-03","to":"CLE-07","kind":"task","body":"b","files":[],"bogus":true}`))
	if err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestFilename(t *testing.T) {
	m := sample()
	name := Filename(m)
	if !strings.HasPrefix(name, "20260918T120000Z--GRK-03--review-this-") || !strings.HasSuffix(name, ".json") {
		t.Fatalf("unexpected filename: %s", name)
	}
}

func TestNow(t *testing.T) {
	got := Now(time.Date(2026, 9, 18, 12, 0, 0, 0, time.UTC))
	if got != "2026-09-18T12:00:00Z" {
		t.Fatalf("Now format: %s", got)
	}
}
