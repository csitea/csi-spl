package marketing_test

import (
	"encoding"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
)

// redactFakeToken is a made-up token; no real credential looks like it.
const redactFakeToken = "fake-oauth-token-r46-06-not-a-secret"

// redactWant is what every printed or encoded form of a Plaintext shows.
const redactWant = "[redacted]"

// TestPlaintextGoStringAndTextRedact covers the two Plaintext encoders the
// fmt verbs never reach (Format wins over GoString for %#v): GoString called
// as a fmt.GoStringer, and MarshalText, alone and as a JSON map key. Each holds
// the redaction text and never the token; Reveal still returns the token.
func TestPlaintextGoStringAndTextRedact(t *testing.T) {
	p := marketing.NewPlaintext(redactFakeToken)
	holder := struct{ Token marketing.Plaintext }{p}

	text, err := p.MarshalText()
	if err != nil {
		t.Fatalf("MarshalText: %v", err)
	}
	var tm encoding.TextMarshaler = p
	viaIface, err := tm.MarshalText()
	if err != nil {
		t.Fatalf("TextMarshaler: %v", err)
	}
	keyJSON, err := json.Marshal(map[marketing.Plaintext]int{p: 1})
	if err != nil {
		t.Fatalf("json map key: %v", err)
	}
	var gs fmt.GoStringer = p
	cases := map[string]string{
		"GoString":       p.GoString(),
		"fmt.GoStringer": gs.GoString(),
		"%#v":            fmt.Sprintf("%#v", p),
		"%#v holder":     fmt.Sprintf("%#v", holder),
		"MarshalText":    string(text),
		"TextMarshaler":  string(viaIface),
		"json map key":   string(keyJSON),
	}
	for name, got := range cases {
		if strings.Contains(got, redactFakeToken) {
			t.Errorf("%s leaks the token: %q", name, got)
		}
		if !strings.Contains(got, redactWant) {
			t.Errorf("%s = %q, want it to hold %q", name, got, redactWant)
		}
	}
	if got, want := string(keyJSON), `{"`+redactWant+`":1}`; got != want {
		t.Errorf("json map key = %s, want %s", got, want)
	}
	if got := p.Reveal(); got != redactFakeToken {
		t.Errorf("Reveal = %q, want the token", got)
	}
}
