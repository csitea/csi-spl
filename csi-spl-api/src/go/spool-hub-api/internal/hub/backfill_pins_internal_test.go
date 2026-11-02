package hub

import (
	"crypto/ed25519"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

func signedRow(t testing.TB, priv ed25519.PrivateKey, box, body string) []byte {
	t.Helper()
	m := &msg.Message{V: msg.V1, MsgID: uid.New(), TaskID: uid.New(), TS: time.Now().UTC().Format(time.RFC3339),
		From: "c-009", To: "ALL-0", Kind: "note", Body: body}
	e, err := wire.NewEnvelopeIn(priv, box, WUIBox, "ops", "", m)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := e.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// Spec 169 T4c, the cost of verifying in a read path: one pin read per box per
// run, however many rows and seats, and none for box-wui.
func TestBackfillPinsReadOncePerBox(t *testing.T) {
	keys, privs := map[string]ed25519.PublicKey{}, map[string]ed25519.PrivateKey{}
	for _, b := range []string{"box-a", "box-b", "box-c"} {
		keys[b], privs[b], _ = ed25519.GenerateKey(nil)
	}
	_, wui, _ := ed25519.GenerateKey(nil)
	reads := map[string]int{}
	p := newBackfillPins(func(box string) (ed25519.PublicKey, error) {
		reads[box]++
		return keys[box], nil
	})
	const seats, rows = 2, 200
	for range seats {
		for i := range rows {
			box := []string{"box-a", "box-b", "box-c"}[i%3]
			if held, err := p.withheld(signedRow(t, privs[box], box, "x")); held || err != nil {
				t.Fatalf("row %d of %s: held %v err %v", i, box, held, err)
			}
			if held, err := p.withheld(signedRow(t, wui, WUIBox, "x")); held || err != nil {
				t.Fatalf("box-wui row %d: held %v err %v", i, held, err)
			}
		}
	}
	if len(reads) != 3 || reads["box-a"] != 1 || reads["box-b"] != 1 || reads["box-c"] != 1 {
		t.Fatalf("pin reads %v, want one each for 3 boxes and none for %s", reads, WUIBox)
	}
}

func TestBackfillPinsRulings(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	_, other, _ := ed25519.GenerateKey(nil)
	boom := errors.New("db down")
	cases := []struct {
		name string
		get  func(string) (ed25519.PublicKey, error)
		row  []byte
		held bool
		err  error
	}{
		{"signed by the live pin", func(string) (ed25519.PublicKey, error) { return pub, nil }, signedRow(t, priv, "box-a", "x"), false, nil},
		{"signed by another key", func(string) (ed25519.PublicKey, error) { return pub, nil }, signedRow(t, other, "box-a", "x"), true, nil},
		{"no live pin: the box decides", func(string) (ed25519.PublicKey, error) { return nil, store.ErrNotFound }, signedRow(t, other, "box-a", "x"), false, nil},
		{"a failed pin read is not a verdict", func(string) (ed25519.PublicKey, error) { return nil, boom }, signedRow(t, other, "box-a", "x"), false, boom},
	}
	for _, c := range cases {
		held, err := newBackfillPins(c.get).withheld(c.row)
		if held != c.held || !errors.Is(err, c.err) {
			t.Errorf("%s: held %v err %v", c.name, held, err)
		}
	}
}

// One large back-fill's verify cost: 200 rows (the size CI and prd use is the
// BackfillMax of the hub's config) of a 4 KB body from 5 boxes.
func BenchmarkBackfillPins200Rows(b *testing.B) {
	boxes := []string{"box-a", "box-b", "box-c", "box-d", "box-e"}
	keys := map[string]ed25519.PublicKey{}
	var rows [][]byte
	for _, box := range boxes {
		pub, priv, _ := ed25519.GenerateKey(nil)
		keys[box] = pub
		for range 40 {
			rows = append(rows, signedRow(b, priv, box, strings.Repeat("x", 4096)))
		}
	}
	b.ResetTimer()
	for range b.N {
		p := newBackfillPins(func(box string) (ed25519.PublicKey, error) { return keys[box], nil })
		for _, r := range rows {
			if held, err := p.withheld(r); held || err != nil {
				b.Fatal(held, err)
			}
		}
	}
}
