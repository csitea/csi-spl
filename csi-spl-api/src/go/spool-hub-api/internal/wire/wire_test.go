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

// legacyEnv is an envelope exactly as a pre-M3 box signs and sends it (no
// channel, no parent_task_id). It must keep parsing, verifying and
// re-marshalling to the same bytes (channels-v1 §2: v:1 boxes keep working).
const legacyEnv = `{"from_box":"box-a","msg":{"body":"a<b & c","files":[],"from":"GRK-03","kind":"task","msg_id":"11111111-1111-4111-8111-111111111111","task_id":"22222222-2222-4222-8222-222222222222","to":"CLE-07","ts":"2026-09-18T12:00:00Z","v":1},"sig":"EVsoo/PF9uj3kQjcNRKXEIidEeMRFyY5BiOWMQgRlN1eHA4cVvtIwGMLum7uI6QICnWGxMj6qeTchmGEsPxnBQ==","to_box":"box-b"}`

func TestEnvelopeLegacyBytes(t *testing.T) {
	e, err := ParseEnvelope([]byte(legacyEnv))
	if err != nil {
		t.Fatal(err)
	}
	if e.Channel != "" || e.ParentTaskID != "" {
		t.Fatalf("legacy envelope grew tags: %+v", e)
	}
	if err := e.Verify(fixedKey().Public().(ed25519.PublicKey)); err != nil {
		t.Fatalf("legacy envelope no longer verifies: %v", err)
	}
	raw, err := e.Marshal()
	if err != nil || string(raw) != legacyEnv {
		t.Fatalf("legacy re-marshal changed bytes (err=%v)\n got %s\nwant %s", err, raw, legacyEnv)
	}
	fresh, _ := NewEnvelope(fixedKey(), "box-a", "box-b", fixedMsg())
	if b, _ := fresh.Marshal(); string(b) != legacyEnv {
		t.Fatalf("NewEnvelope no longer produces the pre-M3 bytes\n got %s", b)
	}
}

// channel / parent_task_id are signed when present and change nothing when absent.
func TestEnvelopeChannelSigned(t *testing.T) {
	pub := fixedKey().Public().(ed25519.PublicKey)
	parent := "33333333-3333-4333-8333-333333333333"
	e, err := NewEnvelopeIn(fixedKey(), "box-a", "box-wui", "tasks", parent, fixedMsg())
	if err != nil {
		t.Fatal(err)
	}
	p, _ := e.SigningPayload()
	want := `{"channel":"tasks","from_box":"box-a","msg":{"body":"a<b & c","files":[],"from":"GRK-03","kind":"task","msg_id":"11111111-1111-4111-8111-111111111111","task_id":"22222222-2222-4222-8222-222222222222","to":"CLE-07","ts":"2026-09-18T12:00:00Z","v":1},"parent_task_id":"33333333-3333-4333-8333-333333333333","to_box":"box-wui"}`
	if string(p) != want {
		t.Fatalf("tagged payload\n got %s\nwant %s", p, want)
	}
	raw, _ := e.Marshal()
	back, err := ParseEnvelope(raw)
	if err != nil || back.Channel != "tasks" || back.ParentTaskID != parent {
		t.Fatalf("round trip: %v %+v", err, back)
	}
	if err := back.Verify(pub); err != nil {
		t.Fatalf("tagged verify: %v", err)
	}
	for name, mut := range map[string]func(*Envelope){
		"channel changed":   func(e *Envelope) { e.Channel = "alerts" },
		"channel stripped":  func(e *Envelope) { e.Channel = "" },
		"parent changed":    func(e *Envelope) { e.ParentTaskID = "44444444-4444-4444-8444-444444444444" },
		"parent stripped":   func(e *Envelope) { e.ParentTaskID = "" },
		"to_box retargeted": func(e *Envelope) { e.ToBox = "box-b" },
	} {
		c, _ := ParseEnvelope(raw)
		mut(c)
		if err := c.Verify(pub); !errors.Is(err, sign.ErrVerify) {
			t.Errorf("%s: verified (err=%v)", name, err)
		}
	}
	// A tag added to a legacy envelope after signing does not verify either.
	l, _ := ParseEnvelope([]byte(legacyEnv))
	l.Channel = "lobby"
	if err := l.Verify(pub); !errors.Is(err, sign.ErrVerify) {
		t.Errorf("channel added post-sign verified (err=%v)", err)
	}
}
