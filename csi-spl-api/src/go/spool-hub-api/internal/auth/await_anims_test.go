package auth

import (
	"encoding/json"
	"strings"
	"testing"
)

// SPL-2113: the ticked thinking animations are a per-tenant override, null =
// the WUI's default set; the hub checks the shape, the WUI owns the ids.
func TestParseAwaitAnims(t *testing.T) {
	if v, has, code, _ := parseAwaitAnims(json.RawMessage(`["robot","dancing-robot"]`)); !has || code != "" || strings.Join(v, ",") != "robot,dancing-robot" {
		t.Fatalf("list: %v %v %q", v, has, code)
	}
	if v, has, code, _ := parseAwaitAnims(json.RawMessage(`null`)); v != nil || !has || code != "" {
		t.Fatalf("null clears: %v %v %q", v, has, code)
	}
	if _, has, _, _ := parseAwaitAnims(nil); has {
		t.Fatal("absent must not be has")
	}
	many := make([]string, AwaitAnimsMax+1)
	for i := range many {
		many[i] = "a" + strings.Repeat("b", i%30) + string(rune('a'+i%26)) + string(rune('a'+i/26))
	}
	tooMany, _ := json.Marshal(many)
	for _, bad := range []string{`[]`, `"robot"`, `true`, `{}`, `["robot","robot"]`, `["Robot"]`, `["9lives"]`, `[""]`, `["a b"]`, `[1]`, `["` + strings.Repeat("a", 33) + `"]`, string(tooMany)} {
		if _, _, code, _ := parseAwaitAnims(json.RawMessage(bad)); code != "unsupported_await_anims" {
			t.Errorf("%.40s: code %q", bad, code)
		}
	}
}

func TestOverlayAwaitAnims(t *testing.T) {
	if got := (HumanSettings{}).Overlay(MembershipSettings{AwaitAnims: []string{"brain"}}).AwaitAnims; strings.Join(got, ",") != "brain" {
		t.Fatalf("overlay: %v", got)
	}
	if got := (HumanSettings{}).Overlay(MembershipSettings{}).AwaitAnims; got != nil {
		t.Fatalf("no override must stay unset: %v", got)
	}
	if p := parseOK(t, `{"await_anims":["hourglass","robot"]}`).membershipPatch(); strings.Join(p["await_anims"].([]string), ",") != "hourglass,robot" {
		t.Fatalf("patch: %+v", p)
	}
	if p := parseOK(t, `{"await_anims":null}`).membershipPatch(); p["await_anims"] != nil {
		t.Fatalf("null must clear: %+v", p)
	} else if _, ok := p["await_anims"]; !ok {
		t.Fatal("null must be in the patch (clears the key)")
	}
	var m MembershipSettings
	if err := json.Unmarshal([]byte(`{"await_anims":["robot"]}`), &m); err != nil || strings.Join(m.AwaitAnims, ",") != "robot" {
		t.Fatalf("jsonb decode: %v %v", m.AwaitAnims, err)
	}
}
