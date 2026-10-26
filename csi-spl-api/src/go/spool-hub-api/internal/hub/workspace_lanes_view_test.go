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
	// C28's short id case moved to TestWorkspaceLanesShortID (v1.2: it resolves now).

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
	if got := laneKeys(op); !slices.Equal(got, []string{"c-501", "c-502", "c-503", "c-504", "c-506", "c-507"}) {
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

// Spec 153 v1.2 section 3.7 (SPL-3514; owner HUM-10, a customer workspace topic f88d6ee4, msg
// 694f9ede): a lane works for the workspace whose topic its put names. A put
// by an operator box with an 8-hex short id that starts no operator topic
// stores the one topic of another workspace that it starts. C28b, C31-C35.
// RED CONTROL (master a066b182e): C28b and C31 fail, the short id is
// stored "" and w1's view is empty.
func TestWorkspaceLanesShortID(t *testing.T) {
	r := newWSLanesRig(t)
	opBoxID := r.opBox.id
	put := func(b *box, agent, topic string) string {
		t.Helper()
		got, err := lanePut(t, b, `{"agent_id":"`+agent+`","agent_box":"`+b.id+`","topic":"`+topic+`","scope":"scope of `+agent+`","state":"live"}`)
		if err != nil {
			t.Fatalf("put %s %s: %v", agent, topic, err)
		}
		return got.Topic
	}
	// C28b: the short id of a w1 topic is stored as that topic's full uuid.
	if got := put(r.opBox, "c-511", r.t1[:8]); got != r.t1 {
		t.Errorf("C28b short id %s stored %q, want w1's topic %s", r.t1[:8], got, r.t1)
	}
	// C32: a prefix that starts a w1 AND a w2 topic is stored "".
	twin := uid.New()[:8]
	lobbyTopic(t, r.e, r.w1, twin+"-0000-4000-8000-000000000001", "## W1 twin\n\none")
	lobbyTopic(t, r.e, r.w2, twin+"-0000-4000-8000-000000000002", "## W2 twin\n\ntwo")
	if got := put(r.opBox, "c-512", twin); got != "" {
		t.Errorf("C32 a prefix of two workspaces' topics stored %q, want \"\"", got)
	}
	// C33: the operator's own topic wins over a w1 topic with the same prefix.
	opFirst := uid.New()[:8]
	lobbyTopic(t, r.e, r.op, opFirst+"-0000-4000-8000-000000000001", "## Operator twin\n\nop")
	lobbyTopic(t, r.e, r.w1, opFirst+"-0000-4000-8000-000000000002", "## W1 op twin\n\nw1")
	if got := put(r.opBox, "c-513", opFirst); got != opFirst+"-0000-4000-8000-000000000001" {
		t.Errorf("C33 operator and w1 prefix stored %q, want the operator's topic", got)
	}
	// C34: a box of another workspace never resolves outside its own.
	if got := put(r.otherBox, "c-514", r.t2[:8]); got != "" {
		t.Errorf("C34 a customer box's short id of a w2 topic stored %q, want \"\"", got)
	}

	// C31: w1's admin sees c-511 with w1's title, w2's admin does not, and
	// neither sees C32-C34's lanes.
	v, raw := wsLanes(t, r, r.w1, r.w1Admin, http.StatusOK)
	if got := laneKeys(v); !slices.Equal(got, []string{"c-511"}) {
		t.Errorf("C31 w1 admin lanes %v, want [c-511]", got)
	}
	for _, l := range v.Lanes {
		if l.TopicID != r.t1 || l.TopicTitle != "W1 build" || l.Scope != "scope of c-511" || l.AgentBox != "" {
			t.Errorf("C31 row: %+v", l)
		}
	}
	for _, leak := range []string{"W2 twin", "W1 op twin", "Operator twin", r.t2, opBoxID} {
		if strings.Contains(raw, leak) {
			t.Errorf("C31: %q in w1's answer: %s", leak, raw)
		}
	}
	if v, raw := wsLanes(t, r, r.w2, r.w2Admin, http.StatusOK); len(v.Lanes) != 0 || strings.Contains(raw, "W1 build") {
		t.Errorf("C31 twin w2 admin: %s, want no lane", raw)
	}

	// C35: the operator view lists c-511 with no w1 title or text.
	op := getLanes(t, r.fleetTokensRig)
	if !slices.Contains(laneKeys(op), "c-511") {
		t.Errorf("C35 operator lanes %v, want c-511", laneKeys(op))
	}
	opRaw, _ := json.Marshal(op)
	for _, leak := range []string{"W1 build", "row B6", "W2 secret", "confidential", "W1 twin", "W2 twin", "W1 op twin"} {
		if strings.Contains(string(opRaw), leak) {
			t.Errorf("C35: workspace text %q in the operator view: %s", leak, opRaw)
		}
	}
}
