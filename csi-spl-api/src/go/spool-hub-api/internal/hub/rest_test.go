package hub_test

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// getFile is GET /v1/files/{id} on tenant's host, with a bearer when token != "".
func (e *env) getFile(tenant, id, token string) (int, string) {
	e.t.Helper()
	req, _ := http.NewRequest(http.MethodGet, e.url(tenant)+"/v1/files/"+id, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

// 017 T006/T007 (FR-SEC-002): the file_id alone is no longer a capability.
// CONTROL: the anonymous GET that returned the bytes before this change is
// 401 view_door in the token door (the default) and the session door, and
// stays 200 only where the door is off (lde). A box token of the Host tenant
// reads; another tenant's token, a garbage token and a stale one do not.
func TestGetFileNeedsCredential(t *testing.T) {
	for _, door := range []string{hub.ViewDoorToken, hub.ViewDoorSession, hub.ViewDoorOff} {
		t.Run(door, func(t *testing.T) {
			var e *env
			if door == hub.ViewDoorSession {
				e = newDoorRig(t).e // the session door needs the sign-in surface
			} else {
				e = newEnv(t, func(o *hub.Options) { o.ViewDoor = door })
			}
			tid, _ := e.tenant()
			other, _ := e.tenant()
			a := e.box(tid, "box-a", "GRK-03")
			o := e.box(other, "box-o", "GRK-09")
			e.pin(tid, a)
			e.pin(other, o)
			data := []byte("confidential attachment")
			fid := sha256Hex(data)
			if err := (blob.Dir{Root: e.blobs}).Put(context.Background(), "t/"+tid+"/files/"+fid, data); err != nil {
				t.Fatal(err)
			}

			code, body := e.getFile(tid, fid, "")
			if door == hub.ViewDoorOff {
				if code != http.StatusOK || body != string(data) {
					t.Fatalf("door off, anonymous: %d %q", code, body)
				}
				return
			}
			if code != http.StatusUnauthorized || errToken([]byte(body)) != "view_door" || body == string(data) {
				t.Fatalf("anonymous GET: %d %s, want 401 view_door", code, body)
			}
			// An unknown id answers the same 401: no existence oracle.
			if code, body := e.getFile(tid, sha256Hex([]byte("nope")), ""); code != http.StatusUnauthorized {
				t.Fatalf("anonymous GET of an absent id: %d %s", code, body)
			}
			if code, _ := e.getFile(tid, fid, "not-a-token"); code != http.StatusUnauthorized {
				t.Fatalf("garbage token: %d", code)
			}
			tokO := e.uploadToken(other, o)
			if code, _ := e.getFile(tid, fid, tokO); code != http.StatusForbidden { // specs/026: tenant_mismatch
				t.Fatalf("other tenant's box token on this host: %d", code)
			}
			// That box on its own host: authenticated, but the id is not its tenant's.
			if code, _ := e.getFile(other, fid, tokO); code != http.StatusNotFound {
				t.Fatalf("other tenant's box, its own host: %d", code)
			}
			if code, body := e.getFile(tid, fid, e.uploadToken(tid, a)); code != http.StatusOK || body != string(data) {
				t.Fatalf("own box token: %d %q", code, body)
			}
		})
	}
}

// Session door (010 FR-009) + 017 FR-SEC-002: a signed-in member reads its
// tenant's files cross-origin with credentials; the same browser is 401 on a
// tenant it is not a member of, and 404 for another tenant's id on its own host.
func TestGetFileMemberSession(t *testing.T) {
	r := newDoorRig(t)
	mine, _ := r.e.tenant()
	theirs, _ := r.e.tenant()
	ctx := context.Background()
	data := []byte("member-only bytes")
	fid := sha256Hex(data)
	theirData := []byte("their bytes")
	theirFID := sha256Hex(theirData)
	bl := blob.Dir{Root: r.e.blobs}
	if err := bl.Put(ctx, "t/"+mine+"/files/"+fid, data); err != nil {
		t.Fatal(err)
	}
	if err := bl.Put(ctx, "t/"+theirs+"/files/"+theirFID, theirData); err != nil {
		t.Fatal(err)
	}

	// Before sign-in the browser is anonymous.
	if code, _, body := r.get(t, mine, "/v1/files/"+fid); code != http.StatusUnauthorized || errToken([]byte(body)) != "view_door" {
		t.Fatalf("anonymous browser: %d %s", code, body)
	}
	if landed := r.signIn(t, mine); landed == "" {
		t.Fatal("sign-in")
	}
	code, hdr, body := r.get(t, mine, "/v1/files/"+fid)
	if code != http.StatusOK || body != string(data) || hdr.Get("Access-Control-Allow-Origin") != wuiOrigin ||
		hdr.Get("Access-Control-Allow-Credentials") != "true" {
		t.Fatalf("member GET: %d %v %q", code, hdr, body)
	}
	// CLE-34985: content-addressed, so cacheable - but only privately, and
	// only for the credentials that passed the door.
	if cc, vary := hdr.Get("Cache-Control"), strings.Join(hdr.Values("Vary"), ","); cc != "private, max-age=86400, immutable" ||
		!strings.Contains(vary, "Cookie") || !strings.Contains(vary, "Authorization") {
		t.Fatalf("member GET cache headers: Cache-Control %q Vary %q", cc, vary)
	}
	if code, hdr, body := r.get(t, mine, "/v1/files/"+theirFID); code != http.StatusNotFound || hdr.Get("Cache-Control") != "" {
		t.Fatalf("their id via my host: %d %s", code, body)
	}
	if code, _, body := r.get(t, theirs, "/v1/files/"+theirFID); code != http.StatusForbidden || errToken([]byte(body)) != "tenant_mismatch" {
		t.Fatalf("non-member on their host: %d %s", code, body)
	}
}
