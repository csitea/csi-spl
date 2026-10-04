package auth

import (
	"encoding/json"
	"testing"
)

// HUM-10 (topic ae2e5093): the message shortcuts switch is a per-tenant
// override, null = on.
func TestParseKeyboardShortcuts(t *testing.T) {
	if v, has, code, _ := parseKeyboardShortcuts(json.RawMessage(`false`)); v == nil || *v || !has || code != "" {
		t.Fatalf("false: %v %v %q", v, has, code)
	}
	if v, has, code, _ := parseKeyboardShortcuts(json.RawMessage(`true`)); v == nil || !*v || !has || code != "" {
		t.Fatalf("true: %v %v %q", v, has, code)
	}
	if v, has, code, _ := parseKeyboardShortcuts(json.RawMessage(`null`)); v != nil || !has || code != "" {
		t.Fatalf("null clears: %v %v %q", v, has, code)
	}
	if _, has, _, _ := parseKeyboardShortcuts(nil); has {
		t.Fatal("absent must not be has")
	}
	for _, bad := range []string{`"off"`, `1`, `{}`} {
		if _, _, code, _ := parseKeyboardShortcuts(json.RawMessage(bad)); code != "unsupported_keyboard_shortcuts" {
			t.Errorf("%s: code %q", bad, code)
		}
	}
}

func TestOverlayKeyboardShortcuts(t *testing.T) {
	off := false
	if got := (HumanSettings{}).Overlay(MembershipSettings{KeyboardShortcuts: &off}).KeyboardShortcuts; got == nil || *got {
		t.Fatalf("overlay: %v", got)
	}
	if got := (HumanSettings{}).Overlay(MembershipSettings{}).KeyboardShortcuts; got != nil {
		t.Fatalf("no override must stay unset (on): %v", *got)
	}
	if p := parseOK(t, `{"keyboard_shortcuts":false}`).membershipPatch(); p["keyboard_shortcuts"] != false {
		t.Fatalf("patch: %+v", p)
	}
	if p := parseOK(t, `{"keyboard_shortcuts":null}`).membershipPatch(); p["keyboard_shortcuts"] != nil {
		t.Fatalf("null must clear: %+v", p)
	} else if _, ok := p["keyboard_shortcuts"]; !ok {
		t.Fatal("null must be in the patch (clears the key)")
	}
}
