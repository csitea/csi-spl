package wire_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// canonicalRef is wire.Canonical as it was before perf round 4 (G9): marshal,
// decode into any with exact numbers, encode again. Canonical is the
// signature contract, so its one-pass rewrite must match this byte for byte.
func canonicalRef(v any) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var any interface{}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&any); err != nil {
		return nil, err
	}
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(any); err != nil {
		return nil, err
	}
	return bytes.TrimRight(b.Bytes(), "\n"), nil
}

func sameCanonical(t *testing.T, name string, v any) {
	t.Helper()
	want, werr := canonicalRef(v)
	got, gerr := wire.Canonical(v)
	if (werr != nil) != (gerr != nil) || !bytes.Equal(got, want) {
		t.Errorf("%s:\n got  %q (%v)\n want %q (%v)", name, got, gerr, want, werr)
	}
}

// tricky are the strings that make a re-encode differ: HTML characters (the
// first marshal escapes them, Canonical must not), U+2028/9, control bytes,
// invalid UTF-8, quotes, backslashes, non-ASCII and a surrogate pair.
var tricky = []string{"", "plain", "a <b> & c", "line\u2028para\u2029", "tab\tnl\nnul\x00bel\x07del\x7f",
	"bad\xffutf8\xc3", `quote " back \ slash /`, "é ü 漢字", "😀 emoji", "\b\f\r", "</script>"}

func TestCanonicalGolden(t *testing.T) {
	m := benchMsg(0)
	for _, s := range tricky {
		m.Body = s
		sameCanonical(t, "msg "+s, m)
		sameCanonical(t, "key "+s, map[string]any{s: s, "z": []any{s, 1, nil}})
	}
	_, inner := envFixture(t)
	sameCanonical(t, "envelope", inner)
	sp, err := inner.SigningPayload()
	if err != nil {
		t.Fatal(err)
	}
	if want, _ := canonicalRef(map[string]any{"from_box": inner.FromBox, "to_box": inner.ToBox, "msg": inner.Msg,
		"channel": inner.Channel, "parent_task_id": inner.ParentTaskID}); !bytes.Equal(sp, want) {
		t.Errorf("SigningPayload drifted:\n got  %s\n want %s", sp, want)
	}
	for _, v := range []any{nil, true, 0, -1.5e300, 3.0, json.Number("1.000"), json.Number("-0"), "x", []int{}, map[string]int{},
		struct{}{}, []any{map[string]any{}, []any{}}, map[string]any{"b": 1, "a": map[string]any{"d": 2, "c": []any{3}}}} {
		sameCanonical(t, fmt.Sprintf("%T %v", v, v), v)
	}
	// raw messages are copied by the first marshal as written (compacted):
	// odd escapes, whitespace, duplicate keys and unsorted nesting all reach
	// the re-encode.
	for _, raw := range []string{`{"b":1,"a":2,"b":3}`, `{ "k" : [ 1 , { "y" : "\u0041\/\u00e9" , "x" : null } ] }`,
		`"\ud83d\ude00 \ud800 lone \udc00 \uD83D\uDE00"`, `{"\u0062":1,"a":2,"b":0}`, `[1e10,-0.0,1E-7,12345678901234567890]`,
		`{"a<":1,"a":2,"a\u0026":3,"\u2028":4}`, `"\u2028\u2029\u0000\u001f\u007f"`, "{\"s\":\"raw\xe2\x80\xa8sep\"}",
		"\"\xff\xfe\"", `{}`, `[]`, `[[],{},[{}]]`, `true`, `null`} {
		sameCanonical(t, "raw "+raw, json.RawMessage(raw))
	}
}

// TestCanonicalRandom compares the two encoders on n=5000 random values
// (fixed seed) built from the tricky strings, nested to depth 4.
func TestCanonicalRandom(t *testing.T) {
	r := &goldenRand{s: 9}
	for i := 0; i < 5000; i++ {
		sameCanonical(t, fmt.Sprintf("random %d", i), randValue(r, 4))
	}
}

func randValue(r *goldenRand, depth int) any {
	n := 7
	if depth == 0 {
		n = 4
	}
	switch r.Intn(n) {
	case 0:
		return tricky[r.Intn(len(tricky))] + tricky[r.Intn(len(tricky))]
	case 1:
		return r.NormFloat64() * 1e6
	case 2:
		return []any{nil, true, false, r.Int63()}[r.Intn(4)]
	case 3:
		return json.Number(fmt.Sprint(r.Int63n(1e9)))
	case 4:
		m := map[string]any{}
		for k := r.Intn(6); k > 0; k-- {
			m[tricky[r.Intn(len(tricky))]+fmt.Sprint(r.Intn(3))] = randValue(r, depth-1)
		}
		return m
	case 5:
		a := make([]any, r.Intn(4))
		for k := range a {
			a[k] = randValue(r, depth-1)
		}
		return a
	default:
		// a raw message as a box might have written it: pretty-printed, with
		// a duplicated key appended
		b, _ := json.MarshalIndent(map[string]any{"k": randValue(r, depth-1), "j": tricky[r.Intn(len(tricky))]}, "", "  ")
		s := strings.TrimSuffix(string(b), "}") + `, "k": ` + fmt.Sprint(r.Intn(9)) + "}"
		return json.RawMessage(s)
	}
}

// FuzzCanonical: any valid JSON document, passed through as a raw message.
func FuzzCanonical(f *testing.F) {
	for _, s := range []string{`{"b":1,"a":[2,"\u003c"]}`, `"\ud800"`, `{"a":1,"a":2}`, "\"\xff\""} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		if !json.Valid([]byte(s)) {
			return
		}
		sameCanonical(t, s, json.RawMessage(s))
	})
}

func envFixture(t testing.TB) (*msg.Message, *wire.Envelope) {
	m := benchMsg(0)
	m.Body = "a <b> & c " + strings.Repeat("é", 20)
	inner, err := msg.Canonical(m)
	if err != nil {
		t.Fatal(err)
	}
	return m, &wire.Envelope{FromBox: "box-a", ToBox: "box-b", Channel: "ops", ParentTaskID: m.TaskID, Msg: inner, Sig: "c2ln"}
}

// BenchmarkCanonicalAB runs the old (ref) and the one-pass (new) Canonical on
// the BenchmarkProtocolCanonical shapes, interleaved by -count:
//
//	go test ./internal/wire -run '^$' -bench BenchmarkCanonicalAB -benchmem -count 6
func BenchmarkCanonicalAB(b *testing.B) {
	for _, bs := range bodySizes {
		m := benchMsg(bs.n)
		for _, impl := range []struct {
			name string
			f    func(any) ([]byte, error)
		}{{"ref", canonicalRef}, {"new", wire.Canonical}} {
			b.Run(bs.name+"/"+impl.name, func(b *testing.B) {
				b.ReportAllocs()
				for b.Loop() {
					if _, err := impl.f(m); err != nil {
						b.Fatal(err)
					}
				}
			})
		}
	}
}

// goldenRand is a fixed-seed xorshift: the random corpus only has to be
// varied and repeatable, not unpredictable.
type goldenRand struct{ s uint64 }

func (r *goldenRand) next() uint64 {
	r.s ^= r.s << 13
	r.s ^= r.s >> 7
	r.s ^= r.s << 17
	return r.s
}

func (r *goldenRand) Intn(n int) int { return int(r.next() % uint64(n)) }

func (r *goldenRand) Int63() int64 { return int64(r.next() >> 1) }

func (r *goldenRand) Int63n(n int64) int64 { return int64(r.next() % uint64(n)) }

func (r *goldenRand) NormFloat64() float64 { return float64(int64(r.next())) / (1 << 52) }
