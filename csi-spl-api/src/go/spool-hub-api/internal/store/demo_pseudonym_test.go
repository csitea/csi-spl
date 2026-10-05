package store

import (
	"context"
	"errors"
	"regexp"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
)

// specs/077 T011 (FR-007): a demo visitor signs in under a generated
// pseudonym, keeps no IdP picture and cannot rename itself. CONTROL: a real
// member signing in to another workspace through the same hooks keeps its
// IdP name and picture, so the assertions would fail on the old code (which
// seeded the demo seat with the IdP name and stored its picture).
func TestDemoPseudonym(t *testing.T) {
	ctx := context.Background()
	shape := regexp.MustCompile(`^visitor-[0-9a-f]{4}$`)
	for name, s := range drivers(t) {
		h := s.(Humans)
		t.Run(name, func(t *testing.T) {
			demo, other := newTenant(t, s), newTenant(t, s)
			bl := blob.Dir{Root: t.TempDir()}
			hooks := AuthHooks{H: h, Blob: bl, Policy: AdmitPolicy{BootstrapOwner: true,
				OpenWorkspace: demo, OpenProviders: []string{"google", "facebook"}}}
			pic := []byte("\x89PNG demo picture " + uid(""))
			tag := uid("")
			ident := func(local, idpName string) auth.Identity {
				return auth.Identity{Provider: "google", Subject: uid(local + "-"),
					Email: local + "-" + tag + "@example.com", Name: idpName, Avatar: pic}
			}

			visitor := ident("v", "FirstName LastName")
			hv, err := hooks.Register(ctx, visitor, demo)
			if err != nil {
				t.Fatal(err)
			}
			got, err := h.DisplayName(ctx, hv)
			if err != nil || got != DemoPseudonym(hv) || !shape.MatchString(got) {
				t.Fatalf("demo display_name %q %v; want %q (visitor-xxxx)", got, err, DemoPseudonym(hv))
			}
			if av, err := h.Avatar(ctx, hv); err != nil || av != "" {
				t.Fatalf("demo avatar %q %v; want none (generated in the WUI)", av, err)
			}
			if _, err := hooks.OwnAvatar(ctx, hv); !errors.Is(err, auth.ErrNoAvatar) {
				t.Fatalf("demo own avatar: %v; want ErrNoAvatar", err)
			}
			if err := hooks.SetDisplayName(ctx, hv, "my real name"); !errors.Is(err, auth.ErrPseudonymFixed) {
				t.Fatalf("demo rename: %v; want ErrPseudonymFixed", err)
			}
			// A re-login keeps the pseudonym and still stores no picture.
			if again, err := hooks.Register(ctx, visitor, demo); err != nil || again != hv {
				t.Fatalf("re-login: %q %v", again, err)
			}
			if got, _ := h.DisplayName(ctx, hv); got != DemoPseudonym(hv) {
				t.Fatalf("re-login display_name %q", got)
			}
			if av, _ := h.Avatar(ctx, hv); av != "" {
				t.Fatalf("re-login avatar %q", av)
			}

			// CONTROL: the bootstrap owner of another workspace keeps both.
			ho, err := hooks.Register(ctx, ident("o", "FirstName LastName"), other)
			if err != nil {
				t.Fatal(err)
			}
			if got, _ := h.DisplayName(ctx, ho); got != "FirstName LastName" {
				t.Fatalf("real member display_name %q; want the IdP name", got)
			}
			if av, _ := h.Avatar(ctx, ho); av == "" {
				t.Fatal("real member avatar not stored")
			}
			if err := hooks.SetDisplayName(ctx, ho, "renamed"); err != nil {
				t.Fatalf("real member rename: %v", err)
			}
		})
	}
}
