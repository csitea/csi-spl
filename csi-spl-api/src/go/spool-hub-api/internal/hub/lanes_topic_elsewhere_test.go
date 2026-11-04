package hub_test

import (
	"context"
	"crypto/ed25519"
	"testing"

	"github.com/google/uuid"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Spec 153 section 3.20 (SPL-4797; owner HUM-10, t1 0c2d08a2 msg e7009f10:
// "there are still lanes created without a proper link to their
// discusions"): a lane put in the operator workspace whose topic is a topic
// of ANOTHER workspace lands under that topic, whether the brief named it as
// its full uuid (a version-5 one too: a customer workspace's topic ids can be) or as the
// 8 hex of its dispatch-<topic8> task. A version-5 uuid that is no topic of
// any workspace still stores nothing (C56b). Memory, and Postgres under
// SPOOL_TEST_PG_DSN. RED CONTROL (master 022055fe6): C90 came back "", the
// lane fell into "No discussion" (prd c-089@sat, 2026-11-04: its brief named
// customer-workspace topic ebb24c8d-b371-50bc-..., a version-5 uuid the hub took
// for a relay hash).

// C90, C91, C92.
func TestLanePutTopicOfAnotherWorkspace(t *testing.T) {
	r := newFleetTokensRig(t)
	ctx := context.Background()
	dv := newTenantID("dv")
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := r.e.st.CreateTenant(ctx, store.Tenant{ID: dv, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	v5 := uuid.NewSHA1(uuid.NameSpaceURL, []byte("customer topic "+uid.New())).String()
	lobbyTopic(t, r.e, dv, v5, "## Deck v7\n\nthe topic")
	put := func(id, topic string) string {
		t.Helper()
		got, err := lanePut(t, r.opBox, `{"agent_id":"`+id+`","agent_box":"`+r.opBox.id+`","state":"live","files":[],"topic":"`+topic+`"}`)
		if err != nil {
			t.Fatal(err)
		}
		return got.Topic
	}
	if got := put("c-561", v5); got != v5 {
		t.Errorf("C90 another workspace's version-5 topic uuid: %q, want %s", got, v5)
	}
	if got := put("c-562", v5[:8]); got != v5 {
		t.Errorf("C91 dispatch-<its topic8>, sent as its 8 hex: %q, want %s", got, v5)
	}
	if got := put("c-563", hashOf("dispatch-no-topic-"+uid.New())); got != "" {
		t.Errorf("C92 a version-5 uuid that is no topic anywhere: %q, want none", got)
	}
}
