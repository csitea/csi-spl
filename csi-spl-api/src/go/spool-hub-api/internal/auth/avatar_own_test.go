package auth_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"io"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// CLE-3406: the top-right avatar is the person's own IdP picture, read from
// GET /api/v1/auth/avatar with the session alone. Claim -> stored picture ->
// session route, for a member AND a not-yet-member (no tenant), refreshed
// on the next sign-in. CONTROLS: no picture claim -> 404 (the WUI draws the
// identicon); no session -> 401; a picture stored only under a tenant (before
// this change) -> 404 until the next sign-in.
func TestOwnAvatarRoute(t *testing.T) {
	ctx := context.Background()
	st := store.NewMemory()
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := st.CreateTenant(ctx, store.Tenant{ID: "t1", RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	bs := blob.Dir{Root: t.TempDir()}
	hooks := store.AuthHooks{H: st, Policy: store.AdmitPolicy{BootstrapOwner: true}, Blob: bs,
		AvatarErr: func(_ string, err error) { t.Errorf("avatar not stored: %v", err) }}
	r := newRigWith(t, auth.Options{Registrar: hooks, Membership: hooks, Avatars: hooks})

	// CONTROL: no session.
	if code, _, _ := ownAvatar(t, browser(t), r, ""); code != http.StatusUnauthorized {
		t.Fatalf("no session: %d, want 401", code)
	}

	// Not yet a member: signed in with no tenant, the picture is already theirs.
	c := browser(t)
	signIn(t, c, r, "google", "")
	if _, s := session(t, c, r); s.HumanID == "" {
		t.Fatal("tenantless sign-in has no human")
	}
	code, body, h := ownAvatar(t, c, r, "")
	if code != http.StatusOK || !bytes.Equal(body, fakeidp.Avatar(alice.Subject)) {
		t.Fatalf("not-yet-member avatar: %d, %d bytes", code, len(body))
	}
	if h.Get("Content-Type") != "image/png" || h.Get("Cache-Control") != "private, no-cache" ||
		h.Get("ETag") != `"`+sha256hex(body)+`"` {
		t.Fatalf("headers %v", h)
	}
	if code, _, _ := ownAvatar(t, c, r, h.Get("ETag")); code != http.StatusNotModified {
		t.Fatalf("If-None-Match: %d, want 304", code)
	}

	// A member (bootstrap owner of t1): same picture.
	signIn(t, c, r, "google", "?tenant=t1")
	if code, body, _ := ownAvatar(t, c, r, ""); code != http.StatusOK || !bytes.Equal(body, fakeidp.Avatar(alice.Subject)) {
		t.Fatalf("member avatar: %d", code)
	}

	// Refreshed on the next sign-in: the person changed their Google picture.
	changed := alice
	changed.PictureSeed = "alice-new-photo"
	r.fake.Set(changed, false)
	signIn(t, c, r, "google", "?tenant=t1")
	if code, body, _ := ownAvatar(t, c, r, ""); code != http.StatusOK || !bytes.Equal(body, fakeidp.Avatar("alice-new-photo")) {
		t.Fatalf("after a changed picture: %d, old bytes still served", code)
	}

	// CONTROL: no picture claim -> 404, never someone else's picture.
	r.fake.Set(fakeidp.Person{Subject: "nopic-own", Email: "nopic-own@example.com", EmailVerified: true, NoPicture: true}, false)
	np := browser(t)
	signIn(t, np, r, "google", "")
	if code, _, _ := ownAvatar(t, np, r, ""); code != http.StatusNotFound {
		t.Fatalf("no picture claim: %d, want 404", code)
	}

	// CONTROL: a picture that exists only as a tenant file (stored before the
	// hub-wide copy) is not served from here.
	legacy := fakeidp.Avatar("legacy")
	fid := sha256hex(legacy)
	key, _ := blob.Key("t1", fid)
	if err := bs.Put(ctx, key, legacy); err != nil {
		t.Fatal(err)
	}
	_, s := session(t, np, r)
	if err := st.SetAvatar(ctx, s.HumanID, fid); err != nil {
		t.Fatal(err)
	}
	if code, _, _ := ownAvatar(t, np, r, ""); code != http.StatusNotFound {
		t.Fatalf("tenant-only picture: %d, want 404", code)
	}
}

// CONTROL: a hub without an AvatarSource answers 404, not 500.
func TestOwnAvatarRouteUnwired(t *testing.T) {
	r := newRigWith(t, auth.Options{Registrar: registrar{}})
	c := browser(t)
	signIn(t, c, r, "google", "")
	if code, _, _ := ownAvatar(t, c, r, ""); code != http.StatusNotFound {
		t.Fatalf("unwired: %d, want 404", code)
	}
}

func ownAvatar(t *testing.T, c *http.Client, r *rig, etag string) (int, []byte, http.Header) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, r.hub+"/api/v1/auth/avatar", nil)
	if etag != "" {
		req.Header.Set("If-None-Match", etag)
	}
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b, resp.Header
}
