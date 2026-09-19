package auth_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// 010 T044 end to end: a fake IdP with a picture -> the callback fetches it
// server-side -> the bytes are a tenant blob and humans.avatar_file_id names
// them. CONTROLS: a refused sign-in stores no blob; a person without a
// picture gets no avatar; a sign-in with no tenant stores nothing.
func TestIdPAvatarStoredAsFileID(t *testing.T) {
	ctx := context.Background()
	st := store.NewMemory()
	for _, id := range []string{"t1", "t2"} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := st.CreateTenant(ctx, store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	// t2 already has an owner, so the sign-in there is refused.
	if _, err := st.Admit(ctx, store.Identity{Provider: "google", Subject: "someone-else"}, "t2",
		store.AdmitPolicy{BootstrapOwner: true}, nowUTC()); err != nil {
		t.Fatal(err)
	}
	bs := blob.Dir{Root: t.TempDir()}
	var avatarErrs []error
	hooks := store.AuthHooks{H: st, Policy: store.AdmitPolicy{BootstrapOwner: true}, Blob: bs,
		AvatarErr: func(_ string, err error) { avatarErrs = append(avatarErrs, err) }}
	r := newRigWith(t, auth.Options{Registrar: hooks, Membership: hooks})
	want := fakeidp.Avatar(alice.Subject)
	wantID := sha256hex(want)
	key, _ := blob.Key("t1", wantID)

	// CONTROL: refused on t2 -> nothing under any tenant prefix.
	if u := signIn(t, browser(t), r, "google", "?tenant=t2"); u.Query().Get("auth_error") != auth.ErrCodeNotAllowed {
		t.Fatalf("t2 landed on %s", u)
	}
	for _, tn := range []string{"t1", "t2"} {
		if n, _ := bs.PrefixBytes(ctx, "t/"+tn+"/files/"); n != 0 {
			t.Fatalf("refused sign-in wrote %d blob bytes under %s", n, tn)
		}
	}

	// No tenant: registered, but no blob prefix to put the picture under.
	c := browser(t)
	signIn(t, c, r, "google", "")
	_, s := session(t, c, r)
	if got, err := st.Avatar(ctx, s.HumanID); err != nil || got != "" {
		t.Fatalf("tenantless sign-in stored avatar %q %v", got, err)
	}

	// Google on t1: the picture is a t1 blob, and the human names it.
	signIn(t, c, r, "google", "?tenant=t1")
	if got, err := st.Avatar(ctx, s.HumanID); err != nil || got != wantID {
		t.Fatalf("avatar_file_id = %q %v, want %s", got, err, wantID)
	}
	rc, err := bs.Get(ctx, key)
	if err != nil {
		t.Fatalf("blob %s: %v", key, err)
	}
	b, _ := io.ReadAll(rc)
	rc.Close()
	if !bytes.Equal(b, want) {
		t.Fatalf("blob bytes differ from the IdP picture (%d vs %d)", len(b), len(want))
	}

	// Facebook reads Graph's picture edge (a separate human, same picture);
	// t1 has its owner now, so this identity comes in on an invite.
	if err := st.PutInvite(ctx, store.Invite{TenantID: "t1", Email: alice.Email, InvitedBy: s.HumanID,
		ExpiresAt: nowUTC().Add(time.Hour)}, nowUTC()); err != nil {
		t.Fatal(err)
	}
	fb := browser(t)
	if u := signIn(t, fb, r, "facebook", "?tenant=t1"); u.Query().Get("auth_error") != "" {
		t.Fatalf("facebook on t1 landed on %s", u)
	}
	if _, s2 := session(t, fb, r); s2.HumanID == "" || s2.HumanID == s.HumanID {
		t.Fatalf("facebook human %q (google %q)", s2.HumanID, s.HumanID)
	} else if got, _ := st.Avatar(ctx, s2.HumanID); got != wantID {
		t.Fatalf("facebook avatar = %q, want %s", got, wantID)
	}

	// CONTROL: a person with no picture gets no avatar.
	r.fake.Set(fakeidp.Person{Subject: "nopic-1", Email: "nopic@example.com", EmailVerified: true, NoPicture: true}, false)
	np := browser(t)
	if err := st.PutInvite(ctx, store.Invite{TenantID: "t1", Email: "nopic@example.com", InvitedBy: s.HumanID,
		ExpiresAt: nowUTC().Add(time.Hour)}, nowUTC()); err != nil {
		t.Fatal(err)
	}
	signIn(t, np, r, "google", "?tenant=t1")
	if _, s3 := session(t, np, r); s3.HumanID == "" {
		t.Fatal("no-picture person was not signed in")
	} else if got, _ := st.Avatar(ctx, s3.HumanID); got != "" {
		t.Fatalf("no-picture person got avatar %q", got)
	}
	if len(avatarErrs) != 0 {
		t.Fatalf("avatar errors: %v", avatarErrs)
	}
}

func nowUTC() time.Time { return time.Now().UTC() }

func sha256hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
