package wire

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// crTagged is a struct with json tags: a renamed field, omitempty, a skipped
// field and a nested map, marshalled in declaration order.
type crTagged struct {
	Zed   int            `json:"zed"`
	Alpha string         `json:"alpha,omitempty"`
	Skip  string         `json:"-"`
	Inner map[string]any `json:"inner"`
}

// crCases are the values Canonical must encode exactly as its reference,
// canonicalDecode(json.Marshal(v)), does: wire.go says the two are
// byte-identical, and Canonical's bytes are what a box signs.
var crCases = []struct {
	name string
	v    any
}{
	{"unsorted map", map[string]any{"z": 1, "a": 2, "m": 3}},
	{"nested maps", map[string]any{"b": map[string]any{"y": map[string]any{"q": 1, "c": 2}, "x": 0}, "a": []any{map[string]any{"k": 1, "j": 2}}}},
	{"html chars", map[string]any{"a<b>": "x < y && y > z", "s": "</script>&amp;"}},
	{"non-ascii", map[string]any{"ключ": "é ü 漢字 😀", "a": "ñ"}},
	{"u2028 u2029", "line para end"},
	{"escaped quotes", map[string]any{`k"q`: `say "hi" \ back /`}},
	{"json.Number past float", map[string]any{"n": json.Number("12345678901234567890.123456789012345678"), "e": json.Number("1e400")}},
	{"empty map", map[string]any{}},
	{"empty slice", []any{}},
	{"empty string", ""},
	{"nil", nil},
	{"struct with tags", crTagged{Zed: 7, Skip: "gone", Inner: map[string]any{"b": true, "a": nil}}},
	{"raw duplicate keys", json.RawMessage(`{"a":1,"b":2,"a":3}`)},
	{"raw whitespace", json.RawMessage(" { \"b\" : [ 1 , 2 ] ,\n\t\"a\" : { } } ")},
	{"raw lone surrogate", json.RawMessage(`{"\ud800x":"\udc00","p":"😀"}`)},
	{"raw escapes", json.RawMessage(`"A\/\b\f\n\r\té "`)},
	{"invalid utf8", "bad\xffutf8\xc3"},
	{"deep nesting", crNest(64)},
}

// crNest is depth levels of {"d":[...]} around a string.
func crNest(depth int) json.RawMessage {
	return json.RawMessage(strings.Repeat(`{"d":[`, depth) + `"x"` + strings.Repeat(`]}`, depth))
}

// crReference is canonicalDecode applied to json.Marshal(v): the path
// Canonical took before the one-pass rewrite.
func crReference(t *testing.T, v any) []byte {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	want, err := canonicalDecode(raw)
	if err != nil {
		t.Fatalf("canonicalDecode: %v", err)
	}
	return want
}

func TestCanonicalMatchesReference(t *testing.T) {
	for _, tc := range crCases {
		t.Run(tc.name, func(t *testing.T) {
			want := crReference(t, tc.v)
			got, err := Canonical(tc.v)
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("Canonical:\n got  %q (%v)\n want %q", got, err, want)
			}
		})
	}
}

// TestCanonicalOnePassTakesEveryCase: for each case the one pass accepts the
// whole of json.Marshal(v), so Canonical never reaches its canonicalDecode
// fallback for them. With the golden, random and fuzz tests this is the
// search for a json.Marshal output that reaches it; none was found.
func TestCanonicalOnePassTakesEveryCase(t *testing.T) {
	for _, tc := range crCases {
		raw, err := json.Marshal(tc.v)
		if err != nil {
			t.Fatalf("%s: marshal: %v", tc.name, err)
		}
		c := canonBuf{src: raw}
		if n, ok := c.value(0); !ok || skipWS(raw, n) != len(raw) {
			t.Errorf("%s: one pass refused %q at %d", tc.name, raw, n)
		}
	}
}

func TestCanonicalUnmarshalable(t *testing.T) {
	_, want := json.Marshal(make(chan int))
	got, err := Canonical(map[string]any{"c": make(chan int)})
	if err == nil || got != nil {
		t.Fatalf("Canonical(chan) = %q, %v; want the marshal error", got, err)
	}
	if want == nil || err.Error() != want.Error() {
		t.Errorf("err = %v; want json's %v", err, want)
	}
}

// TestCanonicalDecodeRefusesBadJSON: the reference itself returns the decode
// error instead of bytes.
func TestCanonicalDecodeRefusesBadJSON(t *testing.T) {
	for _, raw := range []string{``, `{`, `{"a":}`, `"\x"`} {
		if got, err := canonicalDecode([]byte(raw)); err == nil {
			t.Errorf("canonicalDecode(%q) = %q, nil; want an error", raw, got)
		}
	}
}
