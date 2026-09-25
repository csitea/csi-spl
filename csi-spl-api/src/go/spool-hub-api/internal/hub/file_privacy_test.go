package hub_test

// rdb 0030 — the read door on an ATTACHMENT. 0028 closed the message, and
// left GET /v1/files/{file_id} scoped to the TENANT and nothing else: a
// signed-in member who knew a file_id could fetch a file out of a channel
// they were never in, or out of another member's DM.
//
// Every refusal here is paired with the same fetch by someone who may do it.
// Without that, deleting the guard in rest.go would leave a suite that still
// passes, because "nobody can read anything" satisfies every assertion about
// what must not be readable.

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// putFileRow stores one message that CARRIES fileID, and the blob behind it.
func putFileRow(t *testing.T, e *env, tenant, task, channel, from, to, fileID string, at time.Time) {
	t.Helper()
	files := `[{"mode":"blob","kind":"file","file_id":"` + fileID + `","name":"secret.pdf","sha256":"` + fileID + `"}]`
	inner := `{"v":1,"msg_id":"` + uuidV4() + `","task_id":"` + task + `","from":"` + from +
		`","to":"` + to + `","kind":"note","body":"see the file","files":` + files + `}`
	raw := `{"from_box":"box-wui","to_box":"box-wui","channel":"` + channel + `","msg":` + inner + `,"sig":""}`
	m := store.Message{TenantID: tenant, MsgID: uuidV4(), TaskID: task, Channel: channel, TS: at,
		FromBox: "box-wui", FromID: from, ToBox: "box-wui", ToID: to, Kind: "note", Body: "see the file",
		Files: []byte(files), Msg: []byte(inner), Env: []byte(raw),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if _, err := e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	key, err := blob.Key(tenant, fileID)
	if err != nil {
		t.Fatal(err)
	}
	if err := (blob.Dir{Root: e.blobs}).Put(context.Background(), key, []byte("the bytes")); err != nil {
		t.Fatal(err)
	}
}

// getFile is GET /v1/files/{id} as member `as`; returns the status.
func getFile(t *testing.T, e *env, tid, fileID, as string) int {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, e.url(tid)+"/v1/files/"+fileID, nil)
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("GET file: %v", err)
	}
	defer resp.Body.Close()
	return resp.StatusCode
}

func TestFilePrivacy(t *testing.T) {
	e := followEnv(t)
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
	chFile := strings.Repeat("a", 64)
	dmFile := strings.Repeat("b", 64)
	pubFile := strings.Repeat("c", 64)
	putFileRow(t, e, tid, uuidV4(), "live-proof", "HUM-1", "CLE-07", chFile, now)
	putFileRow(t, e, tid, uuidV4(), "", "HUM-1", "CLE-07", dmFile, now)
	putFileRow(t, e, tid, uuidV4(), "lobby", "HUM-1", "CLE-07", pubFile, now)

	for _, tc := range []struct {
		what, file, as string
		want           int
	}{
		// CONTROLS: the member who may read the message gets its file.
		{"HUM-1 gets its channel's file", chFile, "HUM-1", http.StatusOK},
		{"HUM-1 gets its own DM's file", dmFile, "HUM-1", http.StatusOK},
		{"HUM-1 gets the #lobby file", pubFile, "HUM-1", http.StatusOK},
		// #lobby is tenant-wide, so its attachment is too.
		{"HUM-2 gets the #lobby file", pubFile, "HUM-2", http.StatusOK},
		// The defect.
		{"HUM-2 gets a file from a channel it is not in", chFile, "HUM-2", http.StatusNotFound},
		{"HUM-2 gets a file from another member's DM", dmFile, "HUM-2", http.StatusNotFound},
	} {
		if got := getFile(t, e, tid, tc.file, tc.as); got != tc.want {
			t.Errorf("%s: got %d, want %d", tc.what, got, tc.want)
		}
	}
}

// A FRESH blob no message references is an upload whose message has not been
// sent: the door lets it through, or a box could not fetch back what it just
// uploaded. The CONTROL is that attaching it to a private message closes it.
// Past hub.FileUploadGrace it is closed anyway (file_retention_test.go).
func TestUnattachedFileStaysReadableUntilItIsSent(t *testing.T) {
	e := followEnv(t)
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
	id := strings.Repeat("d", 64)
	key, err := blob.Key(tid, id)
	if err != nil {
		t.Fatal(err)
	}
	if err := (blob.Dir{Root: e.blobs}).Put(ctx, key, []byte("not sent yet")); err != nil {
		t.Fatal(err)
	}
	if got := getFile(t, e, tid, id, "HUM-2"); got != http.StatusOK {
		t.Errorf("an unattached upload: got %d, want 200", got)
	}
	// CONTROL: the moment a message carries it, the message's door governs.
	putFileRow(t, e, tid, uuidV4(), "live-proof", "HUM-1", "CLE-07", id, now)
	if got := getFile(t, e, tid, id, "HUM-2"); got != http.StatusNotFound {
		t.Errorf("after it is sent into a private channel: got %d, want 404", got)
	}
	if got := getFile(t, e, tid, id, "HUM-1"); got != http.StatusOK { // CONTROL
		t.Errorf("the channel's own member: got %d, want 200", got)
	}
}
