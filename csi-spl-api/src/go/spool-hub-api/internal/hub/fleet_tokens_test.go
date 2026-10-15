package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

const fleetTokensPath = "/v1/operator/fleet-tokens"

// fleetTokensRig is a hub whose operator workspace is op, one other
// workspace, a box pinned in each, and a clock the test moves.
type fleetTokensRig struct {
	e                  *env
	op, other          string
	admin, dev, otherA string
	opBox, otherBox    *box
	offset             atomic.Int64
}

func newFleetTokensRig(t *testing.T) *fleetTokensRig {
	t.Helper()
	r := &fleetTokensRig{op: newTenantID("op"), other: newTenantID("ot")}
	r.e = rbacEnv(t, func(o *hub.Options) {
		o.OperatorTenant = r.op
		o.Now = func() time.Time { return time.Now().Add(time.Duration(r.offset.Load())) }
		o.HelloSkew = 24 * time.Hour // the surge test walks the hub's clock hours back
	})
	for _, id := range []string{r.op, r.other} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := r.e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	r.admin, r.dev, r.otherA = seat(t, r.e, r.op, rbac.Admin), seat(t, r.e, r.op, rbac.Developer), seat(t, r.e, r.other, rbac.Admin)
	// Box ids are unique per rig: the Postgres table is the instance's.
	r.opBox, r.otherBox = r.e.box(r.op, "sat-"+newTenantID("")), r.e.box(r.other, "box-"+newTenantID(""))
	r.e.pin(r.op, r.opBox)
	r.e.pin(r.other, r.otherBox)
	return r
}

type tokSample struct {
	agent, vendor, model string
	minute               time.Time
	in, out, cr, cw      int64
	unmetered            bool
}

func (s tokSample) json() string {
	model := "null"
	if s.model != "" {
		model = fmt.Sprintf("%q", s.model)
	}
	return fmt.Sprintf(`{"agent_id":%q,"vendor":%q,"model":%s,"minute":%q,"tokens_in":%d,"tokens_out":%d,"cache_read":%d,"cache_write":%d,"is_metered":%t}`,
		s.agent, s.vendor, model, s.minute.UTC().Format(time.RFC3339), s.in, s.out, s.cr, s.cw, !s.unmetered)
}

func pushBody(ss ...tokSample) json.RawMessage {
	parts := make([]string, len(ss))
	for i, s := range ss {
		parts[i] = s.json()
	}
	return json.RawMessage(`{"samples":[` + strings.Join(parts, ",") + `]}`)
}

func (r *fleetTokensRig) push(t *testing.T, b *box, ss ...tokSample) (wire.FleetTokensAckFrame, error) {
	t.Helper()
	raw, err := b.c.Lane(context.Background(), wire.FleetBurnPushOp, "", pushBody(ss...))
	var ack wire.FleetTokensAckFrame
	if err == nil {
		if err := json.Unmarshal(raw, &ack); err != nil {
			t.Fatalf("ack %s: %v", raw, err)
		}
	}
	return ack, err
}

// spec 140 T011: a box of the operator workspace pushes samples over its
// live connection and gets the ack with the rows written; the rows carry
// the session's box. RED CONTROL: malformed samples answer bad_samples and
// an unknown fleet_tokens op bad_frame on the same open connection (the next
// frame on it is still answered); a box of another workspace is refused.
func TestFleetTokensPushOp(t *testing.T) {
	r := newFleetTokensRig(t)
	ctx := context.Background()
	m := time.Now().UTC().Truncate(time.Minute).Add(-2 * time.Minute)

	ack, err := r.push(t, r.opBox, tokSample{agent: "c-001", vendor: "claude", model: "claude-opus-5-5", minute: m, in: 12450, out: 850, cr: 34000, cw: 4200},
		tokSample{agent: "a-204", vendor: "agy", minute: m, unmetered: true})
	if err != nil || ack.Type != "ack" || ack.LaneOp != wire.FleetBurnPushOp || ack.Inserted != 2 || ack.At == "" {
		t.Fatalf("push: %+v %v", ack, err)
	}
	rows, err := r.e.st.(store.FleetTokenStore).ListBuckets(ctx, m, "")
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, row := range rows {
		if row.BoxTag == r.opBox.id {
			n++
		}
	}
	if n != 2 {
		t.Fatalf("rows of box %s: %d of %+v", r.opBox.id, n, rows)
	}

	// One raw connection: a bad frame, then a good one, both answered.
	c, _ := r.e.helloRaw(r.op, r.opBox)
	frames := []struct {
		op, lane, want, token string
	}{
		{wire.FleetBurnPushOp, `{"samples":[{"agent_id":"c-001","vendor":"claude"}]}`, wire.TError, "bad_samples"},
		{wire.FleetBurnPushOp, `{"samples":[{"agent_id":"c-001","vendor":"gpt","minute":"` + m.Format(time.RFC3339) + `"}]}`, wire.TError, "bad_samples"},
		{wire.FleetBurnPushOp, `{"samples":[{"agent_id":"c-001","vendor":"claude","minute":"` + m.Add(time.Hour).Format(time.RFC3339) + `"}]}`, wire.TError, "bad_samples"},
		{"fleet_tokens_drop", `{}`, wire.TError, "bad_frame"},
		{wire.FleetBurnPushOp, string(pushBody(tokSample{agent: "c-002", vendor: "claude", minute: m, in: 5})), wire.TLane, ""},
	}
	for i, f := range frames {
		id := fmt.Sprintf("00000000-0000-4000-8000-%012d", i+1)
		if err := wsjson.Write(ctx, c, wire.Frame{Type: wire.TLane, MsgID: id, LaneOp: f.op, Lane: json.RawMessage(f.lane)}); err != nil {
			t.Fatalf("frame %d: the connection dropped: %v", i, err)
		}
		var got wire.Frame
		for {
			rctx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := wsjson.Read(rctx, c, &got)
			cancel()
			if err != nil {
				t.Fatalf("frame %d: no answer, the connection dropped: %v", i, err)
			}
			if got.MsgID == id {
				break
			}
		}
		if got.Type != f.want || got.Error != f.token {
			t.Fatalf("frame %d (%s): %+v, want %s %s", i, f.lane, got, f.want, f.token)
		}
		if f.want == wire.TError && got.Status != http.StatusBadRequest {
			t.Fatalf("frame %d: status %d, want 400", i, got.Status)
		}
	}
	c.CloseNow() //nolint:errcheck

	// A box of another workspace may not write the instance's rows.
	if _, err := r.push(t, r.otherBox, tokSample{agent: "c-9", vendor: "claude", minute: m, in: 1}); err == nil || !strings.Contains(err.Error(), "not_operator") {
		t.Fatalf("another workspace's box: %v, want not_operator", err)
	}
}

// spec 140 T012: the operator admin reads the fleet's burn: the sums of
// every lane, per vendor and per agent, agy unmetered with null sums.
// RED CONTROL: a developer of the operator workspace and the admin of
// another workspace get 403; an unknown window is a 400.
func TestFleetTokensReadRoute(t *testing.T) {
	r := newFleetTokensRig(t)
	now := time.Now().UTC()
	m1, m2 := now.Truncate(time.Minute).Add(-2*time.Minute), now.Truncate(time.Minute).Add(-1*time.Minute)
	if _, err := r.push(t, r.opBox,
		tokSample{agent: "c-801", vendor: "claude", model: "claude-opus-5-5", minute: m1, in: 1000, out: 500, cr: 20000, cw: 0},
		tokSample{agent: "c-801", vendor: "claude", model: "claude-opus-5-5", minute: m2, in: 2000, out: 500, cr: 0, cw: 1000},
		tokSample{agent: "m-802", vendor: "mistral", model: "codestral", minute: m2, in: 400, out: 100},
		tokSample{agent: "a-803", vendor: "agy", minute: m2, unmetered: true}); err != nil {
		t.Fatal(err)
	}
	code, body := call(t, r.e, r.op, http.MethodGet, fleetTokensPath+"?window=1h", r.admin, nil)
	if code != http.StatusOK {
		t.Fatalf("admin read: %d %v", code, body)
	}
	raw, _ := json.Marshal(body)
	var got wire.FleetTokenSummaryResponse
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	agents := map[string]wire.AgentTokenBurn{}
	for _, a := range got.ByAgent {
		if a.Box == r.opBox.id {
			agents[a.AgentID] = a
		}
	}
	c, mi, ag := agents["c-801"], agents["m-802"], agents["a-803"]
	if c.TodayTotalTokens == nil || *c.TodayTotalTokens != 25000 || *c.BurnRate1m != 3500 || *c.FreshTokensPerMin != (1500+3500)/5 || !c.IsMetered ||
		c.Model == nil || *c.Model != "claude-opus-5-5" {
		t.Fatalf("claude lane %+v", c)
	}
	if mi.TodayTotalTokens == nil || *mi.TodayTotalTokens != 500 || mi.Priced {
		t.Fatalf("mistral lane (no price row: tokens kept, priced false) %+v", mi)
	}
	if ag.IsMetered || ag.TodayTotalTokens != nil || ag.BurnRateTokensPerMin != nil || ag.TodayCost != nil || ag.LastActive != m2.Format(time.RFC3339) {
		t.Fatalf("agy lane %+v, want unmetered with null sums", ag)
	}
	// The fleet sums hold at least this rig's lanes (Postgres is shared).
	if got.Summary.TodayTotalTokens < 25500 || got.Summary.ActiveAgents < 3 || got.Summary.UnmeteredAgents < 1 || len(got.ByVendor) != 5 || len(got.History) != 61 {
		t.Fatalf("summary %+v, %d vendors, %d history rows", got.Summary, len(got.ByVendor), len(got.History))
	}
	for _, v := range got.ByVendor {
		if v.Vendor == "agy" && (v.Status != "unmetered" || v.TodayTotalTokens != nil) {
			t.Fatalf("agy vendor %+v", v)
		}
	}
	if code, body := call(t, r.e, r.op, http.MethodGet, fleetTokensPath+"?vendor=mistral&window=today", r.admin, nil); code != http.StatusOK {
		t.Fatalf("vendor filter: %d %v", code, body)
	} else if as, _ := body["by_agent"].([]any); len(as) == 0 {
		t.Fatalf("vendor filter lost mistral: %v", body)
	} else {
		for _, a := range as {
			if a.(map[string]any)["vendor"] != "mistral" {
				t.Fatalf("vendor filter: %v", a)
			}
		}
	}
	for _, bad := range []string{"?window=7d", "?vendor=gpt"} {
		if code, _ := call(t, r.e, r.op, http.MethodGet, fleetTokensPath+bad, r.admin, nil); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", bad, code)
		}
	}
	for name, who := range map[string][2]string{"operator developer": {r.op, r.dev}, "other workspace admin": {r.other, r.otherA}, "anonymous": {r.op, ""}} {
		if code, body := call(t, r.e, who[0], http.MethodGet, fleetTokensPath, who[1], nil); code != http.StatusForbidden || body["permission"] != "operator.workspaces" {
			t.Errorf("%s: %d %v, want 403 operator.workspaces", name, code, body)
		}
	}
}

// spec 140 T014: a lane above 60k fresh tokens/min for 3 consecutive minutes
// posts one alert into #fleet-alerts; a lane still surging inside the
// 30-minute cool-off posts none; after the cool-off, or once the lane fell
// below 30k and surged again, it posts again. RED CONTROL: 65k/min for only
// 2 minutes, then a drop, posts nothing, and a lane below 60k posts nothing.
// Without #fleet-alerts the push is still acked and no channel is created.
func TestFleetTokenSurgeAlert(t *testing.T) {
	r := newFleetTokensRig(t)
	ctx := context.Background()
	if err := r.e.st.CreateChannel(ctx, store.Channel{TenantID: r.op, ChannelID: hub.FleetAlertsChannel, Name: hub.FleetAlertsChannel,
		CreatedBy: r.admin, CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	// Minutes from a 30-minute slot start 3 h back, so the slots the alert
	// ids fall into are fixed.
	base := time.Now().UTC().Truncate(30 * time.Minute).Add(-3 * time.Hour)
	min := func(n int) time.Time { return base.Add(time.Duration(n) * time.Minute) }
	r.offset.Store(int64(-3 * time.Hour)) // the hub's clock walks with the minutes
	clockAt := func(n int) { r.offset.Store(int64(min(n).Add(30 * time.Second).Sub(time.Now()))) }
	box := r.opBox.id
	surge := func(agent string, n int, fresh int64) {
		t.Helper()
		clockAt(n)
		if _, err := r.push(t, r.opBox, tokSample{agent: agent, vendor: "claude", model: "claude-opus-5-5", minute: min(n), in: fresh, cr: 500000}); err != nil {
			t.Fatal(err)
		}
	}
	posted := func(agent string, end int) bool {
		ok, err := r.e.st.HasMessage(ctx, r.op, hub.FleetSurgeIDOf(box, agent, min(end)))
		if err != nil {
			t.Fatal(err)
		}
		return ok
	}

	// RED CONTROL: 2 minutes at 65k, then a drop; and 59k for 3 minutes.
	surge("c-two", 20, 65000)
	surge("c-two", 21, 65000)
	surge("c-two", 22, 20000)
	surge("c-low", 20, 59000)
	surge("c-low", 21, 59000)
	surge("c-low", 22, 59000)
	if posted("c-two", 22) || posted("c-two", 21) || posted("c-low", 22) {
		t.Fatal("RED CONTROL: an alert without 3 minutes above 60k")
	}

	// c-hot: 3 minutes above 60k (minutes 25..27) alerts once.
	surge("c-hot", 25, 64200)
	surge("c-hot", 26, 71500)
	if posted("c-hot", 26) {
		t.Fatal("alert after 2 minutes")
	}
	surge("c-hot", 27, 68900)
	if !posted("c-hot", 27) {
		t.Fatal("no alert after 3 consecutive minutes above 60k")
	}
	// Still surging at minutes 28..33, inside the cool-off: minute 30 starts
	// the next slot, so a post there would carry a new id.
	for n := 28; n <= 33; n++ {
		surge("c-hot", n, 70000)
		if n >= 30 && posted("c-hot", n) { // 28, 29: the same slot, the same id as 27's
			t.Fatalf("alert at minute %d inside the 30-minute cool-off", n)
		}
	}
	// After the cool-off (alert at 27, now 58), the surge alerts again.
	for n := 56; n <= 58; n++ {
		surge("c-hot", n, 70000)
	}
	if !posted("c-hot", 58) {
		t.Fatal("no alert after the cool-off")
	}

	// c-rearm: alert, fall below 30k, surge again inside 30 min: alerts.
	for n := 60; n <= 62; n++ {
		surge("c-rearm", n, 65000)
	}
	surge("c-rearm", 63, 10000)
	for n := 64; n <= 66; n++ {
		surge("c-rearm", n, 65000)
	}
	if !posted("c-rearm", 62) || !posted("c-rearm", 66) {
		t.Fatalf("rearm: first %v, second %v, want both", posted("c-rearm", 62), posted("c-rearm", 66))
	}

	// No #fleet-alerts: the push is acked, nothing is posted, no channel made.
	r2 := newFleetTokensRig(t)
	r2.offset.Store(r.offset.Load())
	for n := 70; n <= 72; n++ {
		r2.offset.Store(int64(min(n).Add(30 * time.Second).Sub(time.Now())))
		if ack, err := r2.push(t, r2.opBox, tokSample{agent: "c-hot", vendor: "claude", minute: min(n), in: 90000}); err != nil || ack.Inserted != 1 {
			t.Fatalf("push without the channel: %+v %v", ack, err)
		}
	}
	if ok, _ := r2.e.st.HasMessage(ctx, r2.op, hub.FleetSurgeIDOf(r2.opBox.id, "c-hot", min(72))); ok {
		t.Fatal("an alert was stored without #fleet-alerts")
	}
	if known, _ := r2.e.st.ChannelKnown(ctx, r2.op, hub.FleetAlertsChannel); known {
		t.Fatal("the alert path created #fleet-alerts")
	}
}
