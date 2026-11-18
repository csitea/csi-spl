// SPDX-License-Identifier: AGPL-3.0-only

package evlog

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// C28 (spec 162 section 10.9): two 5xx that differ only in a UUID, a number
// and a quoted value share one fingerprint; another route or another token
// does not.
func TestFingerprintC28(t *testing.T) {
	const kind = "error.http_server"
	anchor := "GET /v1/things/{id} store_error"
	a := `500 store_error at hub.getThing: thing 0b7c9534-1111-2222-3333-444455556666 row 17 name "alpha"`
	b := `500 store_error at hub.getThing: thing 9f867807-aaaa-bbbb-cccc-ddddeeeeffff row 4242 name "beta gamma"`
	fa, fb := Fingerprint(kind, a, anchor), Fingerprint(kind, b, anchor)
	if fa != fb {
		t.Fatalf("same error, two fingerprints: %s (%q) vs %s (%q)", fa, Normalize(a), fb, Normalize(b))
	}
	if len(fa) != 16 || strings.Trim(fa, "0123456789abcdef") != "" {
		t.Fatalf("fingerprint %q is not 16 lower hex", fa)
	}
	if f := Fingerprint(kind, a, "GET /v1/other/{id} store_error"); f == fa {
		t.Errorf("another route kept fingerprint %s", f)
	}
	otherTok := strings.Replace(a, "store_error", "auth_error", 1)
	if f := Fingerprint(kind, otherTok, "GET /v1/things/{id} auth_error"); f == fa {
		t.Errorf("another token kept fingerprint %s", f)
	}
	if f := Fingerprint("error.panic", a, anchor); f == fa {
		t.Errorf("another kind kept fingerprint %s", f)
	}
}

// planted is one row of the C29 table: a line and the strings that must
// not survive Redact. Strings a secret scanner would match on sight (a PEM
// header, a JWT, a key=value pair) are built from parts; every value is an obvious fake.
type planted struct {
	rule, in string
	gone     []string
}

func plantedC29() []planted {
	jwt := "ey" + "JhbGciOiJub25lIn0" + "." + "ey" + "JzdWIiOiJwbGFudGVkIn0" + ".planted-sig-0008"
	pem := "-----BEGIN " + "PRIVATE KEY-----\nplanted-pem-body-0009\n-----END " + "PRIVATE KEY-----"
	return []planted{
		{"email", "mail to FirstName.LastName+t1@example.com bounced", []string{"FirstName.LastName+t1@example.com", "@example.com"}},
		{"bearer", "upstream said 401 for Bearer planted-bearer-0002 now", []string{"planted-bearer-0002"}},
		{"token=", "GET failed token=planted-token-0003 retry", []string{"planted-token-0003"}},
		{"password:", "login password: planted-pwd-0004 refused", []string{"planted-pwd-0004"}},
		{"json key", `body {"client_secret":"planted secret 0005","n":1}`, []string{"planted secret 0005"}},
		{"cookie", "Cookie: sid=planted-cookie-0006; theme=planted-cookie-0006b", []string{"planted-cookie-0006", "planted-cookie-0006b"}},
		{"authorization", "Authorization: Basic cGxhbnRlZDowMDA3", []string{"cGxhbnRlZDowMDA3"}},
		{"jwt", "session " + jwt + " expired", []string{jwt, "planted-sig-0008"}},
		{"pem", "key load failed: " + pem, []string{"planted-pem-body-0009", "PRIVATE KEY"}},
		{"query", "fetch https://api.example.com/v1/x?sig=planted-q-0010&a=1 failed", []string{"planted-q-0010", "a=1"}},
		{"userinfo", "dial https://planted-user:planted-pass-0011@db.example.com/x", []string{"planted-user", "planted-pass-0011"}},
		{"dsn", "open postgres://spool:planted-dsn-0012@127.0.0.1:5432/spool?sslmode=disable", []string{"planted-dsn-0012", "127.0.0.1:5432"}},
		{"blob", "unexpected value AAAAplantedBlob0013ZZZZZZZZ in frame", []string{"AAAAplantedBlob0013ZZZZZZZZ"}},
		{"mixed", "HUM-7 FirstName.LastName@example.com sent Bearer planted-mix-0014a via host=db.example.com port=5432 password=" + "planted-mix-0014b dbname=spool and api_key=" + "planted-mix-0014c",
			[]string{"FirstName.LastName@example.com", "planted-mix-0014a", "planted-mix-0014b", "planted-mix-0014c", "host=db.example.com"}},
	}
}

// C29 (10.6, 10.9): each of the 14 planted strings is gone after Redact.
// Red control: Redact as the identity fails here, naming the string.
func TestRedactC29(t *testing.T) {
	rows := plantedC29()
	if len(rows) != 14 {
		t.Fatalf("C29 table has %d rows, spec 162 10.6 plants 14", len(rows))
	}
	for _, p := range rows {
		out := Redact(p.in)
		for _, s := range p.gone {
			if strings.Contains(out, s) {
				t.Errorf("C29 %s: %q survived Redact: %q", p.rule, s, out)
			}
		}
		if n := Normalize(p.in); containsAny(n, p.gone) {
			t.Errorf("C29 %s: Normalize leaks: %q", p.rule, n)
		}
	}
}

func containsAny(s string, subs []string) bool {
	for _, x := range subs {
		if strings.Contains(s, x) {
			return true
		}
	}
	return false
}

// Redact keeps what is not a secret: plain words, a route, a UUID (an id,
// folded by Normalize, not by Redact).
func TestRedactKeeps(t *testing.T) {
	for _, in := range []string{
		"500 store_error at hub.getThing: no rows",
		"GET /v1/operator/events",
		"thing 0b7c9534-1111-2222-3333-444455556666 missing",
	} {
		if out := Redact(in); out != in {
			t.Errorf("Redact(%q) = %q, want it unchanged", in, out)
		}
	}
}

func TestNormalize(t *testing.T) {
	cases := []struct{ in, want string }{
		{"thing 0B7C9534-1111-2222-3333-444455556666 gone", "thing <uuid> gone"},
		{"HUM-10 asked c-672 twice", "HUM-<n> asked <agent> twice"},
		{"sha deadbeef01 at 12 of 3", "sha <hex> at <n> of <n>"},
		{`name "a b" and 'c' but can't`, "name <s> and <s> but can't"},
		{"  many \t blanks\n\nhere  ", "many blanks here"},
		{"x token=planted-norm-01", "x token=<redacted>"},
		{"abc-123 stays a word", "abc-<n> stays a word"},
	}
	for _, c := range cases {
		if got := Normalize(c.in); got != c.want {
			t.Errorf("Normalize(%q) = %q, want %q", c.in, got, c.want)
		}
		if got := Normalize(c.want); got != c.want {
			t.Errorf("Normalize is not idempotent on %q: %q", c.want, got)
		}
	}
	long := strings.Repeat("é ", 1000)
	if got := []rune(Normalize(long)); len(got) != MaxMessageRunes {
		t.Errorf("Normalize cut to %d runes, want %d", len(got), MaxMessageRunes)
	}
}

const stackPanic = `goroutine 42 [running]:
runtime/debug.Stack()
	/usr/local/go/src/runtime/debug/stack.go:26 +0x5e
github.com/csitea/csi-spl/spool-hub-api/internal/hub.(*Server).middleware.func1.1()
	/src/internal/hub/server.go:897 +0x6b
panic({0x1a2b3c0?, 0xc000123456?})
	/usr/local/go/src/runtime/panic.go:791 +0x132
github.com/csitea/csi-spl/spool-hub-api/internal/hub.(*Server).handleThing(0xc000010000, {0x1f00000, 0xc000200000}, 0xc000300000)
	/src/internal/hub/things.go:%d +0x1d
net/http.HandlerFunc.ServeHTTP(...)
	/usr/local/go/src/net/http/server.go:2294
`

func TestTopFrame(t *testing.T) {
	want := "github.com/csitea/csi-spl/spool-hub-api/internal/hub.(*Server).handleThing"
	a, b := fmt.Sprintf(stackPanic, 41), fmt.Sprintf(stackPanic, 97)
	if got := TopFrame(a); got != want {
		t.Fatalf("TopFrame = %q, want %q", got, want)
	}
	if TopFrame(a) != TopFrame(b) {
		t.Errorf("a moved line split the frame: %q vs %q", TopFrame(a), TopFrame(b))
	}
	noPanic := "goroutine 1 [running]:\ngithub.com/csitea/csi-spl/spool-hub-api/internal/hub.loop()\n\t/src/x.go:3 +0x1\n"
	if got := TopFrame(noPanic); got != "github.com/csitea/csi-spl/spool-hub-api/internal/hub.loop" {
		t.Errorf("TopFrame without panic( = %q", got)
	}
	foreign := "goroutine 1 [running]:\npanic({0x1, 0x2})\n\t/x.go:1\nnet/http.(*conn).serve(0xc0)\n\t/y.go:2\n"
	if got := TopFrame(foreign); got != "" {
		t.Errorf("TopFrame with no module frame = %q, want empty", got)
	}
}

func TestGroupsAddAndTake(t *testing.T) {
	g := NewGroups(10)
	t0 := time.Date(2026, 11, 19, 10, 0, 0, 0, time.UTC)
	s := Sighting{Kind: "error.http_server", Level: LevelError, Message: `500 x: row 1 "a"`, Anchor: "GET /a x"}
	for i := 0; i < 100; i++ {
		s.At, s.Message = t0.Add(time.Duration(50-i)*time.Second), fmt.Sprintf(`500 x: row %d "v%d"`, i, i)
		if _, kept := g.Add(s); !kept {
			t.Fatalf("sighting %d not kept under the cap", i)
		}
	}
	out := g.Take(t0)
	if len(out) != 1 {
		t.Fatalf("100 sightings of one error made %d groups, want 1", len(out))
	}
	gr := out[0]
	if gr.N != 100 || gr.Message != "<n> x: row <n> <s>" || gr.Level != LevelError {
		t.Errorf("group = %+v", gr)
	}
	if !gr.FirstAt.Equal(t0.Add(-49*time.Second)) || !gr.LastAt.Equal(t0.Add(50*time.Second)) {
		t.Errorf("first/last = %v / %v", gr.FirstAt, gr.LastAt)
	}
	if g.Len() != 0 || len(g.Take(t0)) != 0 {
		t.Errorf("Take did not empty the groups")
	}
}

// The cap of 10.4.5: past it a new fingerprint is counted, not kept, and
// Take adds one evlog.overflow group naming the count.
func TestGroupsCap(t *testing.T) {
	at := time.Date(2026, 11, 19, 10, 0, 0, 0, time.UTC)
	g := NewGroups(CapInProcess)
	for i := 0; i < CapInProcess+3; i++ {
		g.Add(Sighting{Kind: "error.log", Level: LevelError, Message: "boom", Anchor: fmt.Sprint("f", i), At: at})
	}
	g.Add(Sighting{Kind: "error.log", Level: LevelError, Message: "boom", Anchor: fmt.Sprint("f", CapInProcess), At: at})
	if _, kept := g.Add(Sighting{Kind: "error.log", Message: "boom", Anchor: "f0", At: at}); !kept {
		t.Errorf("a kept group refused a sighting past the cap")
	}
	if n := g.Len(); n != CapInProcess {
		t.Fatalf("kept %d groups, cap %d", n, CapInProcess)
	}
	out := g.Take(at)
	if len(out) != CapInProcess+1 {
		t.Fatalf("Take = %d groups, want %d + 1 overflow", len(out), CapInProcess)
	}
	ov := out[len(out)-1]
	want := "3 error groups not kept (cap 1000)"
	if ov.Kind != KindOverflow || ov.Level != LevelWarn || ov.Message != want || ov.N != 3 {
		t.Errorf("overflow = %+v, want %q N=3", ov, want)
	}
	if out[0].N != 2 {
		t.Errorf("first group N = %d, want 2", out[0].N)
	}
	if OverflowGroup(1, CapReader, at).Fingerprint == ov.Fingerprint {
		t.Errorf("reader and hub overflow share a fingerprint")
	}
}

// The set of dropped fingerprints is bounded by the cap too.
func TestGroupsDroppedSetBounded(t *testing.T) {
	g := NewGroups(1)
	for i := 0; i < 4; i++ {
		g.Add(Sighting{Kind: "error.log", Message: "boom", Anchor: fmt.Sprint("f", i)})
	}
	out := g.Take(time.Time{})
	if len(out) != 2 || out[1].N != 3 || len(g.dropped) != 0 {
		t.Errorf("Take = %+v, want 1 group + overflow N=3", out)
	}
}
