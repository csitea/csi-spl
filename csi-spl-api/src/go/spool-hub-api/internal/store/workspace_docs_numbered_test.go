package store

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

// Spec 137 T012a: an item whose attrs.numbered is false has no outline and
// does not count among its siblings; the items under it have no outline.
// Red on the old reader, which numbered every item by its ord path.

func TestOutlineOfUnnumbered(t *testing.T) {
	for _, c := range []struct {
		path []int32
		want string
	}{{nil, ""}, {[]int32{2, 1}, "2.1"}, {[]int32{0}, ""}, {[]int32{0, 1}, ""}, {[]int32{2, 0}, ""}} {
		if got := outlineOf(c.path); got != c.want {
			t.Errorf("outlineOf(%v) = %q, want %q", c.path, got, c.want)
		}
	}
}

func TestWorkspaceDocUnnumberedOutline(t *testing.T) {
	pg, tid := wsDocPG(t)
	ctx := context.Background()
	doc, root, err := pg.DocCreate(ctx, tid, "unnumbered", "", "t")
	if err != nil {
		t.Fatal(err)
	}
	rev := int64(1)
	add := func(anchor, title, attrs string) string {
		t.Helper()
		res, err := pg.DocItemAdd(ctx, tid, DocItemAddReq{DocID: doc, Rev: rev, Anchor: anchor, Where: DocChild,
			Title: title, Attrs: attrs, Actor: "t"})
		if err != nil {
			t.Fatalf("add %s: %v", title, err)
		}
		rev = res.Rev
		return res.ItemID
	}
	off := `{"numbered":false}`
	add(root, "a", "")
	b := add(root, "b", off)
	add(b, "b1", "")
	c := add(root, "c", `{"numbered":true}`)
	add(c, "c1", off)
	add(c, "c2", "")
	sub, err := pg.DocSubtree(ctx, tid, doc, "")
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, it := range sub[1:] {
		got = append(got, it.Title+"="+it.Outline)
	}
	if s := fmt.Sprint(got); s != "[a=1 b= b1= c=2 c1= c2=2.1]" {
		t.Fatalf("outline %s", s)
	}
	part, err := pg.DocSubtree(ctx, tid, doc, c)
	kids, err2 := pg.DocChildren(ctx, tid, doc, c)
	if err := errors.Join(err, err2); err != nil {
		t.Fatal(err)
	}
	if len(part) != 3 || part[0].Outline != "2" || part[2].Outline != "2.1" || part[2].Depth != 2 {
		t.Fatalf("subtree from c: %+v", part)
	}
	if len(kids.Items) != 2 || kids.Items[0].Outline != "" || kids.Items[1].Outline != "2.1" || fmt.Sprint(kids.Path) != "[3]" {
		t.Fatalf("children of c: %+v", kids)
	}
}
