package hub_test

// SPL-5570 (owner HUM-10 2026-11-13, #spool-hub-bugs c418ebfd, after HUM-24's
// report that any member could edit others' messages and close a file with X
// that offered to delete it): "Neither should one user have the right to edit
// messages of other users, nor even of AI. Every user should have the right to
// edit their own messages", and "nobody should have the right to delete
// attachments, neither agents' nor other users', only their own".
//
// Each refusal is paired with the same call by the author, so a handler that
// refused everyone fails this file too. Red on the SPL-1291 tree: the owner and
// the admin rows answered 200 (an edit, an attachment remove) and 204 (a file
// delete by any reader).

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
)

// theElevated are the two seats SPL-1291 let edit anyone's message.
var theElevated = []struct{ hum, role string }{{"HUM-51", "biz_owner"}, {"HUM-53", "admin"}}

// TestEditAuthorOnly - the tenant owner and an admin get 403 not_author editing
// another member's message AND an agent's (a hub-signed box-wui row the hub
// could re-sign, so rule 7 does not refuse it first); the body is untouched;
// the author still edits their own.
func TestEditAuthorOnly(t *testing.T) {
	e := rolesEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-54", "HUM-54")
	member, _ := postNote(t, author, "the developer's note")["msg_id"].(string)
	agent := putAttachRow(t, e, tid, "lobby", "CLE-07")
	for _, ed := range theElevated {
		_ = dialMember(t, e, tid, ed.hum, ed.hum)
		for _, id := range []string{member, agent} {
			code, out := patchEdit(t, e, tid, id, ed.hum, map[string]string{"body": "edited by " + ed.role})
			if code != http.StatusForbidden || out["error"] != "not_author" {
				t.Fatalf("%s editing %s: %d %v (want 403 not_author)", ed.role, id, code, out)
			}
		}
	}
	if got := storedBody(t, e, tid, member); got != "the developer's note" {
		t.Fatalf("a refused edit changed the member's message: %q", got)
	}
	if got := storedBody(t, e, tid, agent); got != "see the file" {
		t.Fatalf("a refused edit changed the agent's message: %q", got)
	}
	if code, out := patchEdit(t, e, tid, member, "HUM-54", map[string]string{"body": "fixed by its author"}); code != http.StatusOK {
		t.Fatalf("CONTROL: the author editing their own: %d %v (want 200)", code, out)
	}
}

// TestRemoveAttachmentAuthorOnly - DELETE /v1/attachments: the owner and an
// admin get 403 not_author on another member's file and on an agent's; the row
// and the blob stay; the uploader removes their own.
func TestRemoveAttachmentAuthorOnly(t *testing.T) {
	e := rolesEnv(t)
	tid, _ := e.tenant()
	mine, bot := strings.Repeat("4", 64), strings.Repeat("5", 64)
	id := putAttachRow(t, e, tid, "lobby", "HUM-54", mine)
	putAttachRow(t, e, tid, "lobby", "CLE-07", bot)
	for _, ed := range theElevated {
		for _, f := range []string{mine, bot} {
			if code, out := removeAttachment(t, e, tid, f, ed.hum); code != http.StatusForbidden || out["error"] != "not_author" {
				t.Fatalf("%s removing %s: %d %v (want 403 not_author)", ed.role, f[:4], code, out)
			}
			if !blobExists(t, e, tid, f) {
				t.Fatalf("%s: a refused remove deleted the blob %s", ed.role, f[:4])
			}
		}
	}
	if code, out := removeAttachment(t, e, tid, mine, "HUM-54"); code != http.StatusOK || out["blob_deleted"] != true {
		t.Fatalf("CONTROL: the uploader: %d %v (want 200, blob deleted)", code, out)
	}
	if col, _ := storedFileIDs(t, e, tid, id); len(col) != 0 {
		t.Fatalf("the uploader's remove left %v on the row", col)
	}
}

// deleteFile is DELETE /v1/files/{id} with an upload token and, for a
// browser, the member session that rides with it.
func deleteFile(t *testing.T, e *env, tid, fileID, token, member string) int {
	t.Helper()
	req, _ := http.NewRequest(http.MethodDelete, e.url(tid)+"/v1/files/"+fileID, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	if member != "" {
		req.Header.Set(memberHeader, member)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

// TestDeleteFileUploaderOnlyBrowser - DELETE /v1/files from a browser: the
// owner and an admin, who READ the lobby file, get 404 (the refusal still
// answers as a missing file, so existence does not leak); so does the
// uploader of the same bytes while another member's message also carries
// them; the uploader of every carrier deletes it (204).
func TestDeleteFileUploaderOnlyBrowser(t *testing.T) {
	e := rolesEnv(t)
	tid, _ := e.tenant()
	own, shared := strings.Repeat("6", 64), strings.Repeat("7", 64)
	putAttachRow(t, e, tid, "lobby", "HUM-54", own, shared)
	putAttachRow(t, e, tid, "lobby", "HUM-55", shared)
	for _, ed := range theElevated {
		if code := getFile(t, e, tid, own, ed.hum); code != http.StatusOK {
			t.Fatalf("precondition: %s reads the lobby file: %d", ed.role, code)
		}
		if code := deleteFile(t, e, tid, own, uploadToken(t, e, tid, ed.hum), ed.hum); code != http.StatusNotFound {
			t.Fatalf("%s deletes another member's file: %d (want 404)", ed.role, code)
		}
	}
	tok := uploadToken(t, e, tid, "HUM-54")
	if code := deleteFile(t, e, tid, shared, tok, "HUM-54"); code != http.StatusNotFound || !blobExists(t, e, tid, shared) {
		t.Fatalf("uploader deletes bytes another member's message carries: %d (want 404, blob kept)", code)
	}
	if !blobExists(t, e, tid, own) {
		t.Fatal("a refused delete removed the blob")
	}
	if code := deleteFile(t, e, tid, own, tok, "HUM-54"); code != http.StatusNoContent || blobExists(t, e, tid, own) {
		t.Fatalf("CONTROL: the uploader deletes their own file: %d (want 204, blob gone)", code)
	}
}

// TestDeleteFileUploaderOnlyBox - DELETE /v1/files from a box: box-b received
// box-a's file and may read it, but did not upload it: 404 and the file stays.
// box-a, which sent it, deletes it (204).
func TestDeleteFileUploaderOnlyBox(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	a.c.Sync(ctx) //nolint:errcheck
	b.c.Sync(ctx) //nolint:errcheck
	src := filepath.Join(t.TempDir(), "report.txt")
	os.WriteFile(src, []byte("the report"), 0o644) //nolint:errcheck
	att, err := files.PutFile(a.cfg.FilesDir(), src)
	if err != nil {
		t.Fatal(err)
	}
	send(t, a, "GRK-03", "CLE-07", "task", "see file", "box-b", att.FileID)
	b.c.Sync(ctx) //nolint:errcheck
	bt := e.uploadToken(tid, b)
	if code, _ := e.getFile(tid, att.FileID, bt); code != http.StatusOK {
		t.Fatalf("precondition: box-b reads the file it received: %d", code)
	}
	if code := deleteFile(t, e, tid, att.FileID, bt, ""); code != http.StatusNotFound {
		t.Fatalf("box-b deletes box-a's file: %d (want 404)", code)
	}
	if code, _ := e.getFile(tid, att.FileID, bt); code != http.StatusOK {
		t.Fatalf("the file is gone after a refused delete: %d", code)
	}
	if code := deleteFile(t, e, tid, att.FileID, e.uploadToken(tid, a), ""); code != http.StatusNoContent {
		t.Fatalf("CONTROL: box-a deletes the file it sent: %d (want 204)", code)
	}
}
