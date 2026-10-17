package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// hubNotes is the HUB-0 notes stored in task, as envelope bytes.
func hubNotes(t *testing.T, r privacyRig, task string) [][]byte {
	t.Helper()
	envs, err := r.e.st.TaskEnvelopes(context.Background(), r.tid, task)
	if err != nil {
		t.Fatal(err)
	}
	var out [][]byte
	for _, e := range envs {
		if bytes.Contains(e, []byte(`"from":"`+hub.PublicNoticeFrom+`"`)) {
			out = append(out, e)
		}
	}
	return out
}

// waitNotes polls hubNotes until it holds want notes or 2 s pass: the hub
// posts the note after the sender's ack.
func waitNotes(t *testing.T, r privacyRig, task string, want int) [][]byte {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		n := hubNotes(t, r, task)
		if len(n) >= want || time.Now().After(deadline) {
			return n
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// SPL-2419 (owner t1 170c444e): an @mention of a person who is not in the
// channel gets one automatic hub note in the same topic; a member, a default
// channel and a resend get none.
func TestMentionNonMemberNote(t *testing.T) {
	_, key, _ := ed25519.GenerateKey(nil) // the hub signs its notes as box-wui
	e := followEnv(t, func(o *hub.Options) { o.WUIKey = key })
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "live-proof",
		Name: "live-proof", CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "live-proof", []string{"HUM-1"}, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	r := privacyRig{e: e, tid: tid, priv: uuidV4()}
	putRow(t, e, tid, r.priv, "live-proof", "HUM-1", "CLE-07", "the private channel post", now)
	member := dialMember(t, r.e, r.tid, "HUM-1", "HUM-1")
	send := func(task, channel, msgID, body string) {
		t.Helper()
		f := map[string]any{"type": "send", "task_id": task, "msg_id": msgID, "body": body}
		if channel != "" {
			f["channel"] = channel
		}
		wsjson.Write(ctx, member, f) //nolint:errcheck
		if a := readType(t, member, "ack"); a["type"] != "ack" {
			t.Fatalf("send %q: %v", body, a)
		}
	}

	// One socket's frames run in order and each note is posted before the
	// next frame is read, so once the LAST send's note is stored every
	// earlier send has had its chance: the "none" cases cannot pass by racing.
	id := uuidV4()
	two := "@HUM-2 and @HUM-3, see this; @HUM-1 too; again @HUM-2"
	send(r.priv, "live-proof", uuidV4(), "note to self @HUM-1") // CONTROL: a member: none
	send(r.priv, "live-proof", id, two)                         // two outsiders: one note
	send(r.priv, "live-proof", id, two)                         // a resend: none
	send(lobby, "", uuidV4(), "@HUM-2 in the lobby")            // a default channel: none
	send(r.priv, "live-proof", uuidV4(), "and @GST-4")          // the last: one note
	notes := waitNotes(t, r, r.priv, 2)
	if len(notes) != 2 {
		t.Fatalf("want 2 notes (two outsiders, then GST-4), got %d: %s", len(notes), notes)
	}
	all := bytes.Join(notes, []byte("\n"))
	for _, want := range []string{ // any order: the notes share one second
		`"body":"@HUM-2, @HUM-3 do not belong to this channel and cannot see these messages."`,
		`"body":"@GST-4 does not belong to this channel and cannot see these messages."`,
	} {
		if !bytes.Contains(all, []byte(want)) {
			t.Errorf("no note with %s in %s", want, all)
		}
	}
	if n := hubNotes(t, r, lobby); len(n) != 0 {
		t.Errorf("a default channel mention got a note: %s", n)
	}
}
