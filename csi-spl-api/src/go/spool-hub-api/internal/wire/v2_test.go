package wire

import (
	"crypto/ed25519"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// specs/020 canonical-json-v2.md §2: one canonicaliser, golden bytes and
// sigs for both versions, and no cross-version replay.
func TestGoldenV1V2Envelopes(t *testing.T) {
	const sha = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
	inner := func(v string) string {
		return `{"body":"a<b & c","files":[{"bytes":4,"file_id":"` + sha + `","kind":"file","mode":"blob","name":"test.txt","sha256":"` + sha + `"},{"kind":"dir","mode":"path","name":"out","path":"/srv/work/out"}],"from":"GRK-03","kind":"task","msg_id":"11111111-1111-4111-8111-111111111111","task_id":"22222222-2222-4222-8222-222222222222","to":"CLE-07","ts":"2026-09-18T12:00:00Z","v":` + v + `}`
	}
	sigs := map[int]string{
		1: "ZFXGuw9LY63ygB6xIDCH9GOxsHI0cHz6KqmGe7hgh55n7hyiiQE4T/6Wid2FiRxVlvsluQzj0Q6VBKMvJQnxDQ==",
		2: "hj2/6umTFaBw+/iV6wI5ioSTCgjUDv9BfB7l16DiCmz/hsjZp4anZB7uTZqd+5x4+DGYVeENt0xkXZnr+AtGDg==",
	}
	pub := fixedKey().Public().(ed25519.PublicKey)
	envs := map[int]*Envelope{}
	for v, vs := range map[int]string{1: "1", 2: "2"} {
		m := fixedMsg()
		m.V = v
		m.Files = []msg.Attachment{
			{Mode: "blob", Kind: "file", FileID: sha, SHA256: sha, Name: "test.txt", Bytes: 4},
			{Mode: "path", Kind: "dir", Path: "/srv/work/out", Name: "out"},
		}
		if c, err := msg.Canonical(m); err != nil || string(c) != inner(vs) {
			t.Fatalf("v:%d inner canonical (err=%v)\n got %s\nwant %s", v, err, c, inner(vs))
		}
		e, err := NewEnvelope(fixedKey(), "box-a", "box-b", m)
		if err != nil {
			t.Fatal(err)
		}
		want := `{"from_box":"box-a","msg":` + inner(vs) + `,"sig":"` + sigs[v] + `","to_box":"box-b"}`
		raw, _ := e.Marshal()
		if string(raw) != want {
			t.Fatalf("v:%d envelope\n got %s\nwant %s", v, raw, want)
		}
		back, err := ParseEnvelope(raw)
		if err != nil {
			t.Fatal(err)
		}
		if err := back.Verify(pub); err != nil {
			t.Fatalf("v:%d verify: %v", v, err)
		}
		if again, _ := back.Marshal(); string(again) != want {
			t.Fatalf("v:%d parse->marshal changed bytes", v)
		}
		if m2, err := back.Inner(); err != nil || m2.V != v {
			t.Fatalf("v:%d Inner: %v %+v", v, err, m2)
		}
		if InnerVersion(raw) != v {
			t.Fatalf("InnerVersion = %d, want %d", InnerVersion(raw), v)
		}
		envs[v] = back
	}
	// v sits inside the signed bytes: a v:1 sig never verifies a v:2 payload.
	swap := *envs[2]
	swap.Sig = envs[1].Sig
	if swap.Verify(pub) == nil {
		t.Fatal("v:1 signature verified the v:2 envelope")
	}
	if InnerVersion([]byte(`{`)) != 0 {
		t.Fatal("InnerVersion of garbage is not 0")
	}
}

// The pre-020 hello frame bytes are unchanged when msg_versions is absent,
// and the field never enters the hello signature payload.
func TestHelloMsgVersionsOptional(t *testing.T) {
	old, _ := Canonical(Frame{Type: THello, BoxID: "box-a", Nonce: "n", TS: "t", Role: RoleBox, Sig: "s"})
	if want := `{"box_id":"box-a","nonce":"n","role":"box","sig":"s","ts":"t","type":"hello"}`; string(old) != want {
		t.Fatalf("pre-020 hello\n got %s\nwant %s", old, want)
	}
	nw, _ := Canonical(Frame{Type: THello, BoxID: "box-a", Nonce: "n", TS: "t", Role: RoleBox, Sig: "s", MsgVersions: msg.Supported})
	if want := `{"box_id":"box-a","msg_versions":[1,2],"nonce":"n","role":"box","sig":"s","ts":"t","type":"hello"}`; string(nw) != want {
		t.Fatalf("020 hello\n got %s\nwant %s", nw, want)
	}
}
