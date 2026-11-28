package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// agentInvitesDropOf is lane_op agent_invites_drop through c (a one-shot
// role=cli session signed by the box's own key, as `spool agent-invites-drop`
// sends it). box "" leaves the box out of the frame.
func agentInvitesDropOf(t *testing.T, c *hubclient.Client, agent, box string) ([]string, error) {
	t.Helper()
	in := map[string]string{"agent": agent}
	if box != "" {
		in["box"] = box
	}
	row, _ := json.Marshal(in)
	raw, err := c.Lane(context.Background(), "agent_invites_drop", "", row)
	if err != nil {
		return nil, err
	}
	var out struct {
		Agent    string    `json:"agent"`
		Box      string    `json:"box"`
		Channels *[]string `json:"channels"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || out.Channels == nil || out.Agent != agent {
		t.Fatalf("agent_invites_drop answer %s: %v", raw, err)
	}
	return *out.Channels, nil
}

// SPL-6714 (spec 061 3.6): a retired id kept every channel seat a member had
// given it (channel_subscriptions origin 'invite'), and its next holder
// inherited them, because the only remove door needs a member session. A box
// now drops its OWN id's seats with its own key. Counting: c-873@box-a leaves
// #ops and #lobby; c-874@box-a, c-873@box-a2 and workspace B's c-873@box-b
// keep theirs. CONTROLS: a box that names another box is refused and that
// box's seat stays; an announce does not bring the dropped seats back; a
// member's new invite does (the reused id starts empty, not barred).
func TestBoxAgentInvitesDrop(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	ta, _ := e.tenant()
	tb, _ := e.tenant()
	a := e.box(ta, "box-a", "c-873", "c-874")
	a2 := e.box(ta, "box-a2", "c-873")
	b := e.box(tb, "box-b", "c-873")
	e.pin(ta, a)
	e.pin(ta, a2)
	e.pin(tb, b)
	for _, tid := range []string{ta, tb} {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "ops", Name: "ops", CreatedBy: "wui", CreatedAt: now}); err != nil {
			t.Fatal(err)
		}
	}
	for _, s := range []struct{ tid, ch, box, id string }{
		{ta, "ops", "box-a", "c-873"}, {ta, "lobby", "box-a", "c-873"}, {ta, "ops", "box-a", "c-874"},
		{ta, "ops", "box-a2", "c-873"}, {tb, "ops", "box-b", "c-873"},
	} {
		if err := e.st.InviteChannelAgent(ctx, s.tid, s.ch, s.box, s.id, now); err != nil {
			t.Fatal(err)
		}
	}
	members := func(tid, ch string) string {
		t.Helper()
		m, err := e.st.ChannelMembers(ctx, tid, ch)
		if err != nil {
			t.Fatal(err)
		}
		return fmt.Sprint(m)
	}

	// CONTROL: box-a names box-a2 in the frame: refused, box-a2's seat stays.
	if _, err := agentInvitesDropOf(t, a.c, "c-873", "box-a2"); err == nil || !strings.Contains(err.Error(), "forbidden") {
		t.Fatalf("CONTROL: box-a drops c-873@box-a2: err=%v, want forbidden", err)
	}
	if got, want := members(ta, "ops"), "map[box-a:[c-873 c-874] box-a2:[c-873]]"; got != want {
		t.Fatalf("CONTROL: #ops after a refused drop = %s, want %s", got, want)
	}

	got, err := agentInvitesDropOf(t, a.c, "c-873", "box-a")
	if err != nil || fmt.Sprint(got) != "[lobby ops]" {
		t.Fatalf("box-a drops c-873: channels=%v err=%v, want [lobby ops]", got, err)
	}
	if got, want := members(ta, "ops"), "map[box-a:[c-874] box-a2:[c-873]]"; got != want {
		t.Fatalf("#ops after the drop = %s, want %s", got, want)
	}
	if got := members(ta, "lobby"); got != "map[]" {
		t.Fatalf("#lobby after the drop = %s, want map[]", got)
	}
	if got, want := members(tb, "ops"), "map[box-b:[c-873]]"; got != want {
		t.Fatalf("CONTROL: workspace B's #ops = %s, want %s (the drop is the asking workspace's only)", got, want)
	}

	// Again, with no box in the frame (the hello's box): nothing left to drop.
	if got, err := agentInvitesDropOf(t, a.c, "c-873", ""); err != nil || len(got) != 0 {
		t.Fatalf("second drop: channels=%v err=%v, want []", got, err)
	}
	// CONTROL: an announce of the reused id does not seat it again.
	if err := e.st.SetSubscriptions(ctx, ta, "box-a", []string{"c-873", "c-874"}, []string{"ops", "lobby"}, now); err != nil {
		t.Fatal(err)
	}
	if got, want := members(ta, "ops"), "map[box-a:[c-874] box-a2:[c-873]]"; got != want {
		t.Fatalf("CONTROL: #ops after an announce = %s, want %s", got, want)
	}
	// A member's new invite seats the reused id again.
	if err := e.st.InviteChannelAgent(ctx, ta, "ops", "box-a", "c-873", now); err != nil {
		t.Fatal(err)
	}
	if got, want := members(ta, "ops"), "map[box-a:[c-873 c-874] box-a2:[c-873]]"; got != want {
		t.Fatalf("#ops after a new invite = %s, want %s", got, want)
	}

	// Not an agent id, or a body that is not {agent}: bad_frame.
	if _, err := agentInvitesDropOf(t, a.c, "HUM-1", ""); err == nil || !strings.Contains(err.Error(), "bad_frame") {
		t.Fatalf("a human id: err=%v, want bad_frame", err)
	}
	if _, err := a.c.Lane(ctx, "agent_invites_drop", "", json.RawMessage(`[1]`)); err == nil || !strings.Contains(err.Error(), "bad_frame") {
		t.Fatalf("bad body: err=%v, want bad_frame", err)
	}
}
