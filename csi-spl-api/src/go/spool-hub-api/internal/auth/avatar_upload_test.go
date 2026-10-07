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

// t1 ccaee528: a person changes their own picture. PUT stores it where the
// IdP picture lives (GET serves it, the roster names it), a later sign-in
// keeps it, DELETE goes back to the IdP picture. CONTROLS: no session -> 401;
// a wrong type -> 415 and an over-cap body -> 413, each beside an accepted
// one; another person's picture never changes.
func TestOwnAvatarUpload(t *testing.T) {
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
	mine := fakeidp.Avatar("alice-upload")

	// CONTROL: no session -> 401 on both writes.
	if code := putAvatar(t, browser(t), r, mine); code != http.StatusUnauthorized {
		t.Fatalf("PUT without a session: %d, want 401", code)
	}
	if code := deleteAvatar(t, browser(t), r); code != http.StatusUnauthorized {
		t.Fatalf("DELETE without a session: %d, want 401", code)
	}

	c := browser(t)
	signIn(t, c, r, "google", "?tenant=t1")
	_, s := session(t, c, r)
	bob := fakeidp.Person{Subject: "sub-bob", Email: "bob@example.com", EmailVerified: true, Name: "FirstName LastName"}
	r.fake.Set(bob, false)
	b := browser(t)
	signIn(t, b, r, "google", "") // t1 has its bootstrap owner: bob signs in with no tenant
	if _, bs := session(t, b, r); bs.HumanID == "" || bs.HumanID == s.HumanID {
		t.Fatalf("bob's session %+v", bs)
	}
	r.fake.Set(alice, false)

	// Wrong type -> 415, too big -> 413; nothing changes.
	gif := append([]byte("GIF89a"), make([]byte, 64)...)
	for name, body := range map[string][]byte{"gif": gif, "text": []byte("not a picture"), "empty": nil} {
		if code := putAvatar(t, c, r, body); code != http.StatusUnsupportedMediaType {
			t.Fatalf("%s: %d, want 415", name, code)
		}
	}
	big := append(append([]byte{}, mine...), make([]byte, auth.AvatarMaxBytes)...)
	if code := putAvatar(t, c, r, big); code != http.StatusRequestEntityTooLarge {
		t.Fatalf("over the cap: %d, want 413", code)
	}
	if _, got, _ := ownAvatar(t, c, r, ""); !bytes.Equal(got, fakeidp.Avatar(alice.Subject)) {
		t.Fatal("a refused upload changed the picture")
	}

	// CONTROL beside the refusals: a png (and one exactly at the cap) is taken.
	atCap := append(append([]byte{}, mine...), make([]byte, auth.AvatarMaxBytes-len(mine))...)
	if code := putAvatar(t, c, r, atCap); code != http.StatusNoContent {
		t.Fatalf("png at the cap: %d, want 204", code)
	}
	if code := putAvatar(t, c, r, mine); code != http.StatusNoContent {
		t.Fatalf("png: %d, want 204", code)
	}

	// Upload then GET serves it, and the roster names it as a tenant file.
	if code, got, _ := ownAvatar(t, c, r, ""); code != http.StatusOK || !bytes.Equal(got, mine) {
		t.Fatalf("after upload: %d, %d bytes, not the upload", code, len(got))
	}
	ids, err := st.TenantAvatars(ctx, "t1")
	if err != nil || ids[s.HumanID] != sha256hex(mine) {
		t.Fatalf("roster avatar %v %v", ids, err)
	}
	if key, _ := blob.Key("t1", sha256hex(mine)); !exists(t, bs, key) {
		t.Fatal("upload has no tenant file for the roster")
	}

	// Someone else's picture is untouched.
	if _, got, _ := ownAvatar(t, b, r, ""); !bytes.Equal(got, fakeidp.Avatar(bob.Subject)) {
		t.Fatal("alice's upload changed bob's picture")
	}

	// A sign-in after the upload keeps it, even when the IdP picture changed.
	changed := alice
	changed.PictureSeed = "alice-new-idp"
	r.fake.Set(changed, false)
	signIn(t, c, r, "google", "?tenant=t1")
	if _, got, _ := ownAvatar(t, c, r, ""); !bytes.Equal(got, mine) {
		t.Fatal("a sign-in overwrote the uploaded picture")
	}

	// DELETE -> the IdP picture again (the one the last sign-in brought).
	if code := deleteAvatar(t, c, r); code != http.StatusNoContent {
		t.Fatalf("DELETE: %d, want 204", code)
	}
	if code, got, _ := ownAvatar(t, c, r, ""); code != http.StatusOK || !bytes.Equal(got, fakeidp.Avatar("alice-new-idp")) {
		t.Fatalf("after DELETE: %d, not the IdP picture", code)
	}
	// ... and sign-ins update it again; a second DELETE changes nothing.
	signIn(t, c, r, "google", "?tenant=t1")
	if code := deleteAvatar(t, c, r); code != http.StatusNoContent {
		t.Fatalf("second DELETE: %d", code)
	}
	if _, got, _ := ownAvatar(t, c, r, ""); !bytes.Equal(got, fakeidp.Avatar("alice-new-idp")) {
		t.Fatal("a DELETE with nothing uploaded changed the picture")
	}
	if _, got, _ := ownAvatar(t, b, r, ""); !bytes.Equal(got, fakeidp.Avatar(bob.Subject)) {
		t.Fatal("alice's DELETE changed bob's picture")
	}
}

// A person with no IdP picture uploads one; DELETE goes back to none (404,
// the WUI draws the identicon).
func TestOwnAvatarUploadNoIdPPicture(t *testing.T) {
	st := store.NewMemory()
	hooks := store.AuthHooks{H: st, Blob: blob.Dir{Root: t.TempDir()}}
	r := newRigWith(t, auth.Options{Registrar: hooks, Membership: hooks, Avatars: hooks})
	r.fake.Set(fakeidp.Person{Subject: "nopic-up", Email: "nopic-up@example.com", EmailVerified: true, NoPicture: true}, false)
	c := browser(t)
	signIn(t, c, r, "google", "")
	mine := fakeidp.Avatar("nopic-upload")
	if code := putAvatar(t, c, r, mine); code != http.StatusNoContent {
		t.Fatalf("PUT: %d", code)
	}
	if _, got, _ := ownAvatar(t, c, r, ""); !bytes.Equal(got, mine) {
		t.Fatal("upload not served")
	}
	if code := deleteAvatar(t, c, r); code != http.StatusNoContent {
		t.Fatalf("DELETE: %d", code)
	}
	if code, _, _ := ownAvatar(t, c, r, ""); code != http.StatusNotFound {
		t.Fatalf("after DELETE: %d, want 404", code)
	}
}

// CONTROL: an AvatarSource that cannot write (or none) answers 503, not 500.
func TestOwnAvatarUploadUnwired(t *testing.T) {
	r := newRigWith(t, auth.Options{Registrar: registrar{}})
	c := browser(t)
	signIn(t, c, r, "google", "")
	if code := putAvatar(t, c, r, fakeidp.Avatar("x")); code != http.StatusServiceUnavailable {
		t.Fatalf("unwired PUT: %d, want 503", code)
	}
	if code := deleteAvatar(t, c, r); code != http.StatusServiceUnavailable {
		t.Fatalf("unwired DELETE: %d, want 503", code)
	}
}

func putAvatar(t *testing.T, c *http.Client, r *rig, body []byte) int {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPut, r.hub+"/api/v1/auth/avatar", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/octet-stream")
	return do(t, c, req)
}

func deleteAvatar(t *testing.T, c *http.Client, r *rig) int {
	t.Helper()
	req, _ := http.NewRequest(http.MethodDelete, r.hub+"/api/v1/auth/avatar", nil)
	return do(t, c, req)
}

func do(t *testing.T, c *http.Client, req *http.Request) int {
	t.Helper()
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body) //nolint:errcheck
	return resp.StatusCode
}
