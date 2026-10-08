package auth

import (
	"encoding/json"
	"testing"
)

// Spec 107 section 1.2: "Count my reading time" is a per-tenant override,
// null = on.
func TestParseHoursReading(t *testing.T) {
	if v, has, code, _ := parseHoursReading(json.RawMessage(`false`)); v == nil || *v || !has || code != "" {
		t.Fatalf("false: %v %v %q", v, has, code)
	}
	if v, has, code, _ := parseHoursReading(json.RawMessage(`true`)); v == nil || !*v || !has || code != "" {
		t.Fatalf("true: %v %v %q", v, has, code)
	}
	if v, has, code, _ := parseHoursReading(json.RawMessage(`null`)); v != nil || !has || code != "" {
		t.Fatalf("null clears: %v %v %q", v, has, code)
	}
	if _, has, _, _ := parseHoursReading(nil); has {
		t.Fatal("absent must not be has")
	}
	for _, bad := range []string{`"off"`, `1`, `{}`} {
		if _, _, code, _ := parseHoursReading(json.RawMessage(bad)); code != "unsupported_hours_reading" {
			t.Errorf("%s: code %q", bad, code)
		}
	}
}

func TestOverlayHoursReading(t *testing.T) {
	off := false
	if got := (HumanSettings{}).Overlay(MembershipSettings{HoursReading: &off}).HoursReading; got == nil || *got {
		t.Fatalf("overlay: %v", got)
	}
	if got := (HumanSettings{}).Overlay(MembershipSettings{}).HoursReading; got != nil {
		t.Fatalf("no override must stay unset (on): %v", *got)
	}
	if p := parseOK(t, `{"hours_reading":false}`).membershipPatch(); p["hours_reading"] != false {
		t.Fatalf("patch: %+v", p)
	}
	if p := parseOK(t, `{"hours_reading":null}`).membershipPatch(); p["hours_reading"] != nil {
		t.Fatalf("null must clear: %+v", p)
	} else if _, ok := p["hours_reading"]; !ok {
		t.Fatal("null must be in the patch (clears the key)")
	}
}
