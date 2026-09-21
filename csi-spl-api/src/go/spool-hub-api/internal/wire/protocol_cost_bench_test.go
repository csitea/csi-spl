package wire_test

// CLE-3436 (specs/030 FR-001): what one message costs INSIDE the process, so a
// fast-path change is argued from a number rather than from a hunch. Each
// benchmark is one hop of the send path the owner's DM actually walks:
//
//	go test ./internal/wire -run '^$' -bench BenchmarkProtocol -benchmem -count 5
//
// Read these against the measured box<->hub RTT (~61.5 ms p50 to the live dev
// hub on 2026-09-21, n=20): a hop worth removing has to cost a material
// fraction of that. A hop that costs microseconds does not, and saying so is
// the point - it stops us rebuilding a layer that is not the cost.

import (
	"crypto/ed25519"
	"encoding/json"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// bodySizes are the interactive shapes: a chat line, a paragraph, and a pasted
// block. 64 KiB (msg.MaxBody) is not an interactive DM and is measured only to
// show where encoding starts to matter.
var bodySizes = []struct {
	name string
	n    int
}{
	{"chat_80B", 80},
	{"para_1KB", 1 << 10},
	{"paste_16KB", 16 << 10},
	{"max_64KB", 64 << 10},
}

func benchMsg(n int) *msg.Message {
	return &msg.Message{
		V: msg.V1, MsgID: "11111111-2222-4333-8444-555555555555",
		TaskID: "66666666-7777-4888-8999-aaaaaaaaaaaa",
		TS:     "2026-09-21T12:00:00Z", From: "HUM-1", To: "CLE-00",
		Kind: "note", Body: strings.Repeat("x", n), Files: []msg.Attachment{},
	}
}

// BenchmarkProtocolSign is what a SENDER pays per message: canonicalise the
// inner object, build the signing payload, sign it (flush.go NewEnvelope).
func BenchmarkProtocolSign(b *testing.B) {
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		b.Fatal(err)
	}
	for _, bs := range bodySizes {
		m := benchMsg(bs.n)
		b.Run(bs.name, func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				if _, err := wire.NewEnvelope(priv, "box-a", "box-b", m); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

// BenchmarkProtocolVerify is what the HUB pays per send (onSend) and what the
// RECEIVING box pays per recv frame (hubclient receive): parse the envelope,
// rebuild the signing payload, verify.
func BenchmarkProtocolVerify(b *testing.B) {
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		b.Fatal(err)
	}
	for _, bs := range bodySizes {
		env, err := wire.NewEnvelope(priv, "box-a", "box-b", benchMsg(bs.n))
		if err != nil {
			b.Fatal(err)
		}
		raw, err := env.Marshal()
		if err != nil {
			b.Fatal(err)
		}
		b.Run(bs.name, func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				e, err := wire.ParseEnvelope(raw)
				if err != nil {
					b.Fatal(err)
				}
				if err := e.Verify(pub); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

// BenchmarkProtocolFrame is the FRAMING cost alone: encode a recv frame and
// decode it, i.e. what the JSON-vs-binary question is actually about.
func BenchmarkProtocolFrame(b *testing.B) {
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		b.Fatal(err)
	}
	for _, bs := range bodySizes {
		env, err := wire.NewEnvelope(priv, "box-a", "box-b", benchMsg(bs.n))
		if err != nil {
			b.Fatal(err)
		}
		raw, err := env.Marshal()
		if err != nil {
			b.Fatal(err)
		}
		f := wire.Frame{Type: wire.TRecv, Env: raw, Agents: []string{"CLE-00"}}
		b.Run(bs.name, func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				out, err := json.Marshal(f)
				if err != nil {
					b.Fatal(err)
				}
				var in wire.Frame
				if err := json.Unmarshal(out, &in); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

// BenchmarkProtocolCanonical isolates the canonical re-encode (sorted keys,
// exact numbers) that every signature and every stored envelope pays twice:
// once to sign, once to verify.
func BenchmarkProtocolCanonical(b *testing.B) {
	for _, bs := range bodySizes {
		m := benchMsg(bs.n)
		b.Run(bs.name, func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				if _, err := msg.Canonical(m); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

// BenchmarkProtocolHello is the per-CONNECTION crypto: the hello payload and
// its signature. It is paid once per socket - or, today, once per `spool send`,
// because flush.go dials a fresh role=cli session per message.
func BenchmarkProtocolHello(b *testing.B) {
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	for b.Loop() {
		p, err := wire.HelloPayload("box-desk", "bm9uY2Utbm9uY2Utbm9uY2Utbm9uY2U=", "2026-09-21T12:00:00Z")
		if err != nil {
			b.Fatal(err)
		}
		sign.Sign(priv, p)
	}
}
