package hub_test

// SPL-72 — DELETE /v1/channels/{channel}: the member who created a channel
// deletes it; nobody else may, whatever their role; a default channel never.
// Every refusal is paired with the creator's delete that succeeds.

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

func TestDeleteChannelCreatorOnly(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	creator := seat(t, e, tid, "developer")
	boss := seat(t, e, tid, "biz_owner")     // IN the channel, did not create it
	outsider := seat(t, e, tid, "developer") // a tenant member, not in the channel

	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels", creator,
		map[string]string{"channel": "doomed", "name": "Doomed"}); code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels/doomed/members", creator,
		map[string]string{"human_id": boss}); code != http.StatusCreated {
		t.Fatalf("add member: %d %v", code, out)
	}

	// A non-member learns nothing: the 404 a missing channel gets.
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/channels/doomed", outsider, nil); code != http.StatusNotFound {
		t.Errorf("outsider DELETE: %d %v, want 404", code, out)
	}
	// A member who did not create it - a biz_owner included - is refused.
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/channels/doomed", boss, nil); code != http.StatusForbidden {
		t.Errorf("biz_owner (not the creator) DELETE: %d %v, want 403", code, out)
	}
	// A default channel is never deleted, not even by the biz owner.
	for _, d := range store.DefaultChannels {
		if code, out := call(t, e, tid, http.MethodDelete, "/v1/channels/"+d, boss, nil); code != http.StatusConflict {
			t.Errorf("DELETE #%s: %d %v, want 409", d, code, out)
		}
	}
	if got := listedChannels(t, e, tid, boss); !got["doomed"] {
		t.Fatalf("a refused DELETE removed the channel: %v", got)
	}

	// CONTROL: the creator may.
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/channels/doomed", creator, nil); code != http.StatusNoContent {
		t.Fatalf("creator DELETE: %d %v", code, out)
	}
	for _, who := range []string{creator, boss} {
		if got := listedChannels(t, e, tid, who); got["doomed"] {
			t.Errorf("%s still lists a deleted channel: %v", who, got)
		}
		if code, _ := call(t, e, tid, http.MethodGet, "/v1/channels/doomed/members", who, nil); code != http.StatusNotFound {
			t.Errorf("%s GET members of a deleted channel: %d, want 404", who, code)
		}
	}
	if code, _ := call(t, e, tid, http.MethodDelete, "/v1/channels/doomed", creator, nil); code != http.StatusNotFound {
		t.Errorf("second DELETE: %d, want 404", code)
	}
	// The slug stays taken while the channel can still be restored.
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/channels", creator,
		map[string]string{"channel": "doomed"}); code != http.StatusConflict {
		t.Errorf("re-create a deleted slug: %d, want 409", code)
	}

	// The way back: the restore brings its members with it.
	if err := e.st.RestoreChannel(context.Background(), tid, "doomed"); err != nil {
		t.Fatal(err)
	}
	if got := listedChannels(t, e, tid, boss); !got["doomed"] {
		t.Errorf("restored channel not listed for its member: %v", got)
	}
}

// Every member's open sidebar learns of the delete; a non-member hears
// nothing (the frame names a channel it must not know exists), and nobody
// can post into the deleted channel.
func TestDeleteChannelLive(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "doomed",
		Name: "doomed", CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "doomed", []string{"HUM-1", "HUM-2"}, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	task := uuidV4()
	putRow(t, e, tid, task, "doomed", "HUM-1", "CLE-07", "before the delete", now)

	member := dialMember(t, e, tid, "HUM-2", "HUM-2")
	outsider := dialMember(t, e, tid, "HUM-3", "HUM-3")
	// CONTROL: the member can post there before the delete.
	wsjson.Write(ctx, member, map[string]any{"type": "send", "task_id": task, //nolint:errcheck
		"channel": "doomed", "body": "still here"})
	if f := readType(t, member, "ack"); f["type"] != "ack" || f["error"] != nil {
		t.Fatalf("CONTROL: member post before delete: %v", f)
	}

	if code, out := call(t, e, tid, http.MethodDelete, "/v1/channels/doomed", "HUM-1", nil); code != http.StatusNoContent {
		t.Fatalf("creator DELETE: %d %v", code, out)
	}
	if f := readType(t, member, "channel_deleted"); f["channel"] != "doomed" {
		t.Errorf("member frame: %v", f)
	}
	quiet(t, outsider, "a non-member heard about a channel it is not in")

	wsjson.Write(ctx, member, map[string]any{"type": "send", "task_id": task, //nolint:errcheck
		"channel": "doomed", "body": "after the delete"})
	if f := readType(t, member, "ack"); f["error"] != "unknown_channel" {
		t.Errorf("post into a deleted channel: %v, want unknown_channel", f)
	}
	if n, _ := readTopic(t, e, tid, task, "HUM-2"); n == http.StatusOK {
		t.Errorf("the deleted channel's topic is still readable")
	}
}
