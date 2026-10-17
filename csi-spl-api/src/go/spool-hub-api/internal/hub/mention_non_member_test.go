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
// channel and a resend get none. SPL-2426 (msg a3fe13e3): the note names each
// person by the name on file, else the name they sign in with, never the id.
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
	admit := func(sub, email, name string) string {
		t.Helper()
		h := e.st.(store.Humans)
		if err := h.PutInvite(ctx, store.Invite{TenantID: tid, Email: email, Role: store.RoleDefault,
			InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
		id, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: sub, Email: email, Name: name}, tid, store.AdmitPolicy{}, now)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	admit("author-sub", "author@example.com", "")                          // a fresh store's HUM-1, the sender
	named := admit("named-sub", "named@example.com", "FirstName LastName") // a name on file
	nameless := admit("nameless-sub", "nameless@example.com", "")          // only a sign-in address
	if named == "HUM-1" || nameless == "HUM-1" {
		t.Fatalf("an outsider is the sender HUM-1: %s %s", named, nameless)
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
	two := "@" + named + " and @" + nameless + ", see this; @HUM-1 too; again @" + named
	send(r.priv, "live-proof", uuidV4(), "note to self @HUM-1") // CONTROL: a member: none
	send(r.priv, "live-proof", id, two)                         // two outsiders: one note
	send(r.priv, "live-proof", id, two)                         // a resend: none
	send(lobby, "", uuidV4(), "@"+named+" in the lobby")        // a default channel: none
	send(r.priv, "live-proof", uuidV4(), "and @GST-4")          // the last: one note
	notes := waitNotes(t, r, r.priv, 2)
	if len(notes) != 2 {
		t.Fatalf("want 2 notes (two outsiders, then GST-4), got %d: %s", len(notes), notes)
	}
	all := bytes.Join(notes, []byte("\n"))
	for _, want := range []string{ // any order: the notes share one second
		`"body":"FirstName LastName and nameless do not belong to this channel and cannot see these messages."`,
		`"body":"a person with no name on file does not belong to this channel and cannot see these messages."`,
	} {
		if !bytes.Contains(all, []byte(want)) {
			t.Errorf("no note with %s in %s", want, all)
		}
	}
	for _, id := range []string{named, nameless, "GST-4"} { // never the bare id
		if bytes.Contains(all, []byte(id)) {
			t.Errorf("a note names %s by id: %s", id, all)
		}
	}
	if n := hubNotes(t, r, lobby); len(n) != 0 {
		t.Errorf("a default channel mention got a note: %s", n)
	}
}
