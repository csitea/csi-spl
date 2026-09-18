package wire

import (
	"crypto/ed25519"
	"errors"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
)

func fixedKey() ed25519.PrivateKey {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	return ed25519.NewKeyFromSeed(seed)
}

func fixedMsg() *msg.Message {
	return &msg.Message{
		V: 1, MsgID: "11111111-1111-4111-8111-111111111111", TaskID: "22222222-2222-4222-8222-222222222222",
		TS: "2026-09-18T12:00:00Z", From: "GRK-03", To: "CLE-07", Kind: "task", Body: "a<b & c",
		Files: []msg.Attachment{},
	}
}

// Golden vector (T002/T003): the exact bytes the hello and envelope sigs cover.
func TestGoldenPayloads(t *testing.T) {
	hp, err := HelloPayload("box-a", "bm9uY2U=", "2026-09-18T12:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"box_id":"box-a","nonce":"bm9uY2U=","ts":"2026-09-18T12:00:00Z"}`; string(hp) != want {
		t.Fatalf("hello payload\n got %s\nwant %s", hp, want)
	}

	e, err := NewEnvelope(fixedKey(), "box-a", "box-b", fixedMsg())
	if err != nil {
		t.Fatal(err)
	}
	p, _ := e.SigningPayload()
	want := `{"from_box":"box-a","msg":{"body":"a<b & c","files":[],"from":"GRK-03","kind":"task","msg_id":"11111111-1111-4111-8111-111111111111","task_id":"22222222-2222-4222-8222-222222222222","to":"CLE-07","ts":"2026-09-18T12:00:00Z","v":1},"to_box":"box-b"}`
	if string(p) != want {
		t.Fatalf("envelope payload\n got %s\nwant %s", p, want)
	}
	if err := e.Verify(fixedKey().Public().(ed25519.PublicKey)); err != nil {
		t.Fatalf("verify: %v", err)
	}
}

// The sig survives a marshal/parse round trip (what the hub stores and forwards).
func TestEnvelopeRoundTrip(t *testing.T) {
	e, _ := NewEnvelope(fixedKey(), "box-a", "box-b", fixedMsg())
	raw, err := e.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	back, err := ParseEnvelope(raw)
	if err != nil {
		t.Fatal(err)
	}
	if err := back.Verify(fixedKey().Public().(ed25519.PublicKey)); err != nil {
		t.Fatalf("verify after round trip: %v", err)
	}
	m, err := back.Inner()
	if err != nil || m.Body != "a<b & c" {
		t.Fatalf("inner: %v %+v", err, m)
	}
}

// Changing any signed field — including to_box, which the hub must never fill —
// breaks the sig.
func TestTamperFails(t *testing.T) {
	pub := fixedKey().Public().(ed25519.PublicKey)
	for name, mut := range map[string]func(*Envelope){
		"to_box":   func(e *Envelope) { e.ToBox = "box-c" },
		"from_box": func(e *Envelope) { e.FromBox = "box-c" },
		"msg":      func(e *Envelope) { e.Msg = []byte(string(e.Msg[:len(e.Msg)-2]) + "2}") },
	} {
		e, _ := NewEnvelope(fixedKey(), "box-a", "box-b", fixedMsg())
		mut(e)
		if err := e.Verify(pub); !errors.Is(err, sign.ErrVerify) {
			t.Errorf("%s: tampered envelope verified (err=%v)", name, err)
		}
	}
}

func TestParseEnvelopeRejectsUnknown(t *testing.T) {
	if _, err := ParseEnvelope([]byte(`{"from_box":"a","to_box":"b","msg":{},"sig":"x","extra":1}`)); err == nil {
		t.Fatal("unknown key accepted")
	}
}

func TestPinPayloads(t *testing.T) {
	p, err := PinPayload("box-a", "pubkey", "2026-09-18T12:00:00Z", false)
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"box_id":"box-a","force":false,"pubkey":"pubkey","ts":"2026-09-18T12:00:00Z"}`; string(p) != want {
		t.Fatalf("pin payload\n got %s\nwant %s", p, want)
	}
	r, err := RevokePayload("box-a", "2026-09-18T12:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"box_id":"box-a","op":"revoke","ts":"2026-09-18T12:00:00Z"}`; string(r) != want {
		t.Fatalf("revoke payload\n got %s\nwant %s", r, want)
	}
}
