package hub_test

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 140 section 3.10 (SPL-3565; owner HUM-10, t1 f3ed0eed, msgs 1bb1f74b
// and 96d69790): a lane's token burn is booked to the workspace it works for
// (its fleet_lanes topic, spec 153 3.7), every role of that workspace reads
// it on GET /v1/tenant/costs, and only the operator workspace's admin reads
// every workspace's. Memory, and Postgres under SPOOL_TEST_PG_DSN.

// wsCostBody is the part of GET /v1/tenant/costs these tests read.
type wsCostBody struct {
	Scope string `json:"scope"`
	Parts []struct {
		Source          string  `json:"source"`
		ProjectOrVendor string  `json:"project_or_vendor"`
		Units           float64 `json:"units"`
		ListValueMicros *int64  `json:"list_value_micros"`
		USDMicros       int64   `json:"usd_micros"`
	} `json:"parts"`
	Workspaces []struct {
		Workspace       string `json:"workspace"`
		Vendor          string `json:"vendor"`
		Tokens          int64  `json:"tokens"`
		ListValueMicros int64  `json:"list_value_micros"`
	} `json:"workspaces"`
}

func costsOf(t *testing.T, r *wsLanesRig, tid, hum string) wsCostBody {
	t.Helper()
	code, body := call(t, r.e, tid, http.MethodGet, "/v1/tenant/costs", hum, nil)
	raw, _ := json.Marshal(body)
	if code != http.StatusOK {
		t.Fatalf("costs in %s as %s: %d %s", tid, hum, code, raw)
	}
	var b wsCostBody
	if err := json.Unmarshal(raw, &b); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), `"workspaces"`) != (b.Scope == "estate") {
		t.Errorf("costs in %s as %s: workspaces listed outside the estate (or missing in it): %s", tid, hum, raw)
	}
	return b
}

// tokenParts is the answer's fleet_tokens parts (this route's burn), by vendor.
func tokenParts(b wsCostBody) map[string][2]int64 {
	out := map[string][2]int64{}
	for _, p := range b.Parts {
		if p.Source == "fleet_tokens" {
			list := int64(-1)
			if p.ListValueMicros != nil {
				list = *p.ListValueMicros
			}
			if p.USDMicros != 0 {
				t := out[p.ProjectOrVendor]
				t[1] = -2 // a paid amount: never (spec 123 Q-4)
				out[p.ProjectOrVendor] = t
				continue
			}
			out[p.ProjectOrVendor] = [2]int64{int64(p.Units), list}
		}
	}
	return out
}

// W1 the push stamps each lane's workspace; W2 every role of w1 reads w1's
// burn only; W3 w2 reads its own; W4 the operator workspace's non-admins read
// its own burn, never another workspace's and never the estate; W5 its admin
// reads the estate with every workspace listed; W6 a box cannot send the
// workspace. RED CONTROLS (n=1 each, recorded in the commit): without the
// stamp W1 and W2 fail (w1 reads no part); with the estate for every
// costs.read holder W4 fails (the biz_owner reads the estate); with the burn
// unfiltered W2 fails (w1 reads w2's 2000).
func TestWorkspaceTokenCosts(t *testing.T) {
	r := newWSLanesRig(t)
	now := r.sameDay()
	m := now.Truncate(time.Minute).Add(-2 * time.Minute)
	box := r.opBox.id
	_, onMemory := r.e.st.(*store.Memory)
	// A price row of this test's own model: 3 USD in, 15 USD out per million.
	model := "claude-wscost-" + newTenantID("")
	for kind, micros := range map[string]int64{store.UsageKindIn: 3_000_000, store.UsageKindOut: 15_000_000} {
		putModelPrice(t, r.e.st, store.ModelPrice{Provider: "anthropic", Model: model, Kind: kind, MicrosPerMillion: micros,
			Currency: "USD", ValidFrom: now.Add(-24 * time.Hour)})
	}
	laneAt(t, r.fleetTokensRig, "c-611", box, r.t1, "", now)      // works for w1
	laneAt(t, r.fleetTokensRig, "c-612", box, r.t2, "", now)      // works for w2
	laneAt(t, r.fleetTokensRig, "c-613", box, r.opTopic, "", now) // the operator's own topic
	laneAt(t, r.fleetTokensRig, "c-614", box, "", "", now)        // no topic: the operator's own
	if _, err := r.push(t, r.opBox,
		tokSample{agent: "c-611", vendor: "claude", model: model, minute: m, in: 1000, out: 100},
		tokSample{agent: "c-612", vendor: "claude", model: model, minute: m, in: 2000},
		tokSample{agent: "c-613", vendor: "claude", model: model, minute: m, in: 4000},
		tokSample{agent: "c-614", vendor: "claude", model: model, minute: m, in: 8000},
		tokSample{agent: "m-615", vendor: "mistral", minute: m, in: 16000}); err != nil { // no lane row
		t.Fatal(err)
	}

	// W1
	rows, err := r.e.st.(store.FleetTokenStore).ListBuckets(context.Background(), m, "")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"c-611": r.w1, "c-612": r.w2, "c-613": "", "c-614": "", "m-615": ""}
	cost := map[string]float64{}
	for _, b := range rows {
		if w, mine := want[b.AgentID]; mine && b.BoxTag == box {
			if b.WorkTenant != w {
				t.Errorf("W1 %s booked to %q, want %q", b.AgentID, b.WorkTenant, w)
			}
			cost[b.AgentID] = b.CostMicros
			delete(want, b.AgentID)
		}
	}
	if len(want) != 0 {
		t.Fatalf("W1 rows missing: %v", want)
	}
	if cost["c-611"] != 4500 {
		t.Fatalf("CONTROL: c-611's minute costs %v micros, want 4500 (1000 in at 3, 100 out at 15 per million)", cost)
	}

	// W2: every member role of w1, admin and owner included.
	for _, role := range rbac.RoleIDs {
		b := costsOf(t, r, r.w1, seat(t, r.e, r.w1, role))
		got := tokenParts(b)
		if b.Scope != "workspace" || len(got) != 1 || got["claude"] != [2]int64{1100, int64(math.Round(cost["c-611"]))} {
			t.Errorf("W2 %s of w1: scope %s, token parts %v, want claude 1100 tokens at %v", role, b.Scope, got, cost["c-611"])
		}
	}
	// W3
	if got := tokenParts(costsOf(t, r, r.w2, r.w2Admin)); len(got) != 1 || got["claude"][0] != 2000 {
		t.Errorf("W3 w2 token parts %v, want claude 2000", got)
	}

	// W4: a customer seated as regular_user and a biz_owner of the operator workspace.
	for _, role := range []string{rbac.RegularUser, rbac.BizOwner, rbac.Developer} {
		b := costsOf(t, r, r.op, seat(t, r.e, r.op, role))
		got := tokenParts(b)
		if b.Scope != "workspace" || got["claude"][0] < 12000 || got["mistral"][0] < 16000 {
			t.Errorf("W4 %s of the operator workspace: scope %s, token parts %v, want its own (claude >= 12000, mistral >= 16000)", role, b.Scope, got)
		}
		if onMemory && (got["claude"][0] != 12000 || got["mistral"][0] != 16000) {
			t.Errorf("W4 %s of the operator workspace reads %v: another workspace's burn is in it", role, got)
		}
	}

	// W5
	b := costsOf(t, r, r.op, r.admin)
	if b.Scope != "estate" || len(tokenParts(b)) != 0 {
		t.Fatalf("W5 the operator admin: scope %s, token parts %v, want the estate with its burn in workspaces only", b.Scope, tokenParts(b))
	}
	seen := map[string]int64{}
	for _, w := range b.Workspaces {
		if w.Workspace == r.w1 || w.Workspace == r.w2 || (w.Workspace == r.op && w.Vendor == "claude") {
			seen[w.Workspace] = w.Tokens
		}
	}
	if seen[r.w1] != 1100 || seen[r.w2] != 2000 || seen[r.op] < 12000 {
		t.Errorf("W5 the operator admin's workspaces %v, want w1 1100, w2 2000, op >= 12000", seen)
	}

	// W6
	raw := `{"samples":[{"agent_id":"c-616","vendor":"claude","model":null,"minute":"` + m.Format(time.RFC3339) +
		`","tokens_in":1,"tokens_out":0,"cache_read":0,"cache_write":0,"is_metered":true,"work_tenant":"` + r.w1 + `"}]}`
	if _, err := r.opBox.c.Lane(context.Background(), wire.FleetBurnPushOp, "", json.RawMessage(raw)); err == nil || !strings.Contains(err.Error(), "bad_samples") {
		t.Errorf("W6 a box sent work_tenant: %v, want bad_samples", err)
	}
}
