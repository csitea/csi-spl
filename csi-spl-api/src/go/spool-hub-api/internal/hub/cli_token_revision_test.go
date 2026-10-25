package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-3262: `spool doctree` (and the other one-shot verbs) dial role=cli,
// take the session's upload token, and send their REST calls with it. While
// a deploy rolls, the old and the new revision both serve: on prd
// 2026-10-24 revision 00937 started 11:00:27Z and 00934 still answered
// requests until 11:12:30Z. A box token was bound to its minting revision
// (SPL-1826), so a doctree call on the other one was refused
// (unknown_token), fell through to the browser door and answered
// "401: not signed in (a view token or a member session is required)":
// 2 of 2 repo-tree edits and 1 read failed that way. A role=cli session
// keeps no socket for a probe to strand, so its token is good on every
// revision; a role=box token stays bound (box_token_instances_test.go).

// cliTokenOn dials role on a (revision rev-1) and sends the doctree edit
// the desk action sends, with that session's token, to restOn's instance.
func cliTokenOn(t *testing.T, role string, restOn func(a, b *env) *env) (int, string) {
	t.Helper()
	a := newEnv(t, func(o *hub.Options) { o.UploadTokenKey, o.Revision = uploadKey, "rev-1" })
	b := newUploadPeer(t, a, uploadKey, nil, func(o *hub.Options) { o.Revision, o.ViewDoor = "rev-2", hub.ViewDoorToken })
	tid, _ := a.tenant()
	bx := a.box(tid, "box-a")
	a.pin(tid, bx)
	ctx := context.Background()
	sess, err := bx.c.Dial(ctx, role)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	tok, err := sess.UploadToken(ctx)
	if err != nil {
		t.Fatal(err)
	}
	rest := restOn(a, b)
	req, _ := http.NewRequest(http.MethodPatch,
		rest.url(tid)+"/v1/workspace/doctree/0d291303-2b30-4b23-8541-cd2ff5863387/items/7169e7e9-1b98-42d6-92be-0407bbc9b7a6?fs=repo",
		strings.NewReader(`{"field":"body","value":"x","rev":1}`))
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Content-Type", "application/json")
	resp, err := rest.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var eb struct {
		Error string `json:"error"`
	}
	json.NewDecoder(resp.Body).Decode(&eb) //nolint:errcheck
	return resp.StatusCode, eb.Error
}

// past is an answer from past the caller check: the memory store has no
// doc tree (404 workspace_doc_tree_off); on Postgres the tenant is not the
// operator workspace (403 repo_docs_read_only). Either means the token was
// accepted; 401 means it was not.
func past(code int, tok string) bool {
	return (code == http.StatusNotFound && tok == "workspace_doc_tree_off") ||
		(code == http.StatusForbidden && tok == "repo_docs_read_only")
}

func TestCLITokenOnTheNextRevision(t *testing.T) {
	const n = 3
	for _, tc := range []struct {
		name     string
		role     string
		restOn   func(a, b *env) *env
		accepted bool
	}{
		{"control: role=cli, REST on the minting revision", wire.RoleCLI, func(a, _ *env) *env { return a }, true},
		{"role=cli, REST on the next revision", wire.RoleCLI, func(_, b *env) *env { return b }, true},
		{"role=box, REST on the next revision stays refused", wire.RoleBox, func(_, b *env) *env { return b }, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for i := range n {
				code, tok := cliTokenOn(t, tc.role, tc.restOn)
				if tc.accepted && !past(code, tok) {
					t.Errorf("try %d: %d %s, want the token accepted", i, code, tok)
				}
				if !tc.accepted && code != http.StatusUnauthorized {
					t.Errorf("try %d: %d %s, want 401", i, code, tok)
				}
			}
		})
	}
}
