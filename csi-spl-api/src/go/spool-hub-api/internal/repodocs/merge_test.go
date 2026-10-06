package repodocs

import (
	"fmt"
	"strings"
	"testing"
)

func TestMerge3(t *testing.T) {
	base := "a\nb\nc\nd\ne\nf\n"
	cases := []struct {
		name, theirs, mine, want string
		ok                       bool
	}{
		{"only mine changed", base, "a\nB\nc\nd\ne\nf\n", "a\nB\nc\nd\ne\nf\n", true},
		{"only theirs changed", "a\nb\nc\nd\ne\nF\n", base, "a\nb\nc\nd\ne\nF\n", true},
		{"far apart", "A\nb\nc\nd\ne\nf\n", "a\nb\nc\nd\ne\nF\n", "A\nb\nc\nd\ne\nF\n", true},
		{"same change both", "a\nX\nc\nd\ne\nf\n", "a\nX\nc\nd\ne\nf\n", "a\nX\nc\nd\ne\nf\n", true},
		{"same lines differ", "a\nT\nc\nd\ne\nf\n", "a\nM\nc\nd\ne\nf\n", "", false},
		{"adjacent lines conflict", "a\nT\nc\nd\ne\nf\n", "a\nb\nM\nd\ne\nf\n", "", false},
		{"insert vs append", "top\n" + base, base + "end\n", "top\n" + base + "end\n", true},
		{"both insert at one point", "a\nb\nT\nc\nd\ne\nf\n", "a\nb\nM\nc\nd\ne\nf\n", "", false},
		{"delete vs far edit", "a\nc\nd\ne\nf\n", "a\nb\nc\nd\ne\nF\n", "a\nc\nd\ne\nF\n", true},
		{"line ends kept", "a\nb\nc\nd\ne\nf", "A\nb\nc\nd\ne\nf\n", "A\nb\nc\nd\ne\nf", true},
	}
	for _, c := range cases {
		got, ok := Merge3([]byte(base), []byte(c.theirs), []byte(c.mine))
		if ok != c.ok || (ok && string(got) != c.want) {
			t.Errorf("%s: ok=%v got %q, want ok=%v %q", c.name, ok, got, c.ok, c.want)
		}
	}
}

// TestMerge3EmptyBase: a new file both sides created is a conflict unless
// the two texts are the same.
func TestMerge3EmptyBase(t *testing.T) {
	if got, ok := Merge3(nil, []byte("x\n"), []byte("x\n")); !ok || string(got) != "x\n" {
		t.Fatalf("same new text: %q %v", got, ok)
	}
	if _, ok := Merge3(nil, []byte("x\n"), []byte("y\n")); ok {
		t.Fatal("two different new texts merged")
	}
}

// TestMerge3LargeDoc: a long doc with one edit per side far apart merges, and
// a rewrite past maxMergeEdits is a conflict rather than a slow guess.
func TestMerge3LargeDoc(t *testing.T) {
	var b strings.Builder
	for i := 0; i < 20000; i++ {
		fmt.Fprintf(&b, "line %d\n", i)
	}
	base := b.String()
	theirs := strings.Replace(base, "line 10\n", "line ten\n", 1)
	mine := strings.Replace(base, "line 19990\n", "line end\n", 1)
	got, ok := Merge3([]byte(base), []byte(theirs), []byte(mine))
	if !ok || !strings.Contains(string(got), "line ten\n") || !strings.Contains(string(got), "line end\n") {
		t.Fatalf("large merge ok=%v", ok)
	}
	rewrite := strings.ReplaceAll(base, "line", "row")
	if _, ok := Merge3([]byte(base), []byte(theirs), []byte(rewrite)); ok {
		t.Fatal("a full rewrite over a moved head merged")
	}
}
