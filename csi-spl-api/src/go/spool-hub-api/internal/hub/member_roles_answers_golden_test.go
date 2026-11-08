package hub_test

import (
	"bytes"
	"encoding/json"
	"flag"
	"maps"
	"net/http"
	"os"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

var updateMemberRolesAnswers = flag.Bool("update-member-roles-answers", false, "rewrite testdata/member_roles_answers.golden.json")

const memberRolesAnswersGolden = "testdata/member_roles_answers.golden.json"

// memberRolesAnswer is one call's real answer, as the browser reads it.
type memberRolesAnswer struct {
	Status int `json:"status"`
	Body   any `json:"body"`
}

// memberRowMasked is a member row without what differs per run; the keys and
// the role set stay, they are the point.
func memberRowMasked(row map[string]any) map[string]any {
	out := maps.Clone(row)
	for key, mask := range map[string]string{"human_id": "<human_id>", "email": "member@example.com", "display_name": "<display_name>", "since": "<time>", "last_seen": "<time>", "invited_on": "<time>"} {
		if out[key] != nil {
			out[key] = mask
		}
	}
	return out
}

// SPL-5056: the hub's answers on the member role routes, pinned for the web
// client. csi-spl-wui/tests/unit/member-roles-client.test.mjs reads this file,
// so a client that reads another shape and a hub that changes its shape both
// go red without a browser. Generated from the handlers, never by hand:
//
//	go test ./internal/hub -run TestMemberRolesAnswersGolden -update-member-roles-answers
func TestMemberRolesAnswersGolden(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	owner := seat(t, e, tid, rbac.BizOwner)
	admin := seat(t, e, tid, rbac.Admin)
	dev := seat(t, e, tid, rbac.Developer)
	path := "/v1/members/" + dev + "/roles"
	answers := map[string]memberRolesAnswer{}
	ask := func(name, target, as string, body any) map[string]any {
		t.Helper()
		code, out := call(t, e, tid, http.MethodPut, target, as, body)
		if out["human_id"] != nil {
			out = memberRowMasked(out)
		}
		delete(out, "tenant_id")
		answers[name] = memberRolesAnswer{Status: code, Body: out}
		return out
	}

	got := ask("set", path, admin, map[string]any{"roles": []string{rbac.Developer, rbac.Tester}, "primary": rbac.Tester, "from_roles": []string{rbac.Developer}})
	if got["role"] != rbac.Tester {
		t.Fatalf("CONTROL: the set did not land: %v", got)
	}
	ask("stale_from_roles", path, admin, map[string]any{"roles": []string{rbac.Tester}, "from_roles": []string{rbac.Developer}})
	ask("not_grantable", path, admin, map[string]any{"roles": []string{rbac.BizOwner}})
	ask("role_not_in_tenant", path, admin, map[string]any{"roles": []string{rbac.Developer, rbac.DemoUser}})
	ask("empty_set", path, admin, map[string]any{"roles": []string{}})
	ask("last_owner", "/v1/members/"+owner+"/roles", owner, map[string]any{"roles": []string{rbac.Developer}})

	code, list := call(t, e, tid, http.MethodGet, "/v1/members", admin, nil)
	answers["list_row"] = memberRolesAnswer{Status: code, Body: memberRowMasked(memberRowOf(t, list, dev))}
	// Two catalogue rows, one of each kind: a new system role must not touch this file.
	var catalogue []any
	for _, r := range list["roles"].([]any) {
		if id := r.(map[string]any)["id"]; id == rbac.BizOwner || id == rbac.Developer {
			catalogue = append(catalogue, r)
		}
	}
	answers["list_roles"] = memberRolesAnswer{Status: code, Body: catalogue}

	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode(answers); err != nil {
		t.Fatal(err)
	}
	if *updateMemberRolesAnswers {
		if err := os.WriteFile(memberRolesAnswersGolden, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(memberRolesAnswersGolden)
	if err != nil {
		t.Fatalf("%v (run with -update-member-roles-answers)", err)
	}
	if !bytes.Equal(want, buf.Bytes()) {
		t.Fatalf("the hub's member role answers changed; the web client reads %s:\n%s", memberRolesAnswersGolden, buf.String())
	}
}
