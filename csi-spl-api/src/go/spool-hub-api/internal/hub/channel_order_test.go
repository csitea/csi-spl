package hub_test

import (
	"net/http"
	"reflect"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-1034 (specs/045 §3.8, contracts/move-v1.md §7): PUT /v1/me/channel-order
// keeps a person's own Channels order, GET /v1/view/me answers it, another
// member's order is untouched (the control), [] clears it, and a bad list or
// a caller without a member session is refused.
func TestChannelOrderPref(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	a := seat(t, e, tid, rbac.Developer)
	b := seat(t, e, tid, rbac.Developer)
	put := func(as string, order any) (int, map[string]any) {
		t.Helper()
		return call(t, e, tid, http.MethodPut, "/v1/me/channel-order", as, map[string]any{"channel_order": order})
	}
	order := func(as string) []any {
		t.Helper()
		code, me := call(t, e, tid, http.MethodGet, "/v1/view/me", as, nil)
		if code != http.StatusOK {
			t.Fatalf("me %s: %d %v", as, code, me)
		}
		if _, present := me["channel_order"]; !present {
			t.Fatalf("me %s carries no channel_order key: %v", as, me)
		}
		got, _ := me["channel_order"].([]any)
		return got
	}

	if got := order(a); got != nil {
		t.Fatalf("never set: %v", got)
	}
	code, out := put(a, []string{"ops", "#Devel", "ops", "lobby"})
	if code != http.StatusOK || !reflect.DeepEqual(out["channel_order"], []any{"ops", "devel", "lobby"}) {
		t.Fatalf("put: %d %v", code, out)
	}
	if got := order(a); !reflect.DeepEqual(got, []any{"ops", "devel", "lobby"}) {
		t.Fatalf("a's order: %v", got)
	}
	if got := order(b); got != nil {
		t.Fatalf("CONTROL: another member's order changed: %v", got)
	}

	many := make([]string, 201)
	for i := range many {
		many[i] = "c" + strings.Repeat("x", i%5) + string(rune('a'+i%26))
	}
	for name, bad := range map[string]any{
		"not a channel id": []string{"no spaces allowed"},
		"not a list":       "ops",
		"too many":         many,
	} {
		if code, out := put(a, bad); code != http.StatusBadRequest || out["error"] != "bad_json" {
			t.Fatalf("%s: %d %v", name, code, out)
		}
	}
	if code, _ := put("", []string{"ops"}); code != http.StatusForbidden {
		t.Fatalf("no session: %d", code)
	}
	if got := order(a); len(got) != 3 {
		t.Fatalf("a refusal changed the order: %v", got)
	}

	code, out = put(a, []string{})
	if code != http.StatusOK || out["channel_order"] != nil {
		t.Fatalf("clear: %d %v", code, out)
	}
	if got := order(a); got != nil {
		t.Fatalf("after clear: %v", got)
	}
}

func TestChannelOrderPreflight(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	req, _ := http.NewRequest(http.MethodOptions, e.url(tid)+"/v1/me/channel-order", nil)
	req.Header.Set("Origin", wuiOrigin)
	req.Header.Set("Access-Control-Request-Method", "PUT")
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent || resp.Header.Get("Access-Control-Allow-Methods") != "PUT" ||
		resp.Header.Get("Access-Control-Allow-Headers") != "Authorization, Content-Type, X-Locale" {
		t.Fatalf("preflight: %d %q", resp.StatusCode, resp.Header.Get("Access-Control-Allow-Methods"))
	}
}
