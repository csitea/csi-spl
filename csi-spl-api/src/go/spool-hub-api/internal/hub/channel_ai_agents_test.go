package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-1684 (rdb 0189): the per-channel "AI agents" switch. Off, a channel
// post reaches no member agent and no fallback responder; a DM and an
// "@agent ..." dispatch still do; a workspace that never set the default is
// unchanged. Memory store, and Postgres with SPOOL_TEST_PG_DSN.

// aiRig is the fallback rig (responder CLE-001 on box-desk) plus channel
// drivers, whose member agent GRK-36 is online on box-b.
func aiRig(t *testing.T) (*fallbackRig, *box) {
	t.Helper()
	r := newFallbackRig(t, true, "drivers", "quiet")
	ctx := context.Background()
	if err := r.e.st.(store.Fallbacks).SetTenantResponders(ctx, r.tid, []string{"CLE-001"}); err != nil {
		t.Fatal(err)
	}
	b := r.e.box(r.tid, "box-b", "GRK-36")
	r.e.pin(r.tid, b)
	sb, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeWait(sb) })
	if code, out := call(t, r.e, r.tid, http.MethodPost, "/v1/channels/drivers/agents", r.human,
		map[string]string{"id": "GRK-36", "box": "box-b"}); code != http.StatusCreated {
		t.Fatalf("invite: %d %v", code, out)
	}
	return r, b
}

func aiSwitch(t *testing.T, r *fallbackRig, who string, on any) (int, map[string]any) {
	t.Helper()
	return call(t, r.e, r.tid, http.MethodPut, "/v1/channels/drivers/ai-agents", who, map[string]any{"on": on})
}

func membersOf(t *testing.T, r *fallbackRig) map[string]any {
	t.Helper()
	code, out := call(t, r.e, r.tid, http.MethodGet, "/v1/channels/drivers/members", r.human, nil)
	if code != http.StatusOK {
		t.Fatalf("GET members: %d %v", code, out)
	}
	return out
}

func TestChannelAIAgentsOffStopsTheChannelLegOnly(t *testing.T) {
	r, b := aiRig(t)
	ctx := context.Background()
	has := func(id string) bool { return strings.Contains(strings.Join(inboxIDs(t, b, "GRK-36"), ","), id) }

	// A workspace without the setting: as before, and no new field on the wire.
	m1 := "a1000000-0000-4000-8000-000000000001"
	threadFrame(t, r.ws, m1, "b1000000-0000-4000-8000-000000000001", "drivers", 1, "a car is late")
	eventually(t, "GRK-36 got the post (default on)", func() bool { return has(m1) })
	if _, ok := membersOf(t, r)["ai_agents_off"]; ok {
		t.Fatalf("ai_agents_off on the wire of a workspace without the setting: %v", membersOf(t, r))
	}

	// The workspace default goes off: every channel without its own value.
	if _, err := r.e.st.(store.TenantKV).SetTenantSettings(ctx, r.tid,
		store.TenantSettingsPatch{Set: map[string]any{store.ChannelAIAgentsKey: false}}); err != nil {
		t.Fatal(err)
	}
	if membersOf(t, r)["ai_agents_off"] != true {
		t.Fatalf("members answer of an off channel: %v", membersOf(t, r))
	}
	m2 := "a1000000-0000-4000-8000-000000000002"
	threadFrame(t, r.ws, m2, "b1000000-0000-4000-8000-000000000002", "drivers", 1, "another one is late")
	// The direct legs: a DM and an @agent dispatch in the off channel.
	m3, m4 := "a1000000-0000-4000-8000-000000000003", "a1000000-0000-4000-8000-000000000004"
	dmFrame(t, r.ws, m3, "b1000000-0000-4000-8000-000000000003", "GRK-36", "a direct question")
	threadFrame(t, r.ws, m4, "b1000000-0000-4000-8000-000000000004", "drivers", 1, "@GRK-36 please check car 7")
	eventually(t, "the DM and the dispatch reached GRK-36", func() bool { return has(m3) && has(m4) })
	watch(300*time.Millisecond, func() bool { return has(m2) })
	if has(m2) {
		t.Fatalf("an off channel's post reached its member agent: %v", inboxIDs(t, b, "GRK-36"))
	}
	// #quiet has no agent: on, its post would go to the responder.
	threadFrame(t, r.ws, "a1000000-0000-4000-8000-000000000006", "b1000000-0000-4000-8000-000000000006", "quiet", 1, "anyone?")
	watch(300*time.Millisecond, func() bool { return len(inbox(t, r.desk, "CLE-001")) != 0 })
	if ids := inboxIDs(t, r.desk, "CLE-001"); len(ids) != 0 || len(r.pokes()) != 0 {
		t.Fatalf("an off channel's post fell back: inbox %v pokes %v", ids, r.pokes())
	}

	// The channel's own switch wins over the workspace default.
	if code, out := aiSwitch(t, r, r.human, true); code != http.StatusOK || out["ai_agents_off"] != false {
		t.Fatalf("switch on: %d %v", code, out)
	}
	m5 := "a1000000-0000-4000-8000-000000000005"
	threadFrame(t, r.ws, m5, "b1000000-0000-4000-8000-000000000005", "drivers", 1, "on again")
	eventually(t, "GRK-36 got the post (channel on)", func() bool { return has(m5) })
	if code, out := aiSwitch(t, r, r.human, nil); code != http.StatusOK || out["ai_agents_off"] != true {
		t.Fatalf("back to the default: %d %v", code, out)
	}
}

// Who may switch: the channel's creator (or a workspace admin); another
// member is refused, and the body is checked.
func TestChannelAIAgentsWho(t *testing.T) {
	r, _ := aiRig(t)
	other := "HUM-google-sub-2@" + r.tid
	if err := r.e.st.AddChannelHumans(context.Background(), r.tid, "drivers", []string{other}, r.human, time.Now()); err != nil {
		t.Fatal(err)
	}
	if code, out := aiSwitch(t, r, other, false); code != http.StatusForbidden {
		t.Fatalf("a member who is not the owner switched it: %d %v", code, out)
	}
	if code, out := call(t, r.e, r.tid, http.MethodPut, "/v1/channels/drivers/ai-agents", r.human,
		map[string]any{"on": "no"}); code != http.StatusBadRequest {
		t.Fatalf("bad body: %d %v", code, out)
	}
	if code, out := aiSwitch(t, r, r.human, false); code != http.StatusOK || out["ai_agents_off"] != true {
		t.Fatalf("owner switch off: %d %v", code, out)
	}
	if membersOf(t, r)["ai_agents_off"] != true {
		t.Fatalf("members answer: %v", membersOf(t, r))
	}
}
