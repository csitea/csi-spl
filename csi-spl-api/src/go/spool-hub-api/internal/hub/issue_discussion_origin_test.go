package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

const originTitle = "Origin topic title"

// originFix is an issue of workspace ta whose topic "origin" lives in tb:
// dev is a member of ta only, both of ta and tb.
type originFix struct {
	e              *env
	ta, tb, origin string
	dev, both, key string
}

func originSetup(t *testing.T) originFix {
	t.Helper()
	e, member := linksEnv(t)
	ta, _ := e.tenant()
	tb, _ := e.tenant()
	f := originFix{e: e, ta: ta, tb: tb, origin: uid.New(), dev: seat(t, e, ta, rbac.Developer), both: seat(t, e, ta, rbac.Developer)}
	member[f.dev] = []string{ta}
	member[f.both] = []string{ta, tb}
	own := uid.New()
	lobbyTopic(t, e, ta, own, "## Own topic")
	lobbyTopic(t, e, tb, f.origin, "## "+originTitle)
	code, out := call(t, e, ta, http.MethodPost, "/v1/issues", f.dev, map[string]any{
		"title": "origin elsewhere", "discussions": []string{own}})
	if code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	f.key = issueOf(t, out)["key"].(string)
	return f
}

func (f originFix) link(t *testing.T, task string) {
	t.Helper()
	code, out := opCall(t, f.e, f.ta, http.MethodPost, "/v1/operator/issues/"+f.key+"/origin-discussion", "good", map[string]any{
		"tenant": f.ta, "origin_tenant": f.tb, "discussion": task})
	if code != http.StatusOK || out["added"] != true {
		t.Fatalf("operator route: %d %v", code, out)
	}
	if raw, _ := json.Marshal(out); strings.Contains(string(raw), f.tb) || strings.Contains(string(raw), task) {
		t.Fatalf("the operator route's answer names the origin: %s", raw)
	}
}

// opaque fails when v names the origin in any way, and when it carries no
// members-only entry at all (a control on the shape read).
func (f originFix) opaque(t *testing.T, what string, v any) {
	t.Helper()
	raw, _ := json.Marshal(v)
	for _, leak := range []string{f.origin, f.tb, originTitle, `"linked_by":"operator"`} {
		if strings.Contains(string(raw), leak) {
			t.Fatalf("%s names the origin (%s): %s", what, leak, raw)
		}
	}
	if !strings.Contains(string(raw), `"members_only":true`) {
		t.Fatalf("%s has no opaque entry: %s", what, raw)
	}
}

// SPL-5126 step 1: a topic of another workspace is refused as an origin
// through the member route, and the operator route links it.
func TestIssueOriginInAnotherWorkspace(t *testing.T) {
	f := originSetup(t)
	code, out := call(t, f.e, f.ta, http.MethodPost, "/v1/issues/"+f.key+"/discussions", f.dev, map[string]any{"discussion": f.origin})
	if code != http.StatusBadRequest || out["error"] != "unknown_discussion" {
		t.Fatalf("member route, topic of another workspace: %d %v", code, out)
	}
	f.link(t, f.origin)
	// A topic the origin workspace does not have is refused.
	code, out = opCall(t, f.e, f.ta, http.MethodPost, "/v1/operator/issues/"+f.key+"/origin-discussion", "good", map[string]any{
		"tenant": f.ta, "origin_tenant": f.tb, "discussion": uid.New()})
	if code != http.StatusBadRequest || out["error"] != "unknown_discussion" {
		t.Fatalf("no such origin topic: %d %v", code, out)
	}
	// Operator auth only.
	code, _ = opCall(t, f.e, f.ta, http.MethodPost, "/v1/operator/issues/"+f.key+"/origin-discussion", "bad", map[string]any{
		"tenant": f.ta, "origin_tenant": f.tb, "discussion": f.origin})
	if code != http.StatusUnauthorized && code != http.StatusForbidden {
		t.Fatalf("a bad token: %d", code)
	}
}

func TestIssueOriginOpaqueInList(t *testing.T) {
	f := originSetup(t)
	f.link(t, f.origin)
	_, out := call(t, f.e, f.ta, http.MethodGet, "/v1/view/issues", f.dev, nil)
	f.opaque(t, "list", out)
}

func TestIssueOriginOpaqueInFanout(t *testing.T) {
	f := originSetup(t)
	ws := dialMember(t, f.e, f.ta, "", f.dev)
	f.link(t, f.origin)
	f.opaque(t, "fan-out", readFrame(t, ws, "issue"))
}

func TestIssueOriginSingleRead(t *testing.T) {
	f := originSetup(t)
	f.link(t, f.origin)
	_, out := call(t, f.e, f.ta, http.MethodGet, "/v1/view/issues/"+f.key, f.dev, nil)
	f.opaque(t, "single read, no access", out)
	// The control: a member of the origin workspace gets all of it.
	_, out = call(t, f.e, f.ta, http.MethodGet, "/v1/view/issues/"+f.key, f.both, nil)
	raw, _ := json.Marshal(out)
	for _, want := range []string{f.origin, `"workspace":"` + f.tb + `"`, originTitle} {
		if !strings.Contains(string(raw), want) {
			t.Fatalf("single read with access lacks %s: %s", want, raw)
		}
	}
}

func TestIssueOriginDeletedReadsGone(t *testing.T) {
	f := originSetup(t)
	f.link(t, f.origin)
	if err := f.e.st.(store.MessageEdits).DeleteMessage(context.Background(), f.tb, f.origin); err != nil {
		t.Fatal(err)
	}
	for _, as := range []string{f.dev, f.both} {
		_, out := call(t, f.e, f.ta, http.MethodGet, "/v1/view/issues/"+f.key, as, nil)
		raw, _ := json.Marshal(out)
		if !strings.Contains(string(raw), `"state":"gone"`) || strings.Contains(string(raw), f.origin) {
			t.Fatalf("deleted origin topic: %s", raw)
		}
	}
}

// A member cannot remove a link it is not shown.
func TestIssueOriginMemberCannotUnlink(t *testing.T) {
	f := originSetup(t)
	f.link(t, f.origin)
	code, out := call(t, f.e, f.ta, http.MethodDelete, "/v1/issues/"+f.key+"/discussions/"+f.origin, f.both, nil)
	if code != http.StatusNotFound {
		t.Fatalf("unlink a foreign link: %d %v", code, out)
	}
}

func TestIssueOriginCountsInCommitLinks(t *testing.T) {
	f := originSetup(t)
	// Only the tenant's default and the foreign link, so the foreign link
	// alone decides relay_hash_only. A version-5 shape: a foreign link is
	// never counted as a relay hash.
	code, out := call(t, f.e, f.ta, http.MethodPost, "/v1/issues", f.dev, map[string]any{"title": "default only"})
	if code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	f.key = issueOf(t, out)["key"].(string)
	f.origin = "aaaaaaaa-bbbb-5ccc-8ddd-eeeeeeeeeeee"
	lobbyTopic(t, f.e, f.tb, f.origin, "## v5 shaped topic")
	f.link(t, f.origin)
	code, out = opCall(t, f.e, f.ta, http.MethodPost, "/v1/operator/commit-links", "good", map[string]any{"tenant": f.ta, "keys": []string{f.key}})
	k := out["keys"].([]any)[0].(map[string]any)
	if code != http.StatusOK || k["discussions"] != float64(1) || k["default_only"] != false || k["relay_hash_only"] != false {
		t.Fatalf("commit links: %d %v", code, out)
	}
}

func TestIssueOriginInReleaseLinks(t *testing.T) {
	f := originSetup(t)
	registerRepo(t, f.e, f.ta, repoOf(f.ta, "main"), true)
	f.link(t, f.origin)
	day := reportDay(t)
	msg := "feat(wui, " + f.key + "): the links\n\nCloses: " + f.key
	if code, out := ingestFor(t, f.e, f.ta, f.ta, reportRow(reportSHA(t), "", msg, day.Add(1))); code != http.StatusOK {
		t.Fatalf("ingest: %d %v", code, out)
	}
	raw, _ := json.Marshal(commitIssues(t, f.e, f.ta, f.dev, day))
	if strings.Contains(string(raw), f.origin) || strings.Contains(string(raw), f.tb) || strings.Contains(string(raw), originTitle) {
		t.Fatalf("release link, no access: %s", raw)
	}
	raw, _ = json.Marshal(commitIssues(t, f.e, f.ta, f.both, day))
	for _, want := range []string{f.origin, `"workspace":"` + f.tb + `"`, `"can_open":true`} {
		if !strings.Contains(string(raw), want) {
			t.Fatalf("release link with access lacks %s: %s", want, raw)
		}
	}
}
