package githubtest_test

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/github/githubtest"
)

// The multi-repo fake (spec 143 releases-projects.md row B-6b): a private
// repo answers its installation's token only, a public one anyone; the
// lists page; Calls records and ResetCalls forgets.
func TestReposFake(t *testing.T) {
	f := githubtest.NewRepos(t)
	f.Put("o/priv", &githubtest.FakeRepo{Installation: "5"})
	f.Push("o/priv", githubtest.FakeCommit{SHA: "c1", Message: "m", At: time.Unix(0, 0), Files: []string{"a/b"}})
	f.Tag("o/priv", "v1", "c1")
	f.Put("o/pub", &githubtest.FakeRepo{Public: true, Releases: []githubtest.FakeRelease{{Tag: "v1"}}})
	get := func(path, auth string) (int, []byte) {
		req, _ := http.NewRequest(http.MethodGet, f.URL+path, nil)
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var raw json.RawMessage
		_ = json.NewDecoder(resp.Body).Decode(&raw)
		return resp.StatusCode, raw
	}
	if code, _ := get("/repos/o/priv/commits", ""); code != http.StatusNotFound {
		t.Fatalf("private repo with no token: %d", code)
	}
	req, _ := http.NewRequest(http.MethodPost, f.URL+"/app/installations/5/access_tokens", nil)
	req.Header.Set("Authorization", "Bearer a.b.c")
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != http.StatusCreated {
		t.Fatalf("token: %v %v", resp, err)
	}
	var tok struct{ Token string }
	_ = json.NewDecoder(resp.Body).Decode(&tok)
	resp.Body.Close()
	for _, p := range []string{"/repos/o/priv/commits?per_page=1&page=1", "/repos/o/priv/commits/c1", "/repos/o/priv/tags", "/repos/o/priv/releases"} {
		if code, _ := get(p, "token "+tok.Token); code != http.StatusOK {
			t.Errorf("%s with the token: %d", p, code)
		}
	}
	if code, _ := get("/repos/o/priv/commits/nosuch", "token "+tok.Token); code != http.StatusNotFound {
		t.Errorf("unknown commit: %d", code)
	}
	if code, body := get("/repos/o/pub/releases", ""); code != http.StatusOK || len(body) < 5 {
		t.Errorf("public releases: %d %s", code, body)
	}
	if len(f.Calls()) == 0 {
		t.Fatal("no calls recorded")
	}
	f.ResetCalls()
	if len(f.Calls()) != 0 {
		t.Fatal("ResetCalls kept calls")
	}
}
