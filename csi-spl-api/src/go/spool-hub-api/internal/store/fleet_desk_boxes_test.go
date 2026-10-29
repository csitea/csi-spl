package store

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
)

// Spec 158 row T6 (rdb 0230): list, put (a second put keeps the first row
// and answers created false), delete; deleting an unlisted box is
// ErrNotFound; a box id or added_by the table's CHECKs refuse never reaches
// it. Memory and Postgres (the table is the instance's, so the ids are
// unique per run).
func TestFleetDeskBoxesStore(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fd, ok := st.(FleetDeskBoxes)
			if !ok {
				t.Fatalf("%s keeps no fleet desk boxes", name)
			}
			box := uid("fdb-")
			listed := func() []string {
				all, err := fd.ListFleetDeskBoxes(ctx)
				if err != nil {
					t.Fatal(err)
				}
				var ids []string
				for _, b := range all {
					ids = append(ids, b.BoxID)
				}
				return ids
			}
			if slices.Contains(listed(), box) {
				t.Fatalf("control: %s listed before the put", box)
			}
			b, created, err := fd.PutFleetDeskBox(ctx, box, "HUM-10")
			if err != nil || !created || b.BoxID != box || b.AddedBy != "HUM-10" || b.AddedAt.IsZero() {
				t.Fatalf("put: %+v created=%v %v", b, created, err)
			}
			t.Cleanup(func() { _ = fd.DeleteFleetDeskBox(ctx, box) })
			again, created, err := fd.PutFleetDeskBox(ctx, box, "HUM-11")
			if err != nil || created || again.AddedBy != "HUM-10" || !again.AddedAt.Equal(b.AddedAt) {
				t.Fatalf("second put: %+v created=%v %v, want the first row kept", again, created, err)
			}
			if !slices.Contains(listed(), box) {
				t.Fatalf("list misses %s", box)
			}
			for _, bad := range [][2]string{{"Upper", "HUM-10"}, {"-lead", "HUM-10"}, {strings.Repeat("a", 33), "HUM-10"},
				{uid("fdb-"), ""}, {uid("fdb-"), strings.Repeat("x", FleetDeskAddedByMax+1)}} {
				if _, _, err := fd.PutFleetDeskBox(ctx, bad[0], bad[1]); !errors.Is(err, ErrFleetDeskBox) {
					t.Errorf("put %q by %q: %v, want ErrFleetDeskBox", bad[0], bad[1], err)
				}
			}
			if err := fd.DeleteFleetDeskBox(ctx, box); err != nil {
				t.Fatalf("delete: %v", err)
			}
			if slices.Contains(listed(), box) {
				t.Fatalf("%s still listed after the delete", box)
			}
			if err := fd.DeleteFleetDeskBox(ctx, box); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second delete: %v, want ErrNotFound", err)
			}
		})
	}
}
