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
	// SPL-952: the old four and the two new kinds all validate.
	for _, k := range []string{"task", "result", "note", "reject", "blocker", "msg"} {
		ok := sample()
		ok.Kind = k
		if err := ok.Validate(); err != nil {
			t.Fatalf("kind %q rejected: %v", k, err)
		}
	}
	bad = sample()
	bad.From = "lowercase-1"
	if err := bad.Validate(); err == nil {
		t.Fatal("bad from id accepted")
	}
	bad = sample()
	bad.From = "BOX-1"
	if err := bad.Validate(); err == nil {
		t.Fatal("from BOX-1 accepted")
	}
	bad = sample()
	bad.To = "BOX-07"
	if err := bad.Validate(); err == nil {
		t.Fatal("to BOX-07 accepted")
	}
}

func TestValidID(t *testing.T) {
	ok := []string{"CLE-07", "GRK-3", "AGY-01", "CLE-3333"}
	for _, s := range ok {
		if !ValidID(s) {
			t.Errorf("ValidID(%q) = false, want true", s)
		}
	}
	for _, s := range []string{"BOX-1", "BOX-07"} {
		if ValidID(s) {
			t.Errorf("ValidID(%q) = true, want false", s)
		}
	}
}

func TestValidTenantID(t *testing.T) {
	for _, s := range []string{"acme", "t1", "box-a", "a", "dev-001"} {
		if !ValidTenantID(s) {
			t.Errorf("ValidTenantID(%q) = false, want true", s)
		}
	}
	for _, s := range []string{"", "Acme", "t_1", "has.dot", "-lead", "this-id-is-way-too-long-for-the-slug", "dev", "prd", "www", "api"} {
		if ValidTenantID(s) {
			t.Errorf("ValidTenantID(%q) = true, want false", s)
		}
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

// Golden vectors (contracts/canonical-json.md): Canonical == jq -cS 'del(.sig)'
// and Marshal == jq -cS . of the same object, byte for byte. The second vector
// locks '"' and newline escaping plus one files[] entry; the third is the
// <>& control: encoding/json's default HTML escaping (< > &)
// is not jq's and must never reach the disk or a signing payload.
func TestCanonicalGoldenVectors(t *testing.T) {
	const tail = `"from":"GRK-03","kind":"task","msg_id":"11111111-1111-4111-8111-111111111111","task_id":"22222222-2222-4222-8222-222222222222","to":"CLE-07","ts":"2026-09-18T12:00:00Z","v":1}`
	blob := Attachment{Mode: "blob", Kind: "file", FileID: "ab12", Name: "a.txt", Bytes: 3, SHA256: "ab12"}
	const blobJSON = `[{"bytes":3,"file_id":"ab12","kind":"file","mode":"blob","name":"a.txt","sha256":"ab12"}]`
	for _, tc := range []struct {
		name, body, bodyJSON string
		files                []Attachment
		filesJSON            string
	}{
		{"plain", "review this", `"review this"`, nil, `[]`},
		{"quote-newline-file", "say \"hi\"\nnow/then", `"say \"hi\"\nnow/then"`, []Attachment{blob}, blobJSON},
		{"html-control", "a<b && c>d", `"a<b && c>d"`, nil, `[]`},
	} {
		m := &Message{V: 1, MsgID: "11111111-1111-4111-8111-111111111111",
			TaskID: "22222222-2222-4222-8222-222222222222", TS: "2026-09-18T12:00:00Z",
			From: "GRK-03", To: "CLE-07", Kind: "task", Body: tc.body, Files: tc.files}
		want := `{"body":` + tc.bodyJSON + `,"files":` + tc.filesJSON + `,` + tail
		c, err := Canonical(m)
		if err != nil || string(c) != want {
			t.Fatalf("%s: Canonical (err=%v)\n got %s\nwant %s", tc.name, err, c, want)
		}
		d, err := Marshal(m)
		if err != nil || string(d) != want {
			t.Fatalf("%s: Marshal (err=%v)\n got %s\nwant %s", tc.name, err, d, want)
		}
		m.Sig = "c2ln"
		withSig := strings.Replace(want, `,"task_id"`, `,"sig":"c2ln","task_id"`, 1)
		if d, _ := Marshal(m); string(d) != withSig {
			t.Fatalf("%s: Marshal with sig\n got %s\nwant %s", tc.name, d, withSig)
		}
		if c, _ := Canonical(m); string(c) != want {
			t.Fatalf("%s: Canonical must drop sig\n got %s", tc.name, c)
		}
	}
}

// A file written before the fix holds <-style escapes. It must still parse
// to the same message and re-marshal to the canonical (unescaped) bytes.
func TestEscapedLegacyFileStillParses(t *testing.T) {
	legacy := `{"body":"a<b && c>d","files":[],"from":"GRK-03","kind":"task","msg_id":"11111111-1111-4111-8111-111111111111","task_id":"22222222-2222-4222-8222-222222222222","to":"CLE-07","ts":"2026-09-18T12:00:00Z","v":1}`
	m, err := Parse([]byte(legacy))
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Validate(); err != nil || m.Body != "a<b && c>d" {
		t.Fatalf("legacy file: err=%v body=%q", err, m.Body)
	}
	d, _ := Marshal(m)
	if want := strings.NewReplacer(`<`, "<", `>`, ">", `&`, "&").Replace(legacy); string(d) != want {
		t.Fatalf("re-marshal\n got %s\nwant %s", d, want)
	}
}

// Spec 067 3.3: ref_task_id is optional. Unset, the canonical bytes are the
// ones a reader that predates it signs and verifies; set, it round-trips and
// must be a uuid (rdb 0112 types the column).
func TestRefTaskID(t *testing.T) {
	m := sample()
	plain, err := Canonical(m)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(plain), "ref_task_id") {
		t.Fatalf("unset ref_task_id is in the canonical bytes: %s", plain)
	}
	m.RefTaskID = "0b6e8f2a-1c3d-4e5f-8a9b-0c1d2e3f4a5b"
	if err := m.Validate(); err != nil {
		t.Fatal(err)
	}
	raw, err := Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	back, err := Parse(raw)
	if err != nil || back.RefTaskID != m.RefTaskID {
		t.Fatalf("round trip: %v %q", err, back.RefTaskID)
	}
	for _, bad := range []string{"t1", "0B6E8F2A-1C3D-4E5F-8A9B-0C1D2E3F4A5B", "0b6e8f2a1c3d4e5f8a9b0c1d2e3f4a5b"} {
		m.RefTaskID = bad
		if err := m.Validate(); err == nil {
			t.Fatalf("ref_task_id %q accepted", bad)
		}
	}
}
