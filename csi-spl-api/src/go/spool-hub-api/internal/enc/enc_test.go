package enc

import (
	"errors"
	"strings"
	"testing"

	"filippo.io/age"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

const marker = "MARKER-BODY-7f3c secret plan for the review"

func sample() *msg.Message {
	return &msg.Message{
		V: 1, MsgID: "11111111-2222-4333-8444-555555555555",
		TaskID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
		TS:     "2026-10-13T12:00:00Z", From: "c-101", To: "c-102",
		Kind: "note", Body: marker,
		Files: []msg.Attachment{{Mode: "path", Kind: "file", Path: "/srv/x/plan.md", Name: "plan.md"}},
	}
}

// keys makes n fresh identities and their recipients, for ids in order.
func keys(t testing.TB, ids ...string) ([]*age.X25519Identity, []Recipient) {
	t.Helper()
	var idents []*age.X25519Identity
	var rcpts []Recipient
	for _, id := range ids {
		k, err := age.GenerateX25519Identity()
		if err != nil {
			t.Fatal(err)
		}
		r, err := ParseRecipient(id, k.Recipient().String())
		if err != nil {
			t.Fatal(err)
		}
		idents = append(idents, k)
		rcpts = append(rcpts, r)
	}
	return idents, rcpts
}

func seal(t *testing.T, rcpts []Recipient) *msg.Sealed {
	t.Helper()
	s, err := Seal(sample(), rcpts)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	return s
}

// FR3: only the `for` identities open it; any other identity fails.
func TestOnlyForIdentitiesOpen(t *testing.T) {
	idents, rcpts := keys(t, "c-102", "HUM-1")
	s := seal(t, rcpts)
	if got := strings.Join(s.For, ","); got != "c-102,HUM-1" {
		t.Fatalf("for = %q", got)
	}
	for i, k := range idents {
		m, err := Open(s, k)
		if err != nil {
			t.Fatalf("identity %d: %v", i, err)
		}
		if m.Body != marker || m.From != "c-101" || len(m.Files) != 1 || m.Files[0].Name != "plan.md" {
			t.Fatalf("identity %d opened %+v", i, m)
		}
	}
	other, _ := keys(t, "c-103")
	if _, err := Open(s, other[0]); !errors.Is(err, ErrNotRecipient) {
		t.Fatalf("other identity: err = %v, want ErrNotRecipient", err)
	}
}

// The v:3 file has no body, no clear body text, and a name with no slug.
func TestSealedFileCarriesNoBody(t *testing.T) {
	_, rcpts := keys(t, "c-102", "HUM-1")
	s := seal(t, rcpts)
	raw, err := msg.MarshalSealed(s)
	if err != nil {
		t.Fatal(err)
	}
	name := msg.SealedFilename(s)
	for _, leak := range []string{"MARKER", "marker", "secret", "plan.md", `"body"`} {
		if strings.Contains(string(raw), leak) || strings.Contains(name, leak) {
			t.Fatalf("%q leaks into the sealed file or its name %q", leak, name)
		}
	}
	if name != "20261013T120000Z--c-101--11111111.age.json" {
		t.Fatalf("name = %q", name)
	}
	if !strings.HasPrefix(string(raw), `{"ct":"`) || !strings.Contains(string(raw), `"enc":"age","files":[],"for":["c-102","HUM-1"]`) {
		t.Fatalf("sealed bytes = %s", raw)
	}
	back, err := msg.ParseSealed(raw)
	if err != nil || back.Validate() != nil {
		t.Fatalf("round trip: %v / %v", err, back.Validate())
	}
	if _, err := msg.Parse(raw); err == nil {
		t.Fatal("a v:1 reader must refuse a v:3 file")
	}
}

// FR13: a rewritten clear header, or a ct replayed under another msg_id, is
// refused, never shown.
func TestHeaderMismatchRefused(t *testing.T) {
	idents, rcpts := keys(t, "c-102", "HUM-1")
	cases := map[string]func(s *msg.Sealed){
		"from":    func(s *msg.Sealed) { s.From = "c-666" },
		"msg_id":  func(s *msg.Sealed) { s.MsgID = "99999999-2222-4333-8444-555555555555" },
		"task_id": func(s *msg.Sealed) { s.TaskID = "99999999-bbbb-4ccc-8ddd-eeeeeeeeeeee" },
		"ts":      func(s *msg.Sealed) { s.TS = "2026-10-13T12:00:01Z" },
		"to":      func(s *msg.Sealed) { s.To = "c-103" },
		"kind":    func(s *msg.Sealed) { s.Kind = "result" },
	}
	for field, tamper := range cases {
		s := seal(t, rcpts)
		tamper(s)
		m, err := Open(s, idents[0])
		if !errors.Is(err, ErrHeaderMismatch) || m != nil {
			t.Fatalf("%s swapped: m=%v err=%v, want ErrHeaderMismatch", field, m, err)
		}
		if !strings.Contains(err.Error(), "HEADER MISMATCH "+s.MsgID) {
			t.Fatalf("%s: error text %q", field, err)
		}
	}
	// Replay: a valid ct copied under another message's header.
	a := seal(t, rcpts)
	other := sample()
	other.MsgID = "22222222-2222-4333-8444-555555555555"
	b, err := Seal(other, rcpts)
	if err != nil {
		t.Fatal(err)
	}
	b.CT = a.CT
	if _, err := Open(b, idents[1]); !errors.Is(err, ErrHeaderMismatch) {
		t.Fatalf("replayed ct: err = %v, want ErrHeaderMismatch", err)
	}
}

func TestSealRefusesBadInput(t *testing.T) {
	_, rcpts := keys(t, "c-102")
	if _, err := Seal(sample(), nil); err == nil {
		t.Fatal("no recipient must be refused")
	}
	big := sample()
	big.Body = strings.Repeat("x", msg.MaxBodyBytes+1)
	if _, err := Seal(big, rcpts); err == nil {
		t.Fatal("MaxBodyBytes must be checked on the clear body before sealing")
	}
	if _, err := ParseRecipient("not an id", "age1x"); err == nil {
		t.Fatal("bad recipient id must be refused")
	}
	if _, err := ParseRecipient("c-102", "age1notakey"); err == nil {
		t.Fatal("bad recipient key must be refused")
	}
	s := seal(t, rcpts)
	s.CT = "!!not base64!!"
	if _, err := Open(s); err == nil {
		t.Fatal("bad ct must be refused")
	}
}

func TestRefTaskAndAcceptsSurvive(t *testing.T) {
	idents, rcpts := keys(t, "c-102")
	m := sample()
	m.RefTaskID = "cccccccc-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	m.Accepts = "dddddddd-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	s, err := Seal(m, rcpts)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Open(s, idents[0])
	if err != nil || got.RefTaskID != m.RefTaskID || got.Accepts != m.Accepts {
		t.Fatalf("got %+v err %v", got, err)
	}
}

// Spec 136 section 7: seal at the p99 body size (3631 B), 3 recipients.
// go test -run '^$' -bench Seal -benchtime 1000x ./internal/enc/
func BenchmarkSealP99ThreeRecipients(b *testing.B) {
	_, rcpts := keys(b, "c-102", "HUM-1", "c-103")
	m := sample()
	m.Body = strings.Repeat("y", 3631)
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if _, err := Seal(m, rcpts); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkOpenP99(b *testing.B) {
	idents, rcpts := keys(b, "c-102", "HUM-1", "c-103")
	m := sample()
	m.Body = strings.Repeat("y", 3631)
	s, err := Seal(m, rcpts)
	if err != nil {
		b.Fatal(err)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := Open(s, idents[2]); err != nil {
			b.Fatal(err)
		}
	}
}
