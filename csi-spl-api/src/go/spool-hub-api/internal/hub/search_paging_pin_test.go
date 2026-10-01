package hub_test

import (
	"context"
	"crypto/ed25519"
	"fmt"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// TestSearchPagingWalksEverySection pins the cursor of each section kind
// (message keyset, message relevance offset, topic keyset, file keyset with
// the file index, entity offset): walking limit=1 pages returns exactly the
// unpaged list, in order. Recorded before searchSection was split per type
// (SPL-1029 round 2).
func TestSearchPagingWalksEverySection(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.SearchRatePerMin = 10000
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) { return "", nil }
	})
	ctx := context.Background()
	ta, _ := e.tenant()
	at := fixtureAt()
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.PutPin(ctx, ta, "box-a", pub, false, at, at); err != nil {
		t.Fatal(err)
	}
	e.st.SetRoster(ctx, ta, "box-a", []string{"CLE-01", "CLE-02", "CLE-03"}, at) //nolint:errcheck
	two := `[{"mode":"blob","kind":"file","file_id":"` + strings.Repeat("ab", 32) + `","name":"plan-a.pdf","bytes":1},` +
		`{"mode":"blob","kind":"file","file_id":"` + strings.Repeat("cd", 32) + `","name":"plan-b.pdf","bytes":2}]`
	for i := 0; i < 3; i++ {
		files := ""
		if i < 2 {
			files = two
		}
		putMsg(t, e.st, ta, uuidV4(), "tasks", "CLE-01", "box-a", "CLE-02", fmt.Sprintf("deploy plan step %d deploy", i), at.Add(time.Duration(i)*time.Minute), files)
	}
	ids := func(rows []map[string]any) []string {
		var out []string
		for _, r := range rows {
			out = append(out, fmt.Sprint(r["msg_id"], r["task_id"], r["file_id"], r["id"]))
		}
		return out
	}
	for _, c := range []struct{ q, extra, group string }{
		{"type:message deploy", "", "messages"},
		{"type:message deploy", "&sort=relevance", "messages"},
		{"type:topic deploy", "", "topics"},
		{"type:file plan", "", "files"},
		{"type:robot CLE", "", "robots"},
	} {
		get := func(extra string) searchResp {
			t.Helper()
			code, _, r, _ := searchGet(t, e, ta, c.q, c.extra+extra)
			if code != http.StatusOK {
				t.Fatalf("%q%s: %d", c.q, extra, code)
			}
			return r
		}
		all := ids(get("").Groups[c.group].Results)
		if len(all) < 2 {
			t.Fatalf("%q: only %d rows, the walk proves nothing", c.q, len(all))
		}
		var walked []string
		extra := "&limit=1"
		for n := 0; n < 10; n++ {
			g := get(extra).Groups[c.group]
			walked = append(walked, ids(g.Results)...)
			if g.Next == nil {
				break
			}
			extra = "&limit=1&cursor=" + url.QueryEscape(*g.Next)
		}
		if !reflect.DeepEqual(walked, all) {
			t.Errorf("%q%s: walked %v, want %v", c.q, c.extra, walked, all)
		}
	}
}

// TestSearchGroupedLimit pins the page size of a grouped (several-section)
// search: 5 by default, ?limit when positive, capped at 20.
func TestSearchGroupedLimit(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.SearchRatePerMin = 10000
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) { return "", nil }
	})
	ctx := context.Background()
	ta, _ := e.tenant()
	at := fixtureAt()
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.PutPin(ctx, ta, "box-a", pub, false, at, at); err != nil {
		t.Fatal(err)
	}
	var agents []string
	for i := 0; i < 25; i++ {
		agents = append(agents, fmt.Sprintf("CLE-%02d", i))
	}
	e.st.SetRoster(ctx, ta, "box-a", agents, at) //nolint:errcheck
	for _, c := range []struct {
		extra     string
		n         int
		wantsNext bool
	}{{"", 5, true}, {"&limit=0", 5, true}, {"&limit=x", 5, true}, {"&limit=7", 7, true}, {"&limit=100", 20, true}, {"&limit=25", 20, true}} {
		code, _, r, _ := searchGet(t, e, ta, "type:robot,user CLE", c.extra)
		g := r.Groups["robots"]
		if code != http.StatusOK || len(g.Results) != c.n || (g.Next != nil) != c.wantsNext {
			t.Errorf("%q: %d, %d robots, next %v; want %d", c.extra, code, len(g.Results), g.Next != nil, c.n)
		}
	}
}
