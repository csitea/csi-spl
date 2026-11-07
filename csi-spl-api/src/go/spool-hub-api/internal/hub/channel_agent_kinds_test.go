package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// kindsEnv: a workspace with one channel owned by HUM-1, which is also the
// operator workspace, and (lease) the fleet's orch lease.
func kindsEnv(t *testing.T, lease bool) (*env, string, string) {
	t.Helper()
	op := newTenantID("op") // unique: under Postgres every test shares one database
	e := newEnv(t, func(o *hub.Options) {
		o.OperatorTenant = op
		o.ViewDoor = hub.ViewDoorOff
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
	})
	ctx := context.Background()
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(ctx, store.Tenant{ID: op, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	if lease {
		if _, err := e.st.CASFleetLease(ctx, op, "main", "orch", "c-001@box-a", "box-a", 0, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	human := "HUM-1@" + op
	now := time.Now()
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: op, ChannelID: "room", Name: "room", CreatedBy: human, CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, op, "room", []string{human}, human, now); err != nil {
		t.Fatal(err)
	}
	return e, op, human
}

// kindsOf reads the answer as "kind" or "kind online", in the hub's order.
func kindsOf(t *testing.T, e *env, tid, as string) string {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/channels/room/agent-kinds", as, nil)
	if code != http.StatusOK {
		t.Fatalf("GET agent-kinds: %d %v", code, out)
	}
	rows, _ := out["kinds"].([]any)
	got := make([]string, 0, len(rows))
	for _, r := range rows {
		m, _ := r.(map[string]any)
		s, _ := m["kind"].(string)
		if m["online"] == true {
			s += " online"
		}
		got = append(got, s)
	}
	return strings.Join(got, ",")
}

// SPL-5000: the list is store.AgentKinds minus the instance's kinds off and
// running pauses, the setting do_spl_lane_mix obeys; nothing else decides.
func TestChannelAgentKindsUsable(t *testing.T) {
	e, op, human := kindsEnv(t, true)
	ctx := context.Background()
	want := strings.Join(store.AgentKinds, ",")
	if got := kindsOf(t, e, op, human); got != want {
		t.Fatalf("every kind on: got %q want %q", got, want)
	}
	fl := e.st.(store.FleetLoadTarget)
	if _, err := fl.SetFleetLoad(ctx, op, store.FleetLoadPatch{KindsOffSet: true, AgentKindsOff: []string{"grok", "qwen"}}); err != nil {
		t.Fatal(err)
	}
	if got := kindsOf(t, e, op, human); got != "claude,agy,mistral" {
		t.Fatalf("grok, qwen off: %q", got)
	}
	if _, err := fl.SetFleetLoad(ctx, op, store.FleetLoadPatch{KindsOffSet: true, AgentKindsOff: []string{"grok"},
		Pauses: map[string]*store.KindPause{"qwen": {Until: time.Now().Add(time.Hour), Reason: "limit", Box: "box-a"}}, Now: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if got := kindsOf(t, e, op, human); got != "claude,agy,mistral" {
		t.Fatalf("qwen paused: %q", got)
	}
}

// online: an agent of the kind can be picked here; one already in the channel
// cannot, so its kind is offered as a new agent again.
func TestChannelAgentKindsOnline(t *testing.T) {
	e, op, human := kindsEnv(t, true)
	a := e.box(op, "box-a", "a-007")
	e.pin(op, a)
	if got := kindsOf(t, e, op, human); strings.Contains(got, "online") {
		t.Fatalf("no box connected: %q", got)
	}
	connectBox(t, e, op, a, "a-007")
	if got := kindsOf(t, e, op, human); !strings.Contains(got, "agy online") || strings.Contains(got, "claude online") {
		t.Fatalf("a-007 online: %q", got)
	}
	if err := e.st.InviteChannelAgent(context.Background(), op, "room", "box-a", "a-007", time.Now()); err != nil {
		t.Fatal(err)
	}
	if got := kindsOf(t, e, op, human); strings.Contains(got, "online") {
		t.Fatalf("a-007 already in the channel: %q", got)
	}
}

// POST leaves one role orch ask the holder's action can read, and a second
// click while it is open changes nothing.
func TestChannelAgentRequestAsksOrchestrator(t *testing.T) {
	e, op, human := kindsEnv(t, true)
	ctx := context.Background()
	body := map[string]any{"kind": "agy"}
	code, out := call(t, e, op, http.MethodPost, "/v1/channels/room/agent-kinds", human, body)
	if code != http.StatusAccepted || out["created"] != true {
		t.Fatalf("first ask: %d %v", code, out)
	}
	code, again := call(t, e, op, http.MethodPost, "/v1/channels/room/agent-kinds", human, body)
	if code != http.StatusAccepted || again["created"] != false || again["ask_id"] != out["ask_id"] {
		t.Fatalf("second ask: %d %v, first %v", code, again, out)
	}
	asks, err := e.st.ListFleetAsks(ctx, op, "main", "orch", false, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if len(asks) != 1 {
		t.Fatalf("asks: %d, want 1: %+v", len(asks), asks)
	}
	a := asks[0]
	if a.Kind != "task" || a.Topic != "channel-seat" || a.From != human ||
		!strings.HasPrefix(a.Summary, "channel seat: kind=agy tenant="+op+" channel=room ") ||
		!strings.Contains(a.Summary, "do_spl_channel_seat_place") {
		t.Fatalf("the ask: %+v", a)
	}
}

func TestChannelAgentRequestRefusals(t *testing.T) {
	e, op, human := kindsEnv(t, true)
	fl := e.st.(store.FleetLoadTarget)
	if _, err := fl.SetFleetLoad(context.Background(), op, store.FleetLoadPatch{KindsOffSet: true, AgentKindsOff: []string{"grok"}}); err != nil {
		t.Fatal(err)
	}
	post := func(env *env, tid, as, kind string) (int, string) {
		code, out := call(t, env, tid, http.MethodPost, "/v1/channels/room/agent-kinds", as, map[string]any{"kind": kind})
		tok, _ := out["error"].(string)
		return code, tok
	}
	if code, tok := post(e, op, human, "grok"); code != http.StatusConflict || tok != "kind_not_usable" {
		t.Fatalf("a kind that is off: %d %s", code, tok)
	}
	if code, tok := post(e, op, human, "nosuch"); code != http.StatusConflict || tok != "kind_not_usable" {
		t.Fatalf("an unknown kind: %d %s", code, tok)
	}
	other := "HUM-2@" + op
	if err := e.st.AddChannelHumans(context.Background(), op, "room", []string{other}, human, time.Now()); err != nil {
		t.Fatal(err)
	}
	if code, tok := post(e, op, other, "agy"); code != http.StatusForbidden || tok != "forbidden" {
		t.Fatalf("a member who may not invite: %d %s", code, tok)
	}
	bare, bareOp, owner := kindsEnv(t, false)
	if code, tok := post(bare, bareOp, owner, "agy"); code != http.StatusConflict || tok != "no_orchestrator" {
		t.Fatalf("no orch lease: %d %s", code, tok)
	}
}

// R7 W1: the ask spends the operator's fleet, so the owner of a channel in any
// other workspace is offered no kind and may not ask; nothing is stored.
func TestChannelAgentRequestOtherWorkspace(t *testing.T) {
	e, op, _ := kindsEnv(t, true)
	ctx := context.Background()
	other := newTenantID("other")
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(ctx, store.Tenant{ID: other, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	owner := "HUM-1@" + other
	now := time.Now()
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: other, ChannelID: "room", Name: "room", CreatedBy: owner, CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, other, "room", []string{owner}, owner, now); err != nil {
		t.Fatal(err)
	}
	if got := kindsOf(t, e, other, owner); got != "" {
		t.Fatalf("another workspace is offered kinds: %q", got)
	}
	code, out := call(t, e, other, http.MethodPost, "/v1/channels/room/agent-kinds", owner, map[string]any{"kind": "agy"})
	if tok, _ := out["error"].(string); code != http.StatusForbidden || tok != "operator_only" {
		t.Fatalf("another workspace asks: %d %v", code, out)
	}
	asks, err := e.st.ListFleetAsks(ctx, op, "main", "orch", false, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if len(asks) != 0 {
		t.Fatalf("asks in the operator fleet: %d, want 0: %+v", len(asks), asks)
	}
}

// R7 W2: the person sees what became of the ask: open while it waits, and a
// decline with its reason (a kind the launcher refused); a new ask replaces it.
func TestChannelAgentKindsShowsSeatAsks(t *testing.T) {
	e, op, human := kindsEnv(t, true)
	ctx := context.Background()
	asksOf := func() string {
		code, out := call(t, e, op, http.MethodGet, "/v1/channels/room/agent-kinds", human, nil)
		if code != http.StatusOK {
			t.Fatalf("GET agent-kinds: %d %v", code, out)
		}
		rows, _ := out["asks"].([]any)
		got := make([]string, 0, len(rows))
		for _, r := range rows {
			m, _ := r.(map[string]any)
			got = append(got, fmt.Sprintf("%v %v %v", m["kind"], m["state"], m["reason"]))
		}
		return strings.Join(got, ";")
	}
	if got := asksOf(); got != "" {
		t.Fatalf("no ask yet: %q", got)
	}
	code, out := call(t, e, op, http.MethodPost, "/v1/channels/room/agent-kinds", human, map[string]any{"kind": "agy"})
	if code != http.StatusAccepted {
		t.Fatalf("ask: %d %v", code, out)
	}
	if got := asksOf(); got != "agy open " {
		t.Fatalf("open ask: %q", got)
	}
	id, _ := out["ask_id"].(string)
	if _, err := e.st.UpdateFleetAsk(ctx, op, store.AskUpdate{Fleet: "main", AskID: id, Op: store.AskDecline, By: "c-001@box-a",
		Reason: "agy is installed on no box"}, "box-a", time.Now()); err != nil {
		t.Fatal(err)
	}
	if got := asksOf(); got != "agy declined agy is installed on no box" {
		t.Fatalf("declined ask: %q", got)
	}
	time.Sleep(10 * time.Millisecond)
	if code, out := call(t, e, op, http.MethodPost, "/v1/channels/room/agent-kinds", human, map[string]any{"kind": "agy"}); code != http.StatusAccepted || out["created"] != true {
		t.Fatalf("ask again: %d %v", code, out)
	}
	if got := asksOf(); got != "agy open " {
		t.Fatalf("the new ask replaces the decline: %q", got)
	}
}

// boxRow writes a box's BOX-0 lane-map load row in the main fleet, as written
// at "at"; scope is what spl_lane_box_report publishes.
func boxRow(t *testing.T, e *env, op, box, scope, state string, at time.Time) {
	t.Helper()
	l := store.FleetLane{Fleet: "main", AgentID: "BOX-0", AgentBox: box, Scope: scope, State: state}
	if _, err := e.st.PutFleetLane(context.Background(), op, l, box, at); err != nil {
		t.Fatal(err)
	}
}

// Holder ruling 15040649 W2: a kind is listed only when some live box measured
// its CLI (the cli= of its BOX-0 row). Live = state live, written within an
// hour (the lane map's LANE_BOX_ROW_MAX_S); a stale or done row does not count.
// No live row with a cli= at all: nothing filters (spawn-window.sh's rule).
func TestChannelAgentKindsInstalledOnABox(t *testing.T) {
	e, op, human := kindsEnv(t, true)
	all := strings.Join(store.AgentKinds, ",")
	boxRow(t, e, op, "box-old", "mem_kb=1 live=", "live", time.Now())
	if got := kindsOf(t, e, op, human); got != all {
		t.Fatalf("no box published cli=: want today's list %q, got %q", all, got)
	}
	boxRow(t, e, op, "box-a", "mem_kb=1 cli=claude,agy live=c-001", "live", time.Now())
	boxRow(t, e, op, "box-b", "mem_kb=1 cli=grok live=", "live", time.Now().Add(-2*time.Hour))
	boxRow(t, e, op, "box-c", "mem_kb=1 cli=mistral live=", "done", time.Now())
	if got := kindsOf(t, e, op, human); got != "claude,agy" {
		t.Fatalf("only box-a is live with cli=: got %q", got)
	}
	code, out := call(t, e, op, http.MethodPost, "/v1/channels/room/agent-kinds", human, map[string]any{"kind": "grok"})
	if tok, _ := out["error"].(string); code != http.StatusConflict || tok != "kind_not_usable" {
		t.Fatalf("POST a kind on no live box: %d %s, want 409 kind_not_usable", code, tok)
	}
	boxRow(t, e, op, "box-b", "mem_kb=1 cli=grok,qwen live=", "live", time.Now().Add(-50*time.Minute))
	if got := kindsOf(t, e, op, human); got != "claude,grok,agy,qwen" {
		t.Fatalf("box-b written 50 min ago is live: got %q", got)
	}
	boxRow(t, e, op, "box-a", "mem_kb=1 cli= live=", "live", time.Now())
	boxRow(t, e, op, "box-b", "mem_kb=1 cli= live=", "live", time.Now())
	if got := kindsOf(t, e, op, human); got != "" {
		t.Fatalf("every live box measured none: got %q", got)
	}
}
