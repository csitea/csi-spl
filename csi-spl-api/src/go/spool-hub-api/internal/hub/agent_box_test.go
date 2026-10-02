package hub

import "testing"

// spec 061 3.3.1: c-004 on two machines is two agents. <ID>@<box> picks one;
// a bare id resolves while one box announces it and is refused once two do.
func TestLocateAgent(t *testing.T) {
	roster := map[string][]string{
		"box-desk": {"CLE-77952", "c-004"},
		"sat":      {"c-004", "c-005"},
		WUIBox:     {"c-006"},
	}
	for _, c := range []struct {
		ref, id, box, tok string
	}{
		{"c-004@box-desk", "c-004", "box-desk", ""},
		{"c-004@sat", "c-004", "sat", ""},
		{"c-005", "c-005", "sat", ""},
		{"CLE-77952", "CLE-77952", "box-desk", ""},
		{"c-004", "", "", "ambiguous_agent"},
		{"c-005@box-desk", "", "", "unknown_agent"},
		{"c-006", "", "", "unknown_agent"}, // box-wui announces no agent of its own
		{"c-007", "", "", "unknown_agent"},
		{"c-004@Sat", "", "", "bad_agent"},
		{"HUM-1", "", "", "bad_agent"},
	} {
		got, re := locateAgent(roster, c.ref)
		tok := ""
		if re != nil {
			tok = re.token
		}
		if tok != c.tok || got.ID != c.id || got.Box != c.box {
			t.Errorf("%s: got %+v %q, want %s@%s %q", c.ref, got, tok, c.id, c.box, c.tok)
		}
	}
	if _, re := locateAgent(roster, "c-004"); re == nil || re.detail != "c-004 is ambiguous: c-004@box-desk, c-004@sat; add @<box>" {
		t.Fatalf("ambiguous detail names both boxes: %+v", re)
	}
}
