package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-959: GET /v1/view/locate/{id} names the tenant of an old link's topic or
// message uuid, among the caller's OWN tenants only. Another tenant's uuid
// reads exactly like an unknown one.
func TestViewLocate(t *testing.T) {
	r := newDoorRig(t)
	a, _ := r.e.tenant()
	b, _ := r.e.tenant()
	c, _ := r.e.tenant()
	sub := "locate-" + a
	r.fake.Set(fakeidp.Person{Subject: sub, Email: sub + "@example.com", EmailVerified: true, Name: "FirstName LastName"}, false)
	hs := r.e.st.(store.Humans)
	for _, tn := range []string{a, b} {
		if _, err := hs.Admit(context.Background(), store.Identity{Provider: "google", Subject: sub, Email: sub + "@example.com"},
			tn, store.AdmitPolicy{BootstrapOwner: true}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	ownedBy(t, r.e, c, "owner-of-c-"+c)
	now := time.Now().UTC()
	inB := putRow(t, r.e, b, uuidV4(), "general", "HUM-1", "HUM-1", "in b", now)
	inC := putRow(t, r.e, c, uuidV4(), "general", "HUM-1", "HUM-1", "in c", now)

	locate := func(id string) (int, string) {
		t.Helper()
		return r.req(t, http.MethodGet, apiLabel, "/v1/view/locate/"+id, nil, nil)
	}
	// CONTROL: no session, no answer.
	if code, body := locate(inB.TaskID); code != http.StatusUnauthorized {
		t.Fatalf("anonymous locate: %d %s", code, body)
	}
	if landed := r.signIn(t, a); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in: %s", landed)
	}
	for _, id := range []string{inB.TaskID, inB.MsgID} { // a topic link and a message link
		if code, body := locate(id); code != http.StatusOK || !strings.Contains(body, `"tenant":"`+b+`"`) {
			t.Fatalf("locate %s in B while bound to A: %d %s", id, code, body)
		}
	}
	// Not a member of C: its uuid is as unknown as an invented one.
	codeC, bodyC := locate(inC.TaskID)
	codeX, bodyX := locate(uuidV4())
	if codeC != http.StatusNotFound || codeX != http.StatusNotFound || errToken([]byte(bodyC)) != errToken([]byte(bodyX)) || strings.Contains(bodyC, c) {
		t.Fatalf("foreign uuid %d %s vs unknown %d %s", codeC, bodyC, codeX, bodyX)
	}
	if code, _ := locate("Not-A-UUID"); code != http.StatusBadRequest {
		t.Fatalf("bad id: %d", code)
	}
}
