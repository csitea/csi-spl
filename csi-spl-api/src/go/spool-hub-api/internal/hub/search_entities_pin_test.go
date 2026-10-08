package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// TestSearchEntityRows pins the answer rows of the box, robot, user and
// channel sections byte for byte (tenant and human ids normalized), recorded
// before searchEntities was split into one collector per type (SPL-1029
// round 2). The issue, tenant and event rows are pinned by their own tests.
func TestSearchEntityRows(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.SearchRatePerMin = 1000
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) { return "", nil }
	})
	ctx := context.Background()
	ta, _ := e.tenant()
	at := fixtureAt()
	for _, b := range []string{"box-z", "box-a", "box-r"} {
		pub, _, _ := ed25519.GenerateKey(nil) // one live pin per key (rdb 0154)
		if err := e.st.PutPin(ctx, ta, b, pub, false, at, at); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.st.RevokePin(ctx, ta, "box-r", at.Add(time.Minute), at.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	e.st.SetRoster(ctx, ta, "box-a", []string{"GRK-03", "CLE-07"}, at) //nolint:errcheck
	e.st.SetRoster(ctx, ta, "box-z", []string{"AGY-01"}, at)           //nolint:errcheck
	h := e.st.(store.Humans)
	if err := h.PutInvite(ctx, store.Invite{TenantID: ta, Email: "ada-" + ta + "@example.com", Role: store.RoleDefault,
		InvitedBy: store.AdmittedOperator, ExpiresAt: at.Add(time.Hour)}, at); err != nil {
		t.Fatal(err)
	}
	ada, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: "ada-" + ta, Email: "ada-" + ta + "@example.com", Name: "Ada Person"},
		ta, store.AdmitPolicy{}, at)
	if err != nil {
		t.Fatal(err)
	}
	putMsg(t, e.st, ta, uuidV4(), "alerts", "CLE-07", "box-a", "GRK-03", "disk full", at.Add(2*time.Minute), "")
	norm := strings.NewReplacer(ta, "<T>", ada, "<HUM>")
	// the drivers differ on a pin that never said hello: memory stamps
	// last_hello_at at pin time, Postgres leaves it null
	hello := regexp.MustCompile(`"last_hello_at":("[^"]*"|null)`)
	for _, c := range []struct{ q, group, want string }{
		{"type:box", "boxes", `[{"agents":["CLE-07","GRK-03"],"box_id":"box-a","last_hello_at":<H>,"name":{"text":"box-a","highlights":[]},"online":false,"revoked":false},` +
			`{"agents":[],"box_id":"box-r","last_hello_at":<H>,"name":{"text":"box-r","highlights":[]},"online":false,"revoked":true},` +
			`{"agents":["AGY-01"],"box_id":"box-z","last_hello_at":<H>,"name":{"text":"box-z","highlights":[]},"online":false,"revoked":false}]`},
		{"type:robot", "robots", `[{"box":"box-z","id":"AGY-01","name":{"text":"AGY-01@box-z","highlights":[]},"online":false,"revoked":false},` +
			`{"box":"box-a","id":"CLE-07","name":{"text":"CLE-07@box-a","highlights":[]},"online":false,"revoked":false},` +
			`{"box":"box-a","id":"GRK-03","name":{"text":"GRK-03@box-a","highlights":[]},"online":false,"revoked":false}]`},
		{"type:user", "users", `[{"avatar_file_id":null,"display_name":"Ada Person","id":"<HUM>","name":{"text":"Ada Person (<HUM>)","highlights":[]},"online":false}]`},
		{"type:channel", "channels", `[{"channel":"alerts","count":1,"default":true,"last_ts":"` + at.Add(2*time.Minute).Format(time.RFC3339) + `","name":{"text":"alerts","highlights":[]}},` +
			`{"channel":"feedback","count":0,"default":true,"last_ts":null,"name":{"text":"feedback","highlights":[]}},` +
			`{"channel":"lobby","count":0,"default":true,"last_ts":null,"name":{"text":"lobby","highlights":[]}}]`},
		// t1 2b15a748: "#lobby", as the WUI writes a channel, finds it too
		{"type:channel #lobby", "channels", `[{"channel":"lobby","count":0,"default":true,"last_ts":null,"name":{"text":"lobby","highlights":[]}}]`},
		{"type:box box-a", "boxes", `[{"agents":["CLE-07","GRK-03"],"box_id":"box-a","last_hello_at":<H>,"name":{"text":"box-a","highlights":[[0,5]]},"online":false,"revoked":false}]`},
	} {
		code, _, body := viewGet(t, e, ta, "/v1/view/search?q="+url.QueryEscape(c.q))
		var out struct {
			Groups map[string]struct {
				Results json.RawMessage `json:"results"`
			} `json:"groups"`
		}
		if code != http.StatusOK || json.Unmarshal(body, &out) != nil {
			t.Fatalf("%q: %d %s", c.q, code, body)
		}
		got := hello.ReplaceAllString(norm.Replace(string(out.Groups[c.group].Results)), `"last_hello_at":<H>`)
		if got != c.want {
			t.Errorf("%q %s:\n got %s\nwant %s", c.q, c.group, got, c.want)
		}
	}
}
