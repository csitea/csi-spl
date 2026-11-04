package hub_test

import (
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// SPL-4789 (owner HUM-10, t1 ef94396b msg 61bf7791): a release note links
// every issue its message cites and that issue's discussions, in the
// workspace that owns the issues; the gate's operator check answers per key.

// linksEnv is releaseEnv whose session seam is per workspace, as on the real
// hub: member[hum] lists the workspaces hum may sign in to.
func linksEnv(t *testing.T) (*env, map[string][]string) {
	t.Helper()
	member := map[string][]string{}
	e, _, _ := releaseEnv(t, func(o *hub.Options) {
		o.SessionID = func(r *http.Request, tenant string) (string, error) {
			hum := r.Header.Get(memberHeader)
			for _, t := range member[hum] {
				if t == tenant {
					return hum, nil
				}
			}
			return "", errors.New("no session")
		}
	})
	return e, member
}

// ownerIssue files one issue in owner linked to a fresh #lobby topic and
// answers its key and the topic id.
func ownerIssue(t *testing.T, e *env, owner, dev string) (string, string) {
	t.Helper()
	talk := uid.New()
	lobbyTopic(t, e, owner, talk, "## Where the work came from\n\nthe ask")
	code, out := call(t, e, owner, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "the work", "discussions": []string{talk}})
	if code != http.StatusCreated {
		t.Fatalf("create issue: %d %v", code, out)
	}
	return issueOf(t, out)["key"].(string), talk
}

func ingestFor(t *testing.T, e *env, tid, issueTenant string, rows ...map[string]any) (int, map[string]any) {
	t.Helper()
	return opCall(t, e, tid, http.MethodPost, "/v1/operator/release-notes", "good",
		map[string]any{"notes": rows, "issue_tenant": issueTenant})
}

func commitIssues(t *testing.T, e *env, tid, as string, day time.Time) []map[string]any {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/reporting/releases/commits?from="+day.Format(time.DateOnly)+"&to="+day.Format(time.DateOnly), as, nil)
	if code != http.StatusOK || len(out["notes"].([]any)) != 1 {
		t.Fatalf("commits: %d %v", code, out)
	}
	raw := out["notes"].([]any)[0].(map[string]any)["issues"].([]any)
	is := make([]map[string]any, len(raw))
	for k, v := range raw {
		is[k] = v.(map[string]any)
	}
	return is
}

func TestReleaseLinksMemberAndStranger(t *testing.T) {
	e, member := linksEnv(t)
	owner, _ := e.tenant()
	viewer, _ := e.tenant()
	dev := seat(t, e, owner, rbac.Developer)
	inViewer := seat(t, e, viewer, rbac.Developer)
	member[dev] = []string{owner}
	member[inViewer] = []string{viewer}
	key, talk := ownerIssue(t, e, owner, dev)
	n := strings.TrimPrefix(key, strings.Split(key, "-")[0]+"-")
	prefix := strings.TrimSuffix(key, "-"+n)

	day := reportDay(t)
	sha := reportSHA(t)
	msg := "feat(wui, " + key + "): the links\n\nCloses: " + key + "\nRefs: " + prefix + "-99999, HUM-10, UTF-8, x" + key + "x"
	if code, out := ingestFor(t, e, owner, owner, reportRow(sha, "", msg, day.Add(time.Hour))); code != http.StatusOK || out["stored"].(float64) != 1 {
		t.Fatalf("ingest: %d %v", code, out)
	}

	// A member of the owning workspace: the key, the missing key, and the
	// discussion with its title.
	is := commitIssues(t, e, owner, dev, day)
	if len(is) != 2 || is[0]["key"] != key || is[1]["key"] != prefix+"-99999" {
		t.Fatalf("keys: %v", is)
	}
	ds := is[0]["discussions"].([]any)
	d0 := ds[0].(map[string]any)
	if is[0]["found"] != true || is[0]["tenant"] != owner || len(ds) != 1 || d0["task_id"] != talk ||
		d0["title"] != "Where the work came from" || d0["can_open"] != true {
		t.Fatalf("member's link: %v", is[0])
	}
	if is[1]["found"] != false || len(is[1]["discussions"].([]any)) != 0 {
		t.Fatalf("missing key: %v", is[1])
	}

	// A stranger to the owning workspace: the key and the count, never the
	// topic id or its title.
	is = commitIssues(t, e, viewer, inViewer, day)
	d0 = is[0]["discussions"].([]any)[0].(map[string]any)
	if is[0]["found"] != true || is[0]["member"] != false || d0["can_open"] != false || d0["task_id"] != nil || d0["title"] != nil {
		t.Fatalf("stranger's link: %v", is[0])
	}

	// /v1/release-notes/<sha> carries the same links.
	if note := noteOf(t, e, owner, dev, sha[:10]); len(note["issues"].([]any)) != 2 {
		t.Fatalf("release note page: %v", note)
	}

	// A re-ingest that names no issue workspace keeps the stored keys.
	if code, _ := ingest(t, e, owner, reportRow(sha, "", "feat(wui): no keys now", day.Add(time.Hour))); code != http.StatusOK {
		t.Fatal("re-ingest")
	}
	if is = commitIssues(t, e, owner, dev, day); len(is) != 2 {
		t.Fatalf("after a re-ingest without issue_tenant: %v", is)
	}
}

func TestReleaseLinksRefusals(t *testing.T) {
	e, _ := linksEnv(t)
	tid, _ := e.tenant()
	// CONTROL: an issue workspace this hub does not have is a 400, not
	// keys stored for nobody.
	code, out := ingestFor(t, e, tid, "no-such-ws", reportRow(reportSHA(t), "", "feat(x, SPL-1): y", reportDay(t)))
	if code != http.StatusBadRequest {
		t.Fatalf("unknown issue_tenant: %d %v", code, out)
	}
	// A commit naming no key answers an empty list, never null.
	day := reportDay(t)
	if code, out := ingestFor(t, e, tid, tid, reportRow(reportSHA(t), "", "chore: nothing cited", day)); code != http.StatusOK {
		t.Fatalf("ingest: %d %v", code, out)
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/reporting/releases/commits?from="+day.Format(time.DateOnly)+"&to="+day.Format(time.DateOnly), "", nil)
	if code == http.StatusOK {
		t.Fatalf("no session must not read the report: %v", out)
	}
}

func TestCommitLinksOperatorCheck(t *testing.T) {
	e, member := linksEnv(t)
	owner, _ := e.tenant()
	dev := seat(t, e, owner, rbac.Developer)
	member[dev] = []string{owner}
	key, _ := ownerIssue(t, e, owner, dev)
	// An issue that only links the workspace's default discussion (the
	// backlog every issue falls back to) has no discussion it came from.
	code, out := call(t, e, owner, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "backlog only"})
	if code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	backlog := issueOf(t, out)["key"].(string)
	prefix := key[:strings.LastIndexByte(key, '-')]

	code, out = opCall(t, e, owner, http.MethodPost, "/v1/operator/commit-links", "good",
		map[string]any{"tenant": owner, "keys": []string{key, backlog, prefix + "-99999"}})
	if code != http.StatusOK {
		t.Fatalf("check: %d %v", code, out)
	}
	ks := out["keys"].([]any)
	want := []struct {
		found bool
		n     float64
		def   bool
	}{{true, 1, false}, {true, 0, true}, {false, 0, false}}
	for k, w := range want {
		j := ks[k].(map[string]any)
		if j["found"] != w.found || j["discussions"] != w.n || j["default_only"] != w.def {
			t.Errorf("key %d %v, want %+v", k, j, w)
		}
	}
	// CONTROLS: a bad operator token; a member is not an operator, by its
	// session or as a bearer; bad bodies.
	req := map[string]any{"tenant": owner, "keys": []string{key}}
	if code, _ := opCall(t, e, owner, http.MethodPost, "/v1/operator/commit-links", "bad", req); code != http.StatusUnauthorized && code != http.StatusForbidden {
		t.Errorf("bad token: %d", code)
	}
	if code, out := call(t, e, owner, http.MethodPost, "/v1/operator/commit-links", dev, req); code != http.StatusUnauthorized || out["error"] != "no_token" {
		t.Errorf("member session: %d %v, want 401 no_token", code, out)
	}
	if code, out := opCall(t, e, owner, http.MethodPost, "/v1/operator/commit-links", dev, req); code != http.StatusUnauthorized || out["error"] != "bad_token" {
		t.Errorf("member bearer: %d %v, want 401 bad_token", code, out)
	}
	for _, body := range []map[string]any{{"tenant": owner}, {"keys": []string{key}}, {"tenant": "no-such-ws", "keys": []string{key}}} {
		if code, _ := opCall(t, e, owner, http.MethodPost, "/v1/operator/commit-links", "good", body); code == http.StatusOK {
			t.Errorf("body %v: 200", body)
		}
	}
}
