package msg

import (
	"strings"
	"testing"
)

// specs/020 FR-001: readers take v:1 and v:2 under one rule set; nothing else.
func TestValidateAcceptsV1AndV2(t *testing.T) {
	for _, v := range []int{V1, V2} {
		m := sample()
		m.V = v
		m.Files = []Attachment{
			{Mode: "blob", Kind: "file", FileID: "ab12", SHA256: "ab12", Name: "a.txt", Bytes: 3},
			{Mode: "path", Kind: "dir", Path: "/srv/work/out", Name: "out"},
		}
		if err := m.Validate(); err != nil {
			t.Fatalf("v:%d rejected: %v", v, err)
		}
		bad := *m
		bad.Files = []Attachment{{Mode: "blob", Kind: "file", FileID: "ab12", SHA256: "cd34", Name: "a"}}
		if err := bad.Validate(); err == nil {
			t.Fatalf("v:%d: sha256 != file_id accepted (same rules for both versions)", v)
		}
	}
	for _, v := range []int{0, 3, -1} {
		m := sample()
		m.V = v
		if err := m.Validate(); err == nil || !strings.Contains(err.Error(), "unsupported version") {
			t.Fatalf("v:%d accepted: %v", v, err)
		}
	}
	if Version != V1 {
		t.Fatalf("default writer version moved to %d before the 020 P3 gate", Version)
	}
}

// specs/020 US2: a v:2 object with blob + path refs survives Marshal -> Parse
// -> Validate -> Marshal byte for byte (the golden bytes: canonical-json-v2 §2.2).
func TestV2RoundTrip(t *testing.T) {
	const golden = `{"body":"a<b & c","files":[{"bytes":4,"file_id":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","kind":"file","mode":"blob","name":"test.txt","sha256":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"},{"kind":"dir","mode":"path","name":"out","path":"/srv/work/out"}],"from":"GRK-03","kind":"task","msg_id":"11111111-1111-4111-8111-111111111111","task_id":"22222222-2222-4222-8222-222222222222","to":"CLE-07","ts":"2026-09-18T12:00:00Z","v":2}`
	m, err := Parse([]byte(golden))
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Validate(); err != nil || m.V != V2 {
		t.Fatalf("v=%d err=%v", m.V, err)
	}
	if m.Files[1].FileID != "" || m.Files[1].Bytes != 0 || m.Files[1].Path != "/srv/work/out" {
		t.Fatalf("path-dir ref decoded wrong: %+v", m.Files[1])
	}
	for name, f := range map[string]func(*Message) ([]byte, error){"Marshal": Marshal, "Canonical": Canonical} {
		if b, err := f(m); err != nil || string(b) != golden {
			t.Fatalf("%s (err=%v)\n got %s\nwant %s", name, err, b, golden)
		}
	}
}

// message-schema-v2 §4 row 5: a file ref written literally from the frozen
// v:1 contract ({file_id,name,bytes,sha256}, no mode/kind) is refused by every
// shipped reader. v:2 documents mode/kind as required; nothing changes here.
func TestContractLiteralV1RefRejected(t *testing.T) {
	raw := `{"body":"x","files":[{"bytes":3,"file_id":"ab12","name":"a.txt","sha256":"ab12"}],"from":"GRK-03","kind":"task","msg_id":"11111111-1111-4111-8111-111111111111","task_id":"22222222-2222-4222-8222-222222222222","to":"CLE-07","ts":"2026-09-18T12:00:00Z","v":1}`
	m, err := Parse([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Validate(); err == nil || !strings.Contains(err.Error(), "is not file|dir") {
		t.Fatalf("contract-literal v:1 ref: %v", err)
	}
}

// message-schema-v2 §4 row 9: the strict decode reaches inside files[i].
func TestUnknownFileRefKeyRejected(t *testing.T) {
	for _, v := range []string{"1", "2"} {
		raw := `{"body":"x","files":[{"file_id":"ab12","kind":"file","mode":"blob","name":"a","extra":1}],"from":"GRK-03","kind":"task","msg_id":"11111111-1111-4111-8111-111111111111","task_id":"22222222-2222-4222-8222-222222222222","to":"CLE-07","ts":"2026-09-18T12:00:00Z","v":` + v + `}`
		if _, err := Parse([]byte(raw)); err == nil || !strings.Contains(err.Error(), "extra") {
			t.Fatalf("v:%s unknown key inside files[0]: %v", v, err)
		}
	}
}
