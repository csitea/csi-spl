package hub_test

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/077 T011 (FR-007, spec 3.5): visitor A signs in to the demo through
// the open admission (no invite); visitor B walks
// every read route the hub registers on the demo host, every path value
// naming A. No answer carries A's email or A's IdP name, and the roster
// names A by its pseudonym with no picture (the WUI draws the generated
// one). CONTROL: A's own session and the roster through A's browser show the
// pseudonym, and the walk does reach A (the roster carries A's HUM-*).
func TestDemoVisitorsSeeOnlyPseudonyms(t *testing.T) {
	s := newStayRig(t)
	rb := make([]byte, 4)
	rand.Read(rb) //nolint:errcheck
	tag := hex.EncodeToString(rb)
	emailA, idpNameA := "a"+tag+"@example.com", "Idpname"+tag+" Surname"
	signInAs(t, s.r, s.demo, fakeidp.Person{Subject: "sub-a" + tag, Email: emailA, EmailVerified: true, Name: idpNameA})
	humA := s.r.session(t).HumanID
	if humA == "" {
		t.Fatal("visitor A was not admitted by the open rule")
	}
	pseudoA := store.DemoPseudonym(humA)
	if code, body := s.r.req(t, http.MethodGet, "login", "/api/v1/auth/session", nil, nil); code != http.StatusOK ||
		!strings.Contains(body, `"name":"`+pseudoA+`"`) || strings.Contains(body, emailA) || strings.Contains(body, idpNameA) {
		t.Fatalf("CONTROL: A's own session: %d %s", code, body)
	}

	emailB := "b" + tag + "@example.com"
	signInAs(t, s.r, s.demo, fakeidp.Person{Subject: "sub-b" + tag, Email: emailB, EmailVerified: true, Name: "FirstName LastName"})
	code, roster := s.r.req(t, http.MethodGet, s.demo, "/v1/view/roster", nil, nil)
	if code != http.StatusOK || !strings.Contains(roster, humA) {
		t.Fatalf("CONTROL: B's roster does not reach A: %d %s", code, roster)
	}
	if !strings.Contains(roster, `"human_id":"`+humA+`","avatar_file_id":null,"display_name":"`+pseudoA+`"`) {
		t.Errorf("B's roster shows A not as %s with no picture: %s", pseudoA, roster)
	}

	vals := map[string][]string{"{human_id}": {humA}, "{id}": {humA}, "{channel}": {store.ChannelLobby},
		"{msg_id}": {humA}, "{task_id}": {lobby}, "{file_id}": {humA}, "{ref}": {humA}, "{path...}": {"index.md"},
		"{box}": {humA}, "{box_id}": {humA}, "{$}": {""}}
	hdr := http.Header{"Content-Type": {"application/json"}}
	for _, route := range readRoutes(t) {
		method, path, _ := strings.Cut(route, " ")
		for _, p := range expand(path, vals) {
			for _, q := range []string{"", "?q=" + tag} {
				body := ""
				if method == http.MethodPost {
					body = `{"ids":["` + humA + `"]}`
				}
				code, got := s.r.req(t, method, s.demo, p+q, hdr, strings.NewReader(body))
				got = strings.ReplaceAll(got, `"query":"`+tag+`"`, "<echo>")
				for _, leak := range []string{emailA, idpNameA, tag + "@"} {
					if strings.Contains(got, leak) {
						t.Errorf("%s %s%s: %d carries A's %q: %s", method, p, q, code, leak, got)
					}
				}
			}
		}
	}
}
