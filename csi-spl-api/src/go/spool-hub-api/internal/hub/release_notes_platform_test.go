package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-6274 (owner HUM-10, t1 95c5be35, msgs 315e9644 and 228bbd19): the
// version card's Release notes read the spool's own release log, the
// operator workspace's primary repo, in every workspace, signed in or not
// (scope=platform). A workspace's own repo stays its own read.
// RED CONTROL: drop the scope branch in releaseReader and the workspace
// with no repo reads an empty list (TestReleaseNotesPlatformScope fails).

// platformRig is a hub whose operator workspace op has a primary repo
// (public unless private) with one note, a workspace own with its own
// public primary repo and note, and a workspace bare with no repo; each with
// a member.
type platformRig struct {
	e                      *env
	op, own, bare          string
	opHum, ownHum, bareHum string
	opRepo, ownRepo        string
}

func newPlatformRig(t *testing.T, public bool) platformRig {
	t.Helper()
	op := newTenantID("op")
	var humans store.Humans
	e, own, ownHum := releaseEnv(t, func(o *hub.Options) {
		o.OperatorTenant = op
		o.OriginTenant = hub.NewOriginTenant("{tenant}"+domain, "")
		// per workspace, as auth.SessionForTenant on the real hub: a session
		// counts only where its human is a member.
		o.SessionID = func(r *http.Request, tenant string) (string, error) {
			hum := r.Header.Get(memberHeader)
			if hum == "" {
				return "", errors.New("no session")
			}
			if _, err := humans.MemberRole(r.Context(), hum, tenant); err != nil {
				return "", err
			}
			return hum, nil
		}
	})
	humans = e.st.(store.Humans)
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: op, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	rg := platformRig{e: e, op: op, own: own, ownHum: ownHum, opRepo: repoOf(op, "spl"), ownRepo: repoOf(own, "main")}
	registerRepoPublic(t, e, op, rg.opRepo, true, public)
	rg.bare, _ = e.tenant()
	rg.opHum, rg.bareHum = seat(t, e, op, rbac.Developer), seat(t, e, rg.bare, rbac.Developer)
	for tenant, row := range map[string]map[string]any{
		op:  releaseRow(releaseSHA("a"), "v7.4.1", releaseFullMsg),
		own: releaseRow(releaseSHA("b"), "v1.0.0", releaseFullMsg),
	} {
		repo := map[string]string{op: rg.opRepo, own: rg.ownRepo}[tenant]
		if code, out := opCall(t, e, tenant, http.MethodPost, "/v1/operator/release-notes", "good",
			map[string]any{"tenant": tenant, "repo_slug": repo, "notes": []any{row}}); code != http.StatusOK || out["stored"] != float64(1) {
			t.Fatalf("ingest %s: %d %v", tenant, code, out)
		}
	}
	return rg
}

// listSHAs is the shas of a list answer, newest first.
func listSHAs(out map[string]any) []string {
	var shas []string
	vs, _ := out["versions"].([]any)
	for _, v := range vs {
		ns, _ := v.(map[string]any)["notes"].([]any)
		for _, n := range ns {
			shas = append(shas, n.(map[string]any)["sha"].(string))
		}
	}
	return shas
}

func wantShas(t *testing.T, what string, code int, out map[string]any, want ...string) {
	t.Helper()
	got := listSHAs(out)
	if code != http.StatusOK || len(got) != len(want) || (len(want) == 1 && got[0] != want[0]) {
		t.Fatalf("%s = %d %v (shas %v), want 200 and %v", what, code, out, got, want)
	}
}

func TestReleaseNotesPlatformScope(t *testing.T) {
	rg := newPlatformRig(t, true)
	e, opSHA, ownSHA := rg.e, releaseSHA("a"), releaseSHA("b")
	const list = "/v1/release-notes?limit=5&scope=platform"
	for name, c := range map[string]struct{ tid, as string }{
		"a member of a workspace with no repo":         {rg.bare, rg.bareHum},
		"a member of a workspace with its own primary": {rg.own, rg.ownHum},
		"a member of the operator workspace":           {rg.op, rg.opHum},
	} {
		code, out := call(t, e, c.tid, http.MethodGet, list, c.as, nil)
		wantShas(t, name, code, out, opSHA)
		if code, out := call(t, e, c.tid, http.MethodGet, "/v1/release-notes/v7.4.1?scope=platform", c.as, nil); code != http.StatusOK || len(out["notes"].([]any)) != 1 {
			t.Fatalf("%s: version read = %d %v", name, code, out)
		}
		if n := noteOf(t, e, c.tid, c.as, opSHA[:9]+"?scope=platform"); n["sha"] != opSHA {
			t.Fatalf("%s: note read = %v", name, n)
		}
	}
	for name, v := range map[string]struct{ host, origin string }{
		"signed out on the bare workspace's page": {rg.bare + domain, ""},
		"signed out, Origin of the own workspace": {"api" + domain, "https://" + rg.own + domain},
		"signed out, no workspace named":          {"api" + domain, ""},
	} {
		code, out := visitorGet(t, e, v.host, v.origin, list)
		wantShas(t, name, code, out, opSHA)
	}
	// The workspace's own read is unchanged: own reads its repo, bare none.
	code, out := call(t, e, rg.own, http.MethodGet, "/v1/release-notes?limit=5", rg.ownHum, nil)
	wantShas(t, "own, no scope", code, out, ownSHA)
	// No customer repo through the platform scope: own's repo by name 404s.
	if code, out := call(t, e, rg.own, http.MethodGet, "/v1/release-notes/"+ownSHA+"?scope=platform&repo="+rg.ownRepo, rg.ownHum, nil); code != http.StatusNotFound {
		t.Fatalf("own repo through scope=platform = %d %v, want 404", code, out)
	}
	if code, out := call(t, e, rg.own, http.MethodGet, "/v1/release-notes?scope=other", rg.ownHum, nil); code != http.StatusBadRequest {
		t.Fatalf("scope=other = %d %v, want 400", code, out)
	}
}

// CONTROL: the operator's primary repo not flagged notes_public is read by
// its members only; every other reader gets the empty list, never another
// workspace's notes.
func TestReleaseNotesPlatformScopePrivate(t *testing.T) {
	rg := newPlatformRig(t, false)
	const list = "/v1/release-notes?limit=5&scope=platform"
	code, out := call(t, rg.e, rg.op, http.MethodGet, list, rg.opHum, nil)
	wantShas(t, "operator member", code, out, releaseSHA("a"))
	code, out = call(t, rg.e, rg.own, http.MethodGet, list, rg.ownHum, nil)
	wantShas(t, "own member", code, out)
	code, out = visitorGet(t, rg.e, rg.bare+domain, "", list)
	wantShas(t, "visitor", code, out)
}
