package hub_test

// SPL-1560 (owner HUM-10 t1 d74ecae5): the X on an attachment removes it from
// the system. DELETE /v1/attachments/{file_id} takes the file off every
// message the caller may change that carries it, and deletes the blob once no
// message carries it. The uploader (the author of the carrying message) and a
// workspace admin may; nobody else.
//
// Each refusal is paired with the same call by someone who may make it, so a
// handler that refused everyone would fail this file too.

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// putAttachRow stores one unsigned box-wui note by `from` in `channel` that
// carries every id in fileIDs, writes each blob, and returns its msg_id.
func putAttachRow(t *testing.T, e *env, tenant, channel, from string, fileIDs ...string) string {
	t.Helper()
	ctx := context.Background()
	at := time.Now().UTC().Truncate(time.Microsecond)
	id, task := uuidV4(), uuidV4()
	if channel == "lobby" {
		task = lobby // a lobby note, so a socket subscribed to the lobby sees it
	}
	var refs []string
	for _, f := range fileIDs {
		refs = append(refs, `{"bytes":9,"file_id":"`+f+`","kind":"file","mode":"blob","name":"`+f[:4]+`.png","sha256":"`+f+`"}`)
		key, err := blob.Key(tenant, f)
		if err != nil {
			t.Fatal(err)
		}
		if err := (blob.Dir{Root: e.blobs}).Put(ctx, key, []byte("the bytes")); err != nil {
			t.Fatal(err)
		}
	}
	files := "[" + strings.Join(refs, ",") + "]"
	inner := `{"body":"see the file","files":` + files + `,"from":"` + from + `","kind":"note","msg_id":"` + id +
		`","task_id":"` + task + `","to":"ALL-0","ts":"` + at.Format(time.RFC3339) + `","v":1}`
	raw := `{"channel":"` + channel + `","from_box":"box-wui","msg":` + inner + `,"sig":"","to_box":"box-wui"}`
	m := store.Message{TenantID: tenant, MsgID: id, TaskID: task, Channel: channel, TS: at,
		FromBox: "box-wui", FromID: from, ToBox: "box-wui", ToID: "ALL-0", Kind: "note", Body: "see the file",
		Files: []byte(files), Msg: []byte(inner), Env: []byte(raw),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if _, err := e.st.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	return id
}

// removeAttachment is DELETE /v1/attachments/{id} as member `as`.
func removeAttachment(t *testing.T, e *env, tid, fileID, as string) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodDelete, e.url(tid)+"/v1/attachments/"+fileID, nil)
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("DELETE attachment: %v", err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, out
}

// storedFileIDs is the file ids a stored row still carries, from the files
// column AND the envelope the WUI reads.
func storedFileIDs(t *testing.T, e *env, tid, msgID string) (column, envelope []string) {
	t.Helper()
	m, err := e.st.GetEditable(context.Background(), tid, msgID, time.Now())
	if err != nil {
		t.Fatalf("GetEditable: %v", err)
	}
	var env struct {
		Msg struct {
			Files []struct {
				FileID string `json:"file_id"`
			} `json:"files"`
		} `json:"msg"`
	}
	if err := json.Unmarshal(m.Env, &env); err != nil {
		t.Fatalf("env: %v", err)
	}
	for _, f := range env.Msg.Files {
		envelope = append(envelope, f.FileID)
	}
	var inner struct {
		Files []struct {
			FileID string `json:"file_id"`
		} `json:"files"`
	}
	if err := json.Unmarshal(m.Msg, &inner); err != nil {
		t.Fatalf("msg: %v", err)
	}
	for _, f := range inner.Files {
		column = append(column, f.FileID)
	}
	return column, envelope
}

func blobExists(t *testing.T, e *env, tid, fileID string) bool {
	t.Helper()
	key, _ := blob.Key(tid, fileID)
	ok, err := (blob.Dir{Root: e.blobs}).Exists(context.Background(), key)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

// TestRemoveAttachmentUploaderAndAdmin — a stranger is refused and nothing
// changes; the uploader removes one of two files (the other stays on the
// card); an admin removes another member's file; each blob goes with it.
func TestRemoveAttachmentUploaderAndAdmin(t *testing.T) {
	e := rolesEnv(t)
	tid, _ := e.tenant()
	keep, gone, byAdmin := strings.Repeat("1", 64), strings.Repeat("2", 64), strings.Repeat("3", 64)
	id := putAttachRow(t, e, tid, "lobby", "HUM-54", keep, gone)
	other := putAttachRow(t, e, tid, "lobby", "HUM-54", byAdmin)

	// A regular member who did not upload it: 403, file and blob untouched.
	if code, out := removeAttachment(t, e, tid, gone, "HUM-58"); code != http.StatusForbidden || out["error"] != "not_author" {
		t.Fatalf("stranger: %d %v (want 403 not_author)", code, out)
	}
	if col, _ := storedFileIDs(t, e, tid, id); len(col) != 2 || !blobExists(t, e, tid, gone) {
		t.Fatalf("a refused remove changed the row or the blob: %v", col)
	}

	// The uploader: 200, only that file comes off, its blob is deleted.
	code, out := removeAttachment(t, e, tid, gone, "HUM-54")
	if code != http.StatusOK {
		t.Fatalf("uploader: %d %v (want 200)", code, out)
	}
	if out["blob_deleted"] != true || out["kept"] != float64(0) {
		t.Fatalf("uploader answer: %v", out)
	}
	col, envFiles := storedFileIDs(t, e, tid, id)
	if len(col) != 1 || col[0] != keep || len(envFiles) != 1 || envFiles[0] != keep {
		t.Fatalf("after remove: column %v envelope %v, want only %s", col, envFiles, keep[:4])
	}
	if blobExists(t, e, tid, gone) || !blobExists(t, e, tid, keep) {
		t.Fatal("the removed blob must be gone and the other one kept")
	}
	if code := getFile(t, e, tid, gone, "HUM-54"); code != http.StatusNotFound {
		t.Fatalf("GET the removed file: %d, want 404", code)
	}

	// A second remove of the same file: nothing carries it any more.
	if code, _ := removeAttachment(t, e, tid, gone, "HUM-54"); code != http.StatusNotFound {
		t.Fatalf("second remove: %d, want 404", code)
	}

	// A workspace admin removes another member's file.
	if code, out := removeAttachment(t, e, tid, byAdmin, "HUM-53"); code != http.StatusOK || out["blob_deleted"] != true {
		t.Fatalf("admin: %d %v (want 200, blob deleted)", code, out)
	}
	if col, _ := storedFileIDs(t, e, tid, other); len(col) != 0 {
		t.Fatalf("admin remove left %v on the row", col)
	}
}

// TestRemoveAttachmentSharedBlobStays — the same bytes on two members'
// messages: the uploader's own row loses it, the other member's keeps it,
// and so does the blob.
func TestRemoveAttachmentSharedBlobStays(t *testing.T) {
	e := rolesEnv(t)
	tid, _ := e.tenant()
	f := strings.Repeat("4", 64)
	mine := putAttachRow(t, e, tid, "lobby", "HUM-54", f)
	theirs := putAttachRow(t, e, tid, "lobby", "HUM-55", f)
	code, out := removeAttachment(t, e, tid, f, "HUM-54")
	if code != http.StatusOK || out["kept"] != float64(1) || out["blob_deleted"] != false {
		t.Fatalf("shared: %d %v (want 200, kept 1, blob kept)", code, out)
	}
	if col, _ := storedFileIDs(t, e, tid, mine); len(col) != 0 {
		t.Fatalf("own row still carries %v", col)
	}
	if col, _ := storedFileIDs(t, e, tid, theirs); len(col) != 1 || !blobExists(t, e, tid, f) {
		t.Fatalf("the other member's row or the blob changed: %v", col)
	}
}

// TestRemoveAttachmentReadDoor — a file in a channel the caller is not in is
// "no such file", exactly as GET answers it; the member of it is the control.
func TestRemoveAttachmentReadDoor(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC()
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "hr", Name: "hr", CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "hr", []string{"HUM-1"}, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	f := strings.Repeat("5", 64)
	putAttachRow(t, e, tid, "hr", "HUM-1", f)
	if code, _ := removeAttachment(t, e, tid, f, "HUM-2"); code != http.StatusNotFound || !blobExists(t, e, tid, f) {
		t.Fatalf("outsider: %d, want 404 and the blob kept", code)
	}
	if code, out := removeAttachment(t, e, tid, f, "HUM-1"); code != http.StatusOK {
		t.Fatalf("uploader in the channel: %d %v", code, out)
	}
}

// TestRemoveAttachmentLive — an open session is pushed a message_edited frame
// for the row, its envelope without the file, so the card loses it live.
func TestRemoveAttachmentLive(t *testing.T) {
	e := rolesEnv(t)
	tid, _ := e.tenant()
	viewer := dialMember(t, e, tid, "HUM-55", "HUM-55")
	wsjson.Write(context.Background(), viewer, map[string]string{"type": "subscribe", "task_id": lobby}) //nolint:errcheck
	readType(t, viewer, "subscribed")
	f := strings.Repeat("6", 64)
	id := putAttachRow(t, e, tid, "lobby", "HUM-54", f)
	if code, out := removeAttachment(t, e, tid, f, "HUM-54"); code != http.StatusOK {
		t.Fatalf("remove: %d %v", code, out)
	}
	frame := readType(t, viewer, "message_edited")
	if frame["msg_id"] != id {
		t.Fatalf("frame for %v, want %s", frame["msg_id"], id)
	}
	env, _ := frame["env"].(map[string]any)
	inner, _ := env["msg"].(map[string]any)
	if files, _ := inner["files"].([]any); len(files) != 0 {
		t.Fatalf("frame still carries files: %v", files)
	}
}
