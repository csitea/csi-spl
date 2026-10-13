package hub_test

import (
	"fmt"
	"net/http"
	"testing"
)

// TestWorkspaceDocLazyChildrenUnnumbered (spec 137 T012a): the lazy route's
// parent outline is the store's number, so an unnumbered heading (attrs
// numbered false) neither counts among its siblings nor numbers what is
// under it. Red on the old route, which sent the parent's ord path (B "2",
// C "3", C2 "3.2"); numbered parents keep their numbers.
func TestWorkspaceDocLazyChildrenUnnumbered(t *testing.T) {
	e, tid, as := docTreeEnv(t)
	d := mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "unnumbered"}, 200)
	doc, rev := dtStr(d, "id"), dtNum(d, "rev")
	ids := map[string]string{"root": dtStr(d, "root")}
	off := map[string]any{"numbered": false}
	add := func(name, parent string, attrs any) {
		out := mustCall(t, e, tid, http.MethodPost, docTreeAPI+"/"+doc+"/items", as,
			map[string]any{"rev": rev, "anchor": ids[parent], "where": "child", "title": name, "attrs": attrs}, 200)
		rev, ids[name] = dtNum(out, "rev"), dtStr(out, "item")
	}
	add("A", "root", nil)
	add("B", "root", off)
	add("B1", "B", nil)
	add("C", "root", nil)
	add("C1", "C", off)
	add("C1a", "C1", nil)
	add("C2", "C", nil)
	add("C2a", "C2", nil)
	var got []string
	for _, c := range []struct{ parent, outline, path, items string }{
		{"", "", "[]", "1 A,  B, 2 C"},
		{"B", "", "[2]", " B1"},
		{"C", "2", "[3]", " C1, 2.1 C2"},
		{"C1", "", "[3 1]", " C1a"},
		{"C2", "2.1", "[3 2]", "2.1.1 C2a"},
	} {
		q := ""
		if c.parent != "" {
			q = "?parent=" + ids[c.parent]
		}
		m := mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/"+doc+"/children"+q, as, nil, 200)
		o, p, it := dtStr(m, "outline"), fmt.Sprint(m["path"]), outlines(m)
		if o != c.outline || p != c.path || it != c.items {
			t.Errorf("children of %q: outline %q path %s items %q, want %q %s %q", c.parent, o, p, it, c.outline, c.path, c.items)
		}
		got = append(got, c.parent+"="+o)
	}
	t.Logf("parent outlines: %v", got)
}
