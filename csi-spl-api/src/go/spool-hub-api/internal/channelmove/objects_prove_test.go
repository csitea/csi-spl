package channelmove

import (
	"context"
	"errors"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
)

// proofCounts is name -> [count, known], for one assertion per proof.
func proofCounts(ps []Proof) map[string][2]int64 {
	out := map[string][2]int64{}
	for _, p := range ps {
		out[p.Name] = [2]int64{p.Count, p.Known}
	}
	return out
}

// movedFiles is P3, P4 and P6 of two files: one only the set carries, one a
// staying <SRC> row also lists (5.5).
func movedFiles(t *testing.T) (Objects, *rows, ObjectSet, blob.Dir, string) {
	t.Helper()
	ctx := context.Background()
	files := blob.Dir{Root: t.TempDir()}
	r := newRows()
	own, ownB := blobOf(t, "only the moved channel carries me")
	shared, sharedB := blobOf(t, "a staying channel carries me too")
	seed(t, files, fkey(srcT, own), ownB)
	seed(t, files, fkey(srcT, shared), sharedB)
	put(r.attached, srcT, shared, true)
	o := Objects{Files: files, Held: r}
	set := ObjectSet{Files: []string{own, shared}}
	if _, err := o.Copy(ctx, srcT, dstT, set); err != nil {
		t.Fatal(err)
	}
	moveRows(r, own)
	if _, err := o.Delete(ctx, srcT, dstT, set); err != nil {
		t.Fatal(err)
	}
	return o, r, set, files, own
}

// T8b, 5.3: after P6 each moved object is gone from <SRC> and present in
// <DST>; the shared one stays in <SRC> as a known hit, so every proof holds.
func TestProveObjectsAfterMove(t *testing.T) {
	o, _, set, _, _ := movedFiles(t)
	ps, err := o.Prove(context.Background(), srcT, dstT, set)
	if err != nil {
		t.Fatal(err)
	}
	got := proofCounts(ps)
	want := map[string][2]int64{
		"objects M4 files bucket: left in <SRC>":    {1, 1},
		"objects M4 files bucket: missing in <DST>": {0, 0},
		"objects M8 Qto pictures: left in <SRC>":    {0, 0},
		"objects M8 Qto pictures: missing in <DST>": {0, 0},
	}
	if len(got) != len(want) {
		t.Fatalf("proofs %v, want %v", got, want)
	}
	for n, w := range want {
		if got[n] != w {
			t.Errorf("%s: %v, want %v", n, got[n], w)
		}
	}
	if f := Failed(ps); len(f) != 0 {
		t.Errorf("a finished move fails %v", f)
	}
}

// RED CONTROL: an object planted back in <SRC> that no <SRC> row lists is a
// failed proof; P6's counts would not see it.
func TestProveObjectLeftInSourceFails(t *testing.T) {
	o, _, set, files, own := movedFiles(t)
	_, ownB := blobOf(t, "only the moved channel carries me")
	seed(t, files, fkey(srcT, own), ownB)
	ps, err := o.Prove(context.Background(), srcT, dstT, set)
	if err != nil {
		t.Fatal(err)
	}
	f := Failed(ps)
	if len(f) != 1 || f[0].Name != "objects M4 files bucket: left in <SRC>" || f[0].Count != 2 || f[0].Known != 1 {
		t.Fatalf("failed %+v, want the M4 left proof at 2 of 1 known", f)
	}
	t.Logf("red control: %s count %d known %d", f[0].Name, f[0].Count, f[0].Known)
}

// A moved object whose <DST> copy is gone fails the missing proof.
func TestProveObjectMissingInDestinationFails(t *testing.T) {
	o, _, set, files, own := movedFiles(t)
	if err := files.Delete(context.Background(), fkey(dstT, own)); err != nil {
		t.Fatal(err)
	}
	ps, err := o.Prove(context.Background(), srcT, dstT, set)
	if err != nil {
		t.Fatal(err)
	}
	if f := Failed(ps); len(f) != 1 || f[0].Name != "objects M4 files bucket: missing in <DST>" || f[0].Count != 1 {
		t.Fatalf("failed %+v, want the M4 missing proof at 1", f)
	}
}

// M8: a picture in either <SRC> place (its docs store, or the files bucket
// from before 052) is left; its <DST> place is the docs store.
func TestProveDocAssets(t *testing.T) {
	ctx := context.Background()
	files := blob.Dir{Root: t.TempDir()}
	docs := map[string]blob.Store{srcT: blob.Dir{Root: t.TempDir()}, dstT: blob.Dir{Root: t.TempDir()}}
	r := newRows()
	newer, newerB := blobOf(t, "picture in the docs store")
	legacy, legacyB := blobOf(t, "picture from before 052")
	seed(t, docs[srcT], docAssetPrefix+newer, newerB)
	seed(t, files, fkey(srcT, legacy), legacyB)
	o := Objects{Files: files, Held: r,
		Docs: func(_ context.Context, tenant string) (blob.Store, error) { return docs[tenant], nil }}
	set := ObjectSet{DocAssets: []string{newer, legacy}}
	ps, err := o.Prove(ctx, srcT, dstT, set)
	if err != nil {
		t.Fatal(err)
	}
	if got := proofCounts(ps); got["objects M8 Qto pictures: left in <SRC>"] != [2]int64{2, 0} ||
		got["objects M8 Qto pictures: missing in <DST>"] != [2]int64{2, 0} {
		t.Fatalf("before the move %v, want 2 left and 2 missing", got)
	}
	if _, err := o.Copy(ctx, srcT, dstT, set); err != nil {
		t.Fatal(err)
	}
	if _, err := o.Delete(ctx, srcT, dstT, set); err != nil {
		t.Fatal(err)
	}
	ps, err = o.Prove(ctx, srcT, dstT, set)
	if err != nil {
		t.Fatal(err)
	}
	if f := Failed(ps); len(f) != 0 {
		t.Fatalf("after the move %v", f)
	}
}

// unreadable is a bucket P7 cannot read.
type unreadable struct{ blob.Store }

var errNoRead = errors.New("403 storage.objects.get denied")

func (unreadable) Exists(context.Context, string) (bool, error) { return false, errNoRead }

// A P7 that cannot read a bucket holds: an error, never a proof of 0.
func TestProveUnreadableBucketHolds(t *testing.T) {
	o, _, set, files, _ := movedFiles(t)
	o.Files = unreadable{files}
	ps, err := o.Prove(context.Background(), srcT, dstT, set)
	if !errors.Is(err, errNoRead) || ps != nil {
		t.Fatalf("Prove on an unreadable bucket: %v %v, want the read error and no proofs", ps, err)
	}
}
