package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
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
