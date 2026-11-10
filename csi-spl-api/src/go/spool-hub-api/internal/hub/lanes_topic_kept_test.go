package hub_test

import (
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// SPL-5080: a lane whose discussion is a version-5 topic of the operator's
// OWN workspace is opened by its 8 hex, and the hub stores the full uuid; the
// close (lane-map.sh done, the reaper) resends that stored uuid, which the
// hub took for a relay hash of no topic and refused: "names no single
// discussion (rdb 0264: a lane needs one)" (prd 2026-11-08, c-810, c-842,
// c-812; the live map held 8 rows with a v5 topic, 2026-11-10). A put whose
// topic is the one its row already stores keeps it; the rule still holds for
// a new row (C131) and for a topic the row does not hold (C132). Memory, and
// Postgres under SPOOL_TEST_PG_DSN. RED CONTROL (master 4522b6b1e): C129 and
// C130 were refused with "names no single discussion".

// C129, C130, C131, C132.
func TestLanePutKeepsItsOwnV5Topic(t *testing.T) {
	r := newFleetTokensRig(t)
	v5 := uuid.NewSHA1(uuid.NameSpaceURL, []byte("operator topic "+uid.New())).String()
	lobbyTopic(t, r.e, r.op, v5, "## Lane close\n\nthe topic")
	try := func(id, state, topic string) (string, error) {
		t.Helper()
		got, err := lanePut(t, r.opBox, `{"agent_id":"`+id+`","agent_box":"`+r.opBox.id+`","state":"`+state+`","files":[],"issue_key":"SPL-1","topic":"`+topic+`"}`)
		return got.Topic, err
	}
	if got, err := try("c-571", "live", v5[:8]); err != nil || got != v5 {
		t.Fatalf("open by its 8 hex: %q %v, want %s", got, err, v5)
	}
	if got, err := try("c-571", "live", v5); err != nil || got != v5 {
		t.Errorf("C129 a live re-put with the stored full uuid: %q %v, want %s", got, err, v5)
	}
	if got, err := try("c-571", "done", v5); err != nil || got != v5 {
		t.Errorf("C130 the close resends the stored full uuid: %q %v, want %s", got, err, v5)
	}
	if got, err := try("c-572", "live", v5); err == nil || !strings.Contains(err.Error(), "names no single discussion") {
		t.Errorf("C131 a new row naming a version-5 uuid: stored %q (%v), want refused as before", got, err)
	}
	other := hashOf("dispatch-no-topic-" + uid.New())
	if got, err := try("c-571", "done", other); err == nil || !strings.Contains(err.Error(), "names no single discussion") {
		t.Errorf("C132 a close naming a version-5 uuid its row does not hold: stored %q (%v), want refused", got, err)
	}
}
