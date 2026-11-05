package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// boxPinsOf reads a box-pins answer's list as strings.
func boxPinsOf(t *testing.T, body map[string]any) []string {
	t.Helper()
	raw, ok := body["box_pins"].([]any)
	if !ok {
		t.Fatalf("box_pins is not a list: %v", body)
	}
	out := make([]string, 0, len(raw))
	for _, b := range raw {
		out = append(out, b.(string))
	}
	return out
}

// pinBox pins a fresh key for box in tenant (the workspace pins table).
func pinBox(t *testing.T, e *env, tenant, box string) {
	t.Helper()
	pub, _, _ := ed25519.GenerateKey(nil)
	now := time.Now()
	if err := e.st.PutPin(context.Background(), tenant, box, pub, true, now, now); err != nil {
		t.Fatal(err)
	}
}

// Spec 164 row B2: GET and PUT a channel's box pins, the operator PUT and
// the box_pins of GET /v1/tenant/channels. The CONTROLS (spec 164 section 8):
// a member without tenant.settings is 403, an unknown or revoked box is 400
// unknown_box, a default channel is 400 channel_default_unpinnable; none of
// them changes the stored pins.
func TestChannelBoxPinsAPI(t *testing.T) {
	e := rbacEnv(t, func(o *hub.Options) {
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			if token == "good" {
				return operatorSA, nil
			}
			return "", errors.New("token rejected")
		}
	})
	ta, _ := e.tenant()
	tb, _ := e.tenant()
	admin, dev := seat(t, e, ta, rbac.Admin), seat(t, e, ta, rbac.Developer)
	adminB := seat(t, e, tb, rbac.Admin)
	if code, out := call(t, e, ta, http.MethodPost, "/v1/channels", dev, map[string]string{"channel": "deploys", "name": "Deploys"}); code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	pinBox(t, e, ta, "box-x")
	pinBox(t, e, ta, "box-y")
	pinBox(t, e, ta, "box-r")
	if err := e.st.RevokePin(context.Background(), ta, "box-r", time.Now(), time.Now()); err != nil {
		t.Fatal(err)
	}
	pinBox(t, e, tb, "box-b") // pinned in B only
	const path = "/v1/channels/deploys/box-pins"
	put := func(as string, boxes any) (int, map[string]any) {
		return call(t, e, ta, http.MethodPut, path, as, map[string]any{"box_pins": boxes})
	}
	want := func(as string, boxes ...string) {
		t.Helper()
		code, body := call(t, e, ta, http.MethodGet, path, as, nil)
		got := boxPinsOf(t, body)
		if code != http.StatusOK || body["channel"] != "deploys" || body["is_pinned"] != (len(boxes) > 0) ||
			fmt.Sprint(got) != fmt.Sprint(boxes) {
			t.Fatalf("GET as %s: %d %v, want box_pins %v", as, code, body, boxes)
		}
	}

	// Unpinned by default; a channel member without tenant.settings reads it.
	want(dev)
	// CONTROL: a member without tenant.settings cannot set it.
	if code, body := put(dev, []string{"box-x"}); code != http.StatusForbidden || body["permission"] != rbac.TenantSettings {
		t.Fatalf("CONTROL: developer PUT: %d %v, want 403 %s", code, body, rbac.TenantSettings)
	}
	want(dev)

	// The admin (not a member of #deploys) pins two boxes: sorted, deduped.
	if code, body := put(admin, []string{"box-y", " box-x", "box-y"}); code != http.StatusOK ||
		fmt.Sprint(boxPinsOf(t, body)) != "[box-x box-y]" || body["is_pinned"] != true {
		t.Fatalf("admin PUT: %d %v", code, body)
	}
	want(dev, "box-x", "box-y")

	// CONTROL: an unknown box, a revoked box, another workspace's box: 400
	// unknown_box and the pins stay.
	for _, bad := range []string{"box-z", "box-r", "box-b", "Bad Box"} {
		if code, body := put(admin, []string{"box-x", bad}); code != http.StatusBadRequest || body["error"] != "unknown_box" {
			t.Fatalf("CONTROL: PUT %s: %d %v, want 400 unknown_box", bad, code, body)
		}
	}
	want(dev, "box-x", "box-y")

	// CONTROL: a default channel stays on every box (owner Q1 = A).
	for _, ch := range []string{"lobby", "alerts", "feedback", "public", "issues"} {
		code, body := call(t, e, ta, http.MethodPut, "/v1/channels/"+ch+"/box-pins", admin, map[string]any{"box_pins": []string{"box-x"}})
		if code != http.StatusBadRequest || body["error"] != "channel_default_unpinnable" {
			t.Fatalf("CONTROL: PUT #%s: %d %v, want 400 channel_default_unpinnable", ch, code, body)
		}
	}
	if code, body := call(t, e, ta, http.MethodGet, "/v1/channels/lobby/box-pins", dev, nil); code != http.StatusOK || body["is_pinned"] != false {
		t.Fatalf("GET #lobby: %d %v", code, body)
	}

	// An unknown channel is 404; a body without box_pins is 400.
	if code, body := call(t, e, ta, http.MethodPut, "/v1/channels/nope/box-pins", admin, map[string]any{"box_pins": []string{}}); code != http.StatusNotFound || body["error"] != "unknown_channel" {
		t.Fatalf("PUT unknown channel: %d %v", code, body)
	}
	if code, body := call(t, e, ta, http.MethodPut, path, admin, map[string]any{}); code != http.StatusBadRequest || body["error"] != "bad_json" {
		t.Fatalf("PUT without box_pins: %d %v", code, body)
	}
	// Another workspace's admin sets nothing here.
	if code, _ := put(adminB, []string{"box-x"}); code != http.StatusForbidden {
		t.Fatalf("B's admin PUT on A: %d, want 403", code)
	}
	want(dev, "box-x", "box-y")

	// GET /v1/tenant/channels carries box_pins on every row ([] = unpinned).
	code, body := call(t, e, ta, http.MethodGet, "/v1/tenant/channels", admin, nil)
	if code != http.StatusOK {
		t.Fatalf("tenant channels: %d %v", code, body)
	}
	rows := map[string]string{}
	for _, c := range body["channels"].([]any) {
		m := c.(map[string]any)
		rows[m["channel"].(string)] = fmt.Sprint(boxPinsOf(t, m))
	}
	if rows["deploys"] != "[box-x box-y]" || rows["lobby"] != "[]" {
		t.Fatalf("tenant channels box_pins: %v", rows)
	}

	// [] clears the pin: back to any box.
	if code, body := put(admin, []string{}); code != http.StatusOK || body["is_pinned"] != false {
		t.Fatalf("clear: %d %v", code, body)
	}
	want(dev)
	// The read door: an admin outside the private channel reads its pins in
	// the tenant list above, not here (404, as every channel read).
	if code, _ := call(t, e, ta, http.MethodGet, path, admin, nil); code != http.StatusNotFound {
		t.Fatalf("GET as a non-member admin: %d, want 404", code)
	}

	// The operator form, in the workspace its ?tenant= names.
	opPath := "/v1/operator/channels/deploys/box-pins?tenant=" + ta
	if code, body := opCall(t, e, ta, http.MethodPut, opPath, "good", map[string]any{"box_pins": []string{"box-y"}}); code != http.StatusOK ||
		fmt.Sprint(boxPinsOf(t, body)) != "[box-y]" {
		t.Fatalf("operator PUT: %d %v", code, body)
	}
	want(dev, "box-y")
	for _, c := range []struct {
		name, host, path, token string
		boxes                   []string
		code                    int
		errCode                 string
	}{
		{"B's host naming A", tb, opPath, "good", []string{"box-x"}, http.StatusForbidden, "tenant_mismatch"},
		{"no token", ta, opPath, "", []string{"box-x"}, http.StatusUnauthorized, "no_token"},
		{"bad token", ta, opPath, "nope", []string{"box-x"}, http.StatusUnauthorized, "bad_token"},
		{"a default channel", ta, "/v1/operator/channels/lobby/box-pins?tenant=" + ta, "good", []string{"box-x"}, http.StatusBadRequest, "channel_default_unpinnable"},
		{"a revoked box", ta, opPath, "good", []string{"box-r"}, http.StatusBadRequest, "unknown_box"},
		{"B's box in A", ta, opPath, "good", []string{"box-b"}, http.StatusBadRequest, "unknown_box"},
	} {
		code, body := opCall(t, e, c.host, http.MethodPut, c.path, c.token, map[string]any{"box_pins": c.boxes})
		if code != c.code || body["error"] != c.errCode {
			t.Fatalf("CONTROL operator %s: %d %v, want %d %s", c.name, code, body, c.code, c.errCode)
		}
	}
	want(dev, "box-y")

	// An archived channel is unknown to both doors' PUT.
	if code, body := call(t, e, ta, http.MethodDelete, "/v1/tenant/channels/deploys", admin, nil); code != http.StatusNoContent {
		t.Fatalf("archive: %d %v", code, body)
	}
	if code, body := put(admin, []string{"box-x"}); code != http.StatusNotFound || body["error"] != "unknown_channel" {
		t.Fatalf("PUT archived channel: %d %v, want 404 unknown_channel", code, body)
	}
}
