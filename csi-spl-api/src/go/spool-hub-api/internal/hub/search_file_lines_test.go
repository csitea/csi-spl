package hub_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 160 row B4 (SPL-3888): in:file-streams searches the box file stream
// lines, for the workspace's owner or admins only, and the answer carries
// notices. Red on origin/master before B4: in:file-streams was the channel
// named file-streams (no file_lines group) and the answer had no notices.
//
//	go test ./internal/hub -run SearchFileLines -v   (lines: SPOOL_TEST_PG_DSN)

// fsSearchAnswer is the part of GET /v1/view/search this test reads.
type fsSearchAnswer struct {
	Types   []string `json:"types"`
	Notices []string `json:"notices"`
	Groups  map[string]struct {
		Results []struct {
			StreamKey string `json:"stream_key"`
			BoxID     string `json:"box_id"`
			Seq       int64  `json:"seq"`
			Text      string `json:"text"`
		} `json:"results"`
	} `json:"groups"`
}

// fsSearch is the answer of q for as in tenant tid; the status must be 200.
func fsSearch(t *testing.T, r *fsRig, tid, q, as string) fsSearchAnswer {
	t.Helper()
	code, body := get(t, r.e, tid, "/v1/view/search?q="+url.QueryEscape(q), as)
	if code != http.StatusOK {
		t.Fatalf("search %q as %s = %d %s, want 200", q, as, code, body)
	}
	var out fsSearchAnswer
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("search body %s: %v", body, err)
	}
	if out.Notices == nil {
		t.Fatalf("search %q: notices missing from %s (always present, [] when empty)", q, body)
	}
	return out
}

// fsSearchRig is fsRig where box-a of W streams 3 lines into "app" carrying
// the word word, and box-a of W2 a line carrying word too.
func fsSearchRig(t *testing.T, word string) *fsRig {
	t.Helper()
	r := newFSRig(t, store.FileStreamLimits{}, func(o *hub.Options) { o.SearchRatePerMin = 1000 })
	now := time.Now().UTC()
	push := func(b *box, texts ...string) {
		t.Helper()
		if _, err := r.lane(t, b, wire.FileStreamsAnnounceOp, fsAnnounce("app")); err != nil {
			t.Fatal(err)
		}
		parts := make([]string, len(texts))
		for i, s := range texts {
			parts[i] = fmt.Sprintf(`{"seq":%d,"at":%q,"text":%q,"marker":false}`, i+1, now.Format(time.RFC3339), s)
		}
		body := `{"stream_key":"app","lines":[` + strings.Join(parts, ",") + `],"dropped":0,"redactions":{}}`
		if _, err := r.lane(t, b, wire.FileStreamsPushOp, body); err != nil {
			t.Fatal(err)
		}
	}
	push(r.a, "deploy "+word+" failed", "a quiet line", "retry "+word+" ok")
	push(r.a2, "the other workspace's "+word)
	return r
}

// TestSearchFileLinesNotices (case C16, any store): a member's
// in:file-streams is 200 with no line and notices [file_streams_staff_only];
// the owner's carries no notice, nor does a plain search. CONTROL: the
// owner's answer has the file_lines group the member's lacks lines in.
func TestSearchFileLinesNotices(t *testing.T) {
	r := fsSearchRig(t, "zqnotice")
	owner, dev := seat(t, r.e, r.w, rbac.BizOwner), seat(t, r.e, r.w, rbac.Developer)
	m := fsSearch(t, r, r.w, "in:file-streams zqnotice", dev)
	if !slices.Equal(m.Notices, []string{"file_streams_staff_only"}) || len(m.Groups["file_lines"].Results) != 0 {
		t.Fatalf("member: %+v, want no line and notices [file_streams_staff_only]", m)
	}
	if !slices.Equal(m.Types, []string{"file_line"}) {
		t.Fatalf("member types = %v, want [file_line]", m.Types)
	}
	if o := fsSearch(t, r, r.w, "in:file-streams zqnotice", owner); len(o.Notices) != 0 {
		t.Fatalf("owner notices = %v, want []", o.Notices)
	}
	if p := fsSearch(t, r, r.w, "zqnotice", dev); len(p.Notices) != 0 || slices.Contains(p.Types, "file_line") {
		t.Fatalf("plain search: types %v notices %v, want no file_line and []", p.Types, p.Notices)
	}
}

// TestSearchFileLines (cases C14, C15, C17, Postgres): the owner's and an
// admin's in:file-streams <word> finds W's lines with the word, newest
// first, never W2's; channel:file-streams is the same; a plain search of the
// word finds no line; box: and name: narrow it.
func TestSearchFileLines(t *testing.T) {
	r := fsSearchRig(t, "zqline")
	if _, ok := r.e.st.(store.FileLineSearcher); !ok {
		t.Skip("the file_line section is Postgres only (SPOOL_TEST_PG_DSN)")
	}
	owner, admin := seat(t, r.e, r.w, rbac.BizOwner), seat(t, r.e, r.w, rbac.Admin)
	texts := func(a fsSearchAnswer) []string {
		out := []string{}
		for _, l := range a.Groups["file_lines"].Results {
			out = append(out, l.Text)
		}
		return out
	}
	for _, as := range []string{owner, admin} {
		for _, q := range []string{"in:file-streams zqline", "channel:file-streams zqline"} {
			got := texts(fsSearch(t, r, r.w, q, as))
			if !slices.Equal(got, []string{"retry zqline ok", "deploy zqline failed"}) {
				t.Errorf("%s %q = %q, want W's two lines, newest first (C14, C17)", as, q, got)
			}
		}
	}
	if p := fsSearch(t, r, r.w, "zqline", owner); slices.Contains(p.Types, "file_line") || len(p.Groups["file_lines"].Results) != 0 {
		t.Errorf("plain search = %+v, want no file line (C15)", p)
	}
	if got := texts(fsSearch(t, r, r.w, "in:file-streams zqline box:box-b", owner)); len(got) != 0 {
		t.Errorf("box:box-b = %q, want none", got)
	}
	if got := texts(fsSearch(t, r, r.w, "in:file-streams name:ap deploy", owner)); !slices.Equal(got, []string{"deploy zqline failed"}) {
		t.Errorf("name:ap deploy = %q, want the deploy line", got)
	}
	if got := texts(fsSearch(t, r, r.w2, "in:file-streams zqline", seat(t, r.e, r.w2, rbac.BizOwner))); !slices.Equal(got, []string{"the other workspace's zqline"}) {
		t.Errorf("W2's owner = %q, want only W2's line (C17 control: the word is in both)", got)
	}
}

// TestSearchFileLinesChannelOfThatName (case C14): in:#file-streams is the
// channel named file-streams, never the stream lines.
func TestSearchFileLinesChannelOfThatName(t *testing.T) {
	r := fsSearchRig(t, "zqchan")
	owner := seat(t, r.e, r.w, rbac.BizOwner)
	for _, q := range []string{"in:#file-streams zqchan", "channel:#file-streams zqchan"} {
		a := fsSearch(t, r, r.w, q, owner)
		if slices.Contains(a.Types, "file_line") || len(a.Groups["file_lines"].Results) != 0 {
			t.Errorf("%q: types %v, want the channel's sections, no file_line", q, a.Types)
		}
	}
}
