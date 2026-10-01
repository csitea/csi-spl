package auth

import (
	"encoding/json"
	"testing"
)

// CLE-77908 (owner, topic 07b84fd7): the time zone is a per-tenant override,
// null = the browser's zone.
func TestIsTimeZone(t *testing.T) {
	for _, ok := range []string{"Europe/Helsinki", "UTC", "America/Argentina/Buenos_Aires", "Etc/GMT+3", "America/Port-au-Prince"} {
		if !IsTimeZone(ok) {
			t.Errorf("%q refused", ok)
		}
	}
	for _, bad := range []string{"", "Europe/", "/Helsinki", "Europe Helsinki", "a/b/c/d", "<script>", "Europe/../etc"} {
		if IsTimeZone(bad) {
			t.Errorf("%q admitted", bad)
		}
	}
}

func TestParseTimeZone(t *testing.T) {
	if v, has, code, _ := parseTimeZone(json.RawMessage(`"Europe/Helsinki"`)); v != "Europe/Helsinki" || !has || code != "" {
		t.Fatalf("zone: %q %v %q", v, has, code)
	}
	if v, has, code, _ := parseTimeZone(json.RawMessage(`null`)); v != "" || !has || code != "" {
		t.Fatalf("null clears: %q %v %q", v, has, code)
	}
	if _, has, _, _ := parseTimeZone(nil); has {
		t.Fatal("absent must not be has")
	}
	for _, bad := range []string{`42`, `"no spaces/allowed here"`, `{"z":1}`} {
		if _, _, code, _ := parseTimeZone(json.RawMessage(bad)); code != "unsupported_time_zone" {
			t.Errorf("%s: code %q", bad, code)
		}
	}
}

func TestOverlayTimeZone(t *testing.T) {
	helsinki := "Europe/Helsinki"
	if got := (HumanSettings{}).Overlay(MembershipSettings{TimeZone: &helsinki}).TimeZone; got != helsinki {
		t.Fatalf("overlay: %q", got)
	}
	if got := (HumanSettings{}).Overlay(MembershipSettings{}).TimeZone; got != "" {
		t.Fatalf("no override must stay the browser's zone: %q", got)
	}
	in := parseOK(t, `{"time_zone":"Europe/Helsinki"}`)
	if p := in.membershipPatch(); p["time_zone"] != helsinki {
		t.Fatalf("patch: %+v", p)
	}
	if p := parseOK(t, `{"time_zone":null}`).membershipPatch(); p["time_zone"] != nil {
		t.Fatalf("null must clear: %+v", p)
	} else if _, ok := p["time_zone"]; !ok {
		t.Fatal("null must be in the patch (clears the key)")
	}
}

func parseOK(t *testing.T, body string) prefsIn {
	t.Helper()
	var req preferencesReq
	if err := json.Unmarshal([]byte(body), &req); err != nil {
		t.Fatal(err)
	}
	p, code, detail := parsePreferences(req)
	if code != "" {
		t.Fatalf("%s: %s %s", body, code, detail)
	}
	return p
}
