package action

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

// TestAskOd drives the OD pool's ops (spec 134 3.4) through Ask: what the
// client refuses before dialling, and the body the hub sees.
func TestAskOd(t *testing.T) {
	h := newVerbHub(t)
	cfg := hubCfg(t, h)
	job := AskArgs{Fleet: "csi", Op: "enqueue", AskID: askID, Kind: "route_post", From: "c-002@sat", Topic: "dispatch-1",
		Summary: "one line", IssueKey: "SPL-1", DedupeKey: "route:t1", VendorAllow: "grok", Needs: "prd", LeaseS: 300, NeedsOwner: true}
	lock := AskArgs{Fleet: "csi", Op: "lock-next", Seat: "c-001@sat", Vendor: "claude", Harness: "claude", Caps: []string{"prd"}}
	with := func(a AskArgs, f func(*AskArgs)) AskArgs { f(&a); return a }
	cases := []struct {
		name string
		in   AskArgs
		want string // error substring; "" = ok
		body map[string]string
	}{
		{"enqueue", job, "", map[string]string{"kind": `"route_post"`, "dedupe_key": `"route:t1"`, "vendor_allow": `"grok"`,
			"needs": `"prd"`, "lease_s": "300", "needs_owner": "true", "issue_key": `"SPL-1"`}},
		{"enqueue with deadline", with(job, func(a *AskArgs) { a.Deadline = "2026-10-02T06:00:00Z" }), "", map[string]string{"deadline_at": `"2026-10-02T06:00:00Z"`}},
		{"enqueue bad deadline", with(job, func(a *AskArgs) { a.Deadline = "soon" }), "--deadline must be RFC 3339", nil},
		{"enqueue bad kind", with(job, func(a *AskArgs) { a.Kind = "blocker" }), "ask: kind must be route_post", nil},
		{"enqueue bad vendor", with(job, func(a *AskArgs) { a.VendorAllow = "qwen" }), "ask: vendor_allow must be", nil},
		{"enqueue bad lease", with(job, func(a *AskArgs) { a.LeaseS = 5 }), "ask: lease_s must be", nil},
		{"lock-next", lock, "", map[string]string{"seat": `"c-001@sat"`, "vendor": `"claude"`, "caps": `["prd"]`}},
		{"lock-next no seat", with(lock, func(a *AskArgs) { a.Seat = "" }), "ask: seat must be", nil},
		{"lock-next bad cap", with(lock, func(a *AskArgs) { a.Caps = []string{"box:sat"} }), "ask: caps may hold prd only", nil},
		{"pool read", AskArgs{Fleet: "csi", Op: "pool"}, "", nil},
		{"pool set", AskArgs{Fleet: "csi", Op: "pool", PoolSet: true, By: "c-002@sat", Pool: map[string]any{"claude_n": 2}},
			"", map[string]string{"set": "true", "by": `"c-002@sat"`, "claude_n": "2"}},
		{"list free", AskArgs{Fleet: "csi", Op: "list", Role: "od", Free: true}, "", map[string]string{"free": "true", "role": `"od"`}},
		{"list free not od", AskArgs{Fleet: "csi", Op: "list", Role: "orch", Free: true}, "ask: --free lists --role od only", nil},
		{"seat release", AskArgs{Fleet: "csi", Op: "release", By: "c-001@sat"}, "", map[string]string{"by": `"c-001@sat"`}},
		{"seat release no by", AskArgs{Fleet: "csi", Op: "release"}, "ask: a seat release needs --by", nil},
		{"renew at gen", AskArgs{Fleet: "csi", Op: "renew", AskID: askID, By: "c-001@sat", Gen: 3}, "", map[string]string{"gen": "3"}},
		{"decline refuse", AskArgs{Fleet: "csi", Op: "decline", AskID: askID, By: "c-001@sat", Gen: 3, Reason: "no", Refuse: "claude"},
			"", map[string]string{"refuse": `"claude"`}},
		{"queue placement", AskArgs{Fleet: "csi", Op: "queue", AskID: askID, By: "c-001@sat", Place: "claude:s134"},
			"", map[string]string{"placement": `"claude:s134"`}},
		{"queue class bypass", AskArgs{Fleet: "csi", Op: "queue", AskID: askID, By: "c-001@sat", Class: "feature", Flag: "bypass", FlagMsg: askID},
			"", map[string]string{"class": `"feature"`, "flag": `"bypass"`, "flag_msg": `"` + askID + `"`}},
		{"queue bad class", AskArgs{Fleet: "csi", Op: "queue", AskID: askID, By: "c-001@sat", Class: "chore"}, "class must be", nil},
		{"bypass no msg", AskArgs{Fleet: "csi", Op: "queue", AskID: askID, By: "c-001@sat", Class: "feature", Flag: "bypass"}, "a bypass needs flag_msg", nil},
		{"class on ack", AskArgs{Fleet: "csi", Op: "ack", AskID: askID, By: "c-001@sat", Class: "bug"}, "go with queue only", nil},
	}
	for _, c := range cases {
		raw, err := Ask(context.Background(), cfg, c.in)
		if c.want != "" {
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Errorf("%s: %v, want %q", c.name, err, c.want)
			}
			continue
		}
		var got askEcho
		if err != nil || json.Unmarshal(raw, &got) != nil {
			t.Fatalf("%s: %s %v", c.name, raw, err)
		}
		if got.Op != c.in.Op {
			t.Errorf("%s: op %q", c.name, got.Op)
		}
		for k, v := range c.body {
			if string(got.Body[k]) != v {
				t.Errorf("%s: body %s = %s, want %s", c.name, k, got.Body[k], v)
			}
		}
	}
}
