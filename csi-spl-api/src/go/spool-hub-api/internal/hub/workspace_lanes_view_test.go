package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Spec 153 v1.1 row B6 (SPL-3229; owner O1 = B): a workspace's owners and
// admins read the operator's active lanes on their own topics,
// GET /v1/view/lanes. Memory, and Postgres under SPOOL_TEST_PG_DSN (RLS and
// the tenant scope). Each case names its spec 4 row. RED CONTROL (master):
// the route did not exist, every call answered 404.

const workspaceLanesPath = "/v1/view/lanes"

// wsLanesRig is the operator workspace (newFleetTokensRig) plus two customer
// workspaces w1 and w2, their seats and one #lobby topic each.
type wsLanesRig struct {
	*fleetTokensRig
	w1, w2                                 string
	w1Admin, w1Owner, w1DevAdmin, w1Dev    string
	w2Admin                                string
	t1, t2, opTopic, privTopic, privMember string
}

func newWSLanesRig(t *testing.T) *wsLanesRig {
	t.Helper()
	r := &wsLanesRig{fleetTokensRig: newFleetTokensRig(t), w1: newTenantID("w1"), w2: newTenantID("w2")}
	for _, id := range []string{r.w1, r.w2} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := r.e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	r.w1Admin, r.w1Owner = seat(t, r.e, r.w1, rbac.Admin), seat(t, r.e, r.w1, rbac.BizOwner)
	r.w1DevAdmin, r.w1Dev = seat(t, r.e, r.w1, rbac.Developer), seat(t, r.e, r.w1, rbac.Developer)
	setRoles(t, r.e, r.w1, r.w1DevAdmin, rbac.Developer, rbac.Admin) // C25b: admin as a second role
	r.w2Admin = seat(t, r.e, r.w2, rbac.Admin)
	r.t1, r.t2, r.opTopic, r.privTopic = uid.New(), uid.New(), uid.New(), uid.New()
	lobbyTopic(t, r.e, r.w1, r.t1, "## W1 build\n\nrow B6")
	lobbyTopic(t, r.e, r.w2, r.t2, "## W2 secret plan\n\nconfidential")
	lobbyTopic(t, r.e, r.op, r.opTopic, "## Operator only\n\ninternal")

	// C30: a w1 channel whose one member is a second w1 admin, privMember.
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	r.privMember = seat(t, r.e, r.w1, rbac.Admin)
	if err := r.e.st.CreateChannel(ctx, store.Channel{TenantID: r.w1, ChannelID: "b6-private",
		Name: "b6-private", CreatedBy: r.privMember, CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := r.e.st.AddChannelHumans(ctx, r.w1, "b6-private", []string{r.privMember}, r.privMember, now); err != nil {
		t.Fatal(err)
	}
	putRow(t, r.e, r.w1, r.privTopic, "b6-private", r.privMember, "CLE-07", "the private channel post", now)
	return r
}

// wsLanes is GET /v1/view/lanes in tid as hum, decoded; code is checked.
func wsLanes(t *testing.T, r *wsLanesRig, tid, hum string, want int) (lanesView, string) {
	t.Helper()
	code, body := call(t, r.e, tid, http.MethodGet, workspaceLanesPath, hum, nil)
	raw, _ := json.Marshal(body)
	if code != want {
		t.Errorf("GET %s in %s as %s: %d %s, want %d", workspaceLanesPath, tid, hum, code, raw, want)
		return lanesView{}, string(raw)
	}
	var v lanesView
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	return v, string(raw)
}

// C25, C25b, C26, C27, C28, C29, C30 on one fleet.
func TestWorkspaceLanesView(t *testing.T) {
	r := newWSLanesRig(t)
	now := time.Now()
	box := r.opBox.id
	// w1 issues: 1 links t1, 2 links the default discussion only.
	for _, title := range []string{"one", "two"} {
		disc := r.t1
		if title == "two" {
			disc = store.IssueDiscussionDefault(r.w1)
		}
		if code, out := call(t, r.e, r.w1, http.MethodPost, "/v1/issues", r.w1Admin, map[string]any{"title": title, "discussions": []string{disc}}); code != http.StatusCreated {
			t.Fatalf("w1 issue %s: %d %v", title, code, out)
		}
	}
	if code, out := call(t, r.e, r.w2, http.MethodPost, "/v1/issues", r.w2Admin, map[string]any{"title": "theirs", "discussions": []string{r.t2}}); code != http.StatusCreated {
		t.Fatalf("w2 issue: %d %v", code, out)
	}

	laneAt(t, r.fleetTokensRig, "c-501", box, r.t1, "SPL-2", now.Add(-1*time.Minute))   // C25, C29
	laneAt(t, r.fleetTokensRig, "c-502", box, r.t2, "SPL-7", now.Add(-2*time.Minute))   // C25 twin
	laneAt(t, r.fleetTokensRig, "c-503", box, "", "SPL-8", now.Add(-3*time.Minute))     // C28: no topic
	laneAt(t, r.fleetTokensRig, "c-504", box, r.opTopic, "", now.Add(-4*time.Minute))   // C28: operator topic
	laneAt(t, r.fleetTokensRig, "c-506", box, r.t1, "", now.Add(-6*time.Minute))        // C28 twin: full uuid
	laneAt(t, r.fleetTokensRig, "c-507", box, r.privTopic, "", now.Add(-7*time.Minute)) // C30
	laneAt(t, r.fleetTokensRig, "c-508", box, r.t1, "", now.Add(-3*time.Hour))          // not active: 3.2's rule
	// C28: a short id of a w1 topic resolves among the operator's topics only.
	if got, err := lanePut(t, r.opBox, `{"agent_id":"c-505","agent_box":"`+box+`","topic":"`+r.t1[:8]+`","state":"live"}`); err != nil || got.Topic != "" {
		t.Fatalf("C28 short id put: %+v %v, want stored with an empty topic", got, err)
	}

	// C25: w1's admin sees the w1 lanes only, with no box name.
	v, raw := wsLanes(t, r, r.w1, r.w1Admin, http.StatusOK)
	if got := laneKeys(v); !slices.Equal(got, []string{"c-501", "c-506"}) {
		t.Errorf("C25/C28/C30 w1 admin lanes %v, want [c-501 c-506]", got)
	}
	for _, l := range v.Lanes {
		if l.AgentBox != "" || l.TopicID != r.t1 || l.TopicTitle != "W1 build" || l.Scope != "scope of "+l.AgentID {
			t.Errorf("C25 row: %+v", l)
		}
	}
	// C29: issues = w1's issue 1 only; the operator's own key SPL-2 absent.
	if got := issuesOf(t, v, "c-501"); len(got) != 1 || !strings.HasSuffix(strings.Fields(got[0])[0], "-1") || strings.Fields(got[0])[1] == "" {
		t.Errorf("C29 issues %v, want w1's key for issue 1 with its status only", got)
	}
	for _, leak := range []string{"SPL-2", "SPL-7", "SPL-8", "W2 secret", "confidential", "Operator only", r.t2, r.opTopic, r.privTopic, box, "theirs"} {
		if strings.Contains(raw, leak) {
			t.Errorf("C28-C30: %q in w1's answer: %s", leak, raw)
		}
	}

	// C25 twin: w2's admin sees the w2 lane only.
	if v, raw := wsLanes(t, r, r.w2, r.w2Admin, http.StatusOK); !slices.Equal(laneKeys(v), []string{"c-502"}) || strings.Contains(raw, "W1 build") || strings.Contains(raw, "SPL-7") {
		t.Errorf("C25 twin w2 admin: %s, want c-502 only, no own key", raw)
	}

	// C25b: the owner, and a developer whose second role is admin, as C25.
	for _, hum := range []string{r.w1Owner, r.w1DevAdmin} {
		if v, _ := wsLanes(t, r, r.w1, hum, http.StatusOK); !slices.Equal(laneKeys(v), []string{"c-501", "c-506"}) {
			t.Errorf("C25b %s: %v, want [c-501 c-506]", hum, laneKeys(v))
		}
	}

	// C26: a plain developer and no session get 403 forbidden.
	for _, hum := range []string{r.w1Dev, ""} {
		code, body := call(t, r.e, r.w1, http.MethodGet, workspaceLanesPath, hum, nil)
		if code != http.StatusForbidden || body["error"] != "forbidden" {
			t.Errorf("C26 %q: %d %v, want 403 forbidden", hum, code, body)
		}
	}

	// C30 twin: the admin who may open the private topic sees its lane.
	if v, _ := wsLanes(t, r, r.w1, r.privMember, http.StatusOK); !slices.Equal(laneKeys(v), []string{"c-501", "c-506", "c-507"}) {
		t.Errorf("C30 twin: %v, want [c-501 c-506 c-507]", laneKeys(v))
	}

	// C27: the operator view is unchanged: every active lane, the box, the own keys.
	op := getLanes(t, r.fleetTokensRig)
	if got := laneKeys(op); !slices.Equal(got, []string{"c-505", "c-501", "c-502", "c-503", "c-504", "c-506", "c-507"}) {
		t.Errorf("C27 operator lanes %v", got)
	}
	for _, l := range op.Lanes {
		if l.AgentBox != box {
			t.Errorf("C27 operator row without its box: %+v", l)
		}
	}
	if got := issuesOf(t, op, "c-501"); !slices.ContainsFunc(got, func(k string) bool { return strings.HasPrefix(k, "SPL-2") }) {
		t.Errorf("C29 twin: the operator view of c-501 lists %v, want SPL-2", got)
	}
	if got := issuesOf(t, op, "c-502"); !slices.ContainsFunc(got, func(k string) bool { return strings.HasPrefix(k, "SPL-7") }) {
		t.Errorf("C27: the operator view of c-502 lists %v, want its own SPL-7", got)
	}

	// The operator workspace's own admin on this route: its own topics only.
	if v, _ := wsLanes(t, r, r.op, r.admin, http.StatusOK); !slices.Equal(laneKeys(v), []string{"c-504"}) {
		t.Errorf("operator admin on %s: %v, want [c-504]", workspaceLanesPath, laneKeys(v))
	}
	if code, _ := call(t, r.e, r.w1, http.MethodGet, workspaceLanesPath+"?fleet=Main", r.w1Admin, nil); code != http.StatusBadRequest {
		t.Errorf("fleet=Main: %d, want 400", code)
	}
}
