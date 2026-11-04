package hub_test

import (
	"context"
	"crypto/ed25519"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Spec 153 section 3.8 (SPL-4705; owner HUM-10, prd t1 0ea86216 msg
// aa56f0b5: "we must have the workspace attribute in the lanes listing"): a
// lane or a queued ask whose topic is the task id dispatch-<topic8> names the
// workspace holding that topic, in any non-archived workspace; a prefix two
// workspaces share names none, never a guess. Memory, and Postgres under
// SPOOL_TEST_PG_DSN. RED CONTROL (master 3da4fa390): C58 fails, the live
// lane on dispatch-<csitea topic8> came back in the operator workspace.

// C58, C59.
func TestLanesWorkspaceOfDispatchTopic(t *testing.T) {
	r := newFleetTokensRig(t)
	ctx, now, box := context.Background(), time.Now(), r.opBox.id
	cs, other := newTenantID("cs"), newTenantID("other")
	r.ws[cs], r.ws[other] = true, true
	for _, id := range []string{cs, other} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := r.e.st.CreateTenant(ctx, store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	name := "Csitea"
	if err := r.e.st.(store.TenantSettings).SetTenantConfig(ctx, cs, store.TenantConfigPatch{DisplayName: &name}); err != nil {
		t.Fatal(err)
	}
	csTopic := uid.New()
	lobbyTopic(t, r.e, cs, csTopic, "## Csitea build\n\nrow 50")
	twin := uid.New()[:8] // C59: one prefix, a topic in each workspace
	lobbyTopic(t, r.e, cs, twin+uid.New()[8:], "## Twin one\n\nrow 51")
	lobbyTopic(t, r.e, other, twin+uid.New()[8:], "## Twin two\n\nrow 51")

	laneAt(t, r, "c-531", box, "dispatch-"+csTopic[:8], "", now.Add(-time.Minute))
	laneAt(t, r, "c-532", box, "dispatch-"+twin, "", now.Add(-2*time.Minute))
	ws := &wsLanesRig{fleetTokensRig: r}
	queueAsk(t, ws, "dispatch-"+csTopic[:8], "QUEUE csitea lane", "claude:c002-cs", 10*time.Minute)
	queueAsk(t, ws, "dispatch-"+twin, "QUEUE twin lane", "claude:c002-twin", 5*time.Minute)

	v := getLanes(t, r)
	if len(v.Lanes) != 4 {
		t.Fatalf("rows %v, want two lanes and two asks", scopes(v))
	}
	row := map[string]int{}
	for i, l := range v.Lanes {
		row[l.AgentID+"|"+l.Scope] = i
	}
	at := func(k string) int {
		i, ok := row[k]
		if !ok {
			t.Fatalf("no row %q in %v", k, scopes(v))
		}
		return i
	}
	for _, k := range []string{"c-531|scope of c-531", "|QUEUE csitea lane"} { // C58
		l := v.Lanes[at(k)]
		if l.Workspace != cs || l.WorkspaceName != "Csitea" || l.TopicID != csTopic {
			t.Errorf("C58 %s: workspace %q %q topic %q, want %s Csitea %s", k, l.Workspace, l.WorkspaceName, l.TopicID, cs, csTopic)
		}
		if l.TopicTitle != "" {
			t.Errorf("C58 %s: another workspace's title %q shown to the operator", k, l.TopicTitle)
		}
	}
	for _, k := range []string{"c-532|scope of c-532", "|QUEUE twin lane"} { // C59
		if l := v.Lanes[at(k)]; l.Workspace != r.op || l.TopicID != "" || l.TopicTitle != "" {
			t.Errorf("C59 %s: workspace %q topic %q title %q, want the operator's, no topic", k, l.Workspace, l.TopicID, l.TopicTitle)
		}
	}
}
