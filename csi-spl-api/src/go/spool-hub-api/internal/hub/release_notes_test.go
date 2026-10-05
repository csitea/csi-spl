package hub_test

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 065 L4: the operator ingest and the member reads of the release notes.

// releaseEnv is rbacEnv with the operator seam ("good" = the env SA), a tenant
// and a seated member.
func releaseEnv(t *testing.T) (*env, string, string) {
	t.Helper()
	e := rbacEnv(t, func(o *hub.Options) {
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			if token == "good" {
				return operatorSA, nil
			}
			return "", errors.New("token rejected")
		}
	})
	tid, _ := e.tenant()
	return e, tid, seat(t, e, tid, rbac.Developer)
}

func releaseSHA(c string) string { return strings.Repeat(c, 40) }

const releaseFullMsg = `fix(wui): the unread badge stays after a channel is read

Body text.

Lay-What: The red dot now disappears once you have read a channel.
Lay-How: The app tells the server you read it, the moment you open it.
Lay-Why: You saw a dot for messages you had already read.
Tech-What: WUI marks the channel read on open.
Tech-How: ChannelView calls the read route on mount.
Tech-Why: The read call was only sent on scroll-to-bottom.`

func ingest(t *testing.T, e *env, tid string, notes ...map[string]any) (int, map[string]any) {
	t.Helper()
	return opCall(t, e, tid, http.MethodPost, "/v1/operator/release-notes", "good", map[string]any{"notes": notes})
}

func releaseRow(sha, version, msg string) map[string]any {
	return map[string]any{"sha": sha, "version": version, "committed_at": "2026-10-03T08:00:00Z",
		"message": msg, "area": "csi-spl-wui", "link": "https://git.example/commit/" + sha}
}

func noteOf(t *testing.T, e *env, tid, as, ref string) map[string]any {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/release-notes/"+ref, as, nil)
	if code != http.StatusOK {
		t.Fatalf("GET note %s: %d %v", ref, code, out)
	}
	return out["note"].(map[string]any)
}

func TestReleaseNotesIngestAndRead(t *testing.T) {
	e, tid, hum := releaseEnv(t)
	code, out := ingest(t, e, tid,
		releaseRow(releaseSHA("a"), "v7.4.1", releaseFullMsg),
		releaseRow(releaseSHA("b"), "v7.4.2", "chore: bump the baseline\n\nRelease-Note: skip\nLay-Why: Housekeeping."),
		releaseRow(releaseSHA("c"), "v7.4.2", "docs(help): explain notes\n\nLay-What: A new help page.\nLay-Why: Agents need the rule."),
		releaseRow(releaseSHA("d"), "v7.4.10", "feat(hub): no trailers at all"),
		releaseRow(releaseSHA("e"), "v7.4.10", "Revert \"fix(wui): x\"\n\nThis reverts commit "+releaseSHA("a")+"."),
		releaseRow("not-a-sha", "v7.4.10", releaseFullMsg),
	)
	if code != http.StatusOK || out["stored"].(float64) != 5 {
		t.Fatalf("ingest: %d %v", code, out)
	}
	if rej := out["rejected"].([]any); len(rej) != 1 || rej[0].(map[string]any)["sha"] != "not-a-sha" {
		t.Fatalf("rejected: %v", rej)
	}
	n := noteOf(t, e, tid, hum, releaseSHA("a")[:7])
	if n["state"] != "ok" || n["kind"] != "fix" || n["area"] != "wui" || n["version"] != "v7.4.1" ||
		n["tech_why"] != "The read call was only sent on scroll-to-bottom." {
		t.Fatalf("full note: %v", n)
	}
	want := map[string]string{"b": "skip", "c": "missing", "d": "missing", "e": "revert"}
	for c, st := range want {
		if got := noteOf(t, e, tid, hum, releaseSHA(c)); got["state"] != st {
			t.Fatalf("%s: state %v, want %s", c, got["state"], st)
		}
	}
	if got := noteOf(t, e, tid, hum, releaseSHA("e")); got["reverts"] != releaseSHA("a") {
		t.Fatalf("revert link: %v", got)
	}

	// doc-only (spec 5.2): Lay-What + Lay-Why suffice; a 6.1 note wins over
	// the message; an explicit backfill state is kept.
	row := releaseRow(releaseSHA("c"), "v7.4.2", "docs(help): explain notes\n\nLay-What: A new help page.\nLay-Why: Agents need the rule.")
	row["doc_only"] = true
	fix := releaseRow(releaseSHA("d"), "v7.4.10", "feat(hub): no trailers at all")
	fix["note"] = strings.SplitN(releaseFullMsg, "\n\n", 3)[2]
	back := releaseRow(releaseSHA("f"), "v7.4.10", "perf(hub): old commit")
	back["state"], back["lay_what"] = "backfill", "Pages open faster."
	if code, out := ingest(t, e, tid, row, fix, back); code != http.StatusOK || out["stored"].(float64) != 3 {
		t.Fatalf("re-ingest: %d %v", code, out)
	}
	for c, st := range map[string]string{"c": "ok", "d": "ok", "f": "backfill"} {
		if got := noteOf(t, e, tid, hum, releaseSHA(c)); got["state"] != st {
			t.Fatalf("%s: state %v, want %s", c, got["state"], st)
		}
	}

	// The list: versions newest first (v7.4.10 > v7.4.2, numeric), paged.
	code, out = call(t, e, tid, http.MethodGet, "/v1/release-notes?limit=2&before=v7.5.0", hum, nil)
	vs := out["versions"].([]any)
	if code != http.StatusOK || len(vs) != 2 || vs[0].(map[string]any)["version"] != "v7.4.10" ||
		len(vs[0].(map[string]any)["notes"].([]any)) != 3 || out["next_before"] != "v7.4.2" {
		t.Fatalf("list page 1: %d %v", code, out)
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/release-notes?before=v7.4.2", hum, nil)
	vs = out["versions"].([]any)
	if code != http.StatusOK || len(vs) != 1 || vs[0].(map[string]any)["version"] != "v7.4.1" || out["next_before"] != "" {
		t.Fatalf("list page 2: %d %v", code, out)
	}
	// the rolling # (t1 55b6de46): the oldest change is 1, the newest of the six is 6
	if seq := vs[0].(map[string]any)["notes"].([]any)[0].(map[string]any)["seq"]; seq != float64(1) {
		t.Fatalf("oldest seq: %v", seq)
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/release-notes/v7.4.2", hum, nil)
	if code != http.StatusOK || len(out["notes"].([]any)) != 2 {
		t.Fatalf("version: %d %v", code, out)
	}
	if seq := out["notes"].([]any)[0].(map[string]any)["seq"]; seq != float64(3) {
		t.Fatalf("version seq: %v", seq)
	}
}

// The 9.9.9 wrap (owner t1 1c5b6d53): cycle 2's tag v<X.Y.Z>-c2 and cycle
// 1's v<X.Y.Z> are two groups keyed by the full tag, cycle 2 first even after
// cycle 1's v<X>.9.9, and each shows the plain v<X.Y.Z> (t1 e82eea7c). The
// table is estate-wide and Postgres runs share it, so the rows have their own
// shas and major 8, and every list starts below v8.0.2-c2.
func TestReleaseNotesCycleTwoSameVersion(t *testing.T) {
	e, tid, hum := releaseEnv(t)
	code, out := ingest(t, e, tid,
		releaseRow(releaseSHA("2"), "v8.0.1", releaseFullMsg),
		releaseRow(releaseSHA("3"), "v8.9.9", releaseFullMsg),
		releaseRow(releaseSHA("4"), "v8.0.1-c2", releaseFullMsg),
		releaseRow(releaseSHA("5"), "v8.0.1-c1", releaseFullMsg),
	)
	if code != http.StatusOK || out["stored"].(float64) != 3 {
		t.Fatalf("ingest: %d %v", code, out)
	}
	if rej := out["rejected"].([]any); len(rej) != 1 || rej[0].(map[string]any)["sha"] != releaseSHA("5") {
		t.Fatalf("a -c1 tag must be refused (cycle 1 has no suffix): %v", rej)
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/release-notes?limit=3&before=v8.0.2-c2", hum, nil)
	vs := out["versions"].([]any)
	if code != http.StatusOK || len(vs) != 3 {
		t.Fatalf("list: %d %v", code, out)
	}
	for i, want := range [][2]string{{"v8.0.1-c2", "v8.0.1"}, {"v8.9.9", "v8.9.9"}, {"v8.0.1", "v8.0.1"}} {
		v := vs[i].(map[string]any)
		if v["version"] != want[0] || v["display"] != want[1] || len(v["notes"].([]any)) != 1 {
			t.Fatalf("group %d: %v, want key %s display %s", i, v, want[0], want[1])
		}
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/release-notes?limit=1&before=v8.0.1-c2", hum, nil)
	if vs = out["versions"].([]any); code != http.StatusOK || len(vs) != 1 || vs[0].(map[string]any)["version"] != "v8.9.9" {
		t.Fatalf("page below cycle 2: %d %v", code, out)
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/release-notes/v8.0.1-c2", hum, nil)
	if notes, _ := out["notes"].([]any); code != http.StatusOK || out["display"] != "v8.0.1" || len(notes) != 1 ||
		notes[0].(map[string]any)["sha"] != releaseSHA("4") {
		t.Fatalf("cycle-2 version: %d %v", code, out)
	}
}

// The hygiene filter (spec 3, option C): a banned name configured through the
// environment, a mail address and a home directory never reach a stored row.
func TestReleaseNotesHygieneFilterDropsBannedName(t *testing.T) {
	t.Setenv(hub.ReleaseNoteBansEnv, "(?i)\\bjane doe\\b\n(?i)\\bbox-zz9\\b\n([unclosed")
	e, tid, hum := releaseEnv(t)
	// A synthetic home directory, joined at run time: the hygiene sweep reads
	// this file and refuses the literal form.
	home := strings.Join([]string{"", "home", "someone", "x"}, "/")
	msg := "fix(hub): thanks Jane Doe\n\n" +
		"Lay-What: Jane Doe found it on box-zz9.\n" +
		"Lay-How: Mail first.last@example.com for details.\n" +
		"Lay-Why: The log under " + home + " said so.\n" +
		"Tech-What: x\nTech-How: y\nTech-Why: z"
	code, out := ingest(t, e, tid, releaseRow(releaseSHA("1"), "v1.0.0", msg))
	if code != http.StatusOK || out["redacted"].(float64) != 1 || out["stored"].(float64) != 1 {
		t.Fatalf("ingest: %d %v", code, out)
	}
	n := noteOf(t, e, tid, hum, releaseSHA("1"))
	for _, f := range []string{"subject", "lay_what", "lay_how", "lay_why"} {
		v := n[f].(string)
		if strings.Contains(strings.ToLower(v), "jane") || strings.Contains(v, "box-zz9") ||
			strings.Contains(v, "@example.com") || strings.Contains(v, "/home/") || !strings.Contains(v, "[redacted]") {
			t.Fatalf("%s not filtered: %q", f, v)
		}
	}
	if n["state"] != "ok" {
		t.Fatalf("a redacted note keeps its state: %v", n)
	}
}

// CONTROLS: a read needs a member session, the ingest an operator token.
func TestReleaseNotesAuth(t *testing.T) {
	e, tid, hum := releaseEnv(t)
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/release-notes", "", nil); code != http.StatusForbidden && code != http.StatusUnauthorized {
		t.Fatalf("anonymous list: %d", code)
	}
	if code, _ := opCall(t, e, tid, http.MethodPost, "/v1/operator/release-notes", "", map[string]any{"notes": []any{}}); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", code)
	}
	if code, _ := opCall(t, e, tid, http.MethodPost, "/v1/operator/release-notes", "bad", map[string]any{"notes": []any{}}); code != http.StatusUnauthorized {
		t.Fatalf("bad token: %d", code)
	}
	// A member session is not an operator: the ingest refuses it.
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/operator/release-notes", hum, map[string]any{"notes": []any{}}); code != http.StatusUnauthorized {
		t.Fatalf("member ingest: %d", code)
	}
	for path, want := range map[string]int{
		"/v1/release-notes?limit=0":            http.StatusBadRequest,
		"/v1/release-notes?before=x":           http.StatusBadRequest,
		"/v1/release-notes/zz":                 http.StatusBadRequest,
		"/v1/release-notes/" + releaseSHA("9"): http.StatusNotFound,
		"/v1/release-notes/v9.9.9":             http.StatusNotFound,
	} {
		if code, out := call(t, e, tid, http.MethodGet, path, hum, nil); code != want {
			t.Fatalf("%s: %d %v, want %d", path, code, out, want)
		}
	}
}
