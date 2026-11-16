package hub

import (
	"context"
	"errors"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// cloneFakeStore is the memory store plus a scripted Clone(): the one read
// every act-as clone gate makes (readerIsActAsClone, actAsCloneState).
type cloneFakeStore struct {
	*store.Memory
	clone store.Clone
	err   error
}

func (f *cloneFakeStore) Clone(context.Context, string, string) (store.Clone, error) {
	return f.clone, f.err
}

func cloneFakeServer(t *testing.T, f *cloneFakeStore) *Server {
	t.Helper()
	s, err := New(Options{Store: f, Blob: blob.Dir{Root: t.TempDir()}, TenantHostPattern: "{tenant}.example.test"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Shutdown)
	return s
}

// TestActAsCloneCheckFailsClosed (SPL-5673, R7 c-369 N2 on SPL-5369): a store
// error from Clone() that is not "no row" must REFUSE at every clone gate, not
// read "not a clone". Controls: no row = not a clone, an ended clone = not a
// clone, a live clone = a clone, as before.
func TestActAsCloneCheckFailsClosed(t *testing.T) {
	ended := time.Now()
	cases := []struct {
		name  string
		fake  cloneFakeStore
		clone bool // the gate's answer: true = refused as a clone
		err   bool // actAsCloneState carries the store error
	}{
		{"a store error (DB hiccup) refuses", cloneFakeStore{err: errors.New("conn reset")}, true, true},
		{"CONTROL: no member_clones row = not a clone", cloneFakeStore{err: store.ErrNotFound}, false, false},
		{"CONTROL: a live clone is refused", cloneFakeStore{clone: store.Clone{CloneHum: "HUM-9"}}, true, false},
		{"CONTROL: an ended clone is not a clone", cloneFakeStore{clone: store.Clone{CloneHum: "HUM-9", EndedAt: &ended}}, false, false},
	}
	ctx := context.Background()
	for _, tc := range cases {
		f := tc.fake
		f.Memory = store.NewMemory()
		s := cloneFakeServer(t, &f)
		if got := s.readerIsActAsClone(ctx, "tfc", "HUM-9"); got != tc.clone {
			t.Errorf("%s: readerIsActAsClone = %v, want %v", tc.name, got, tc.clone)
		}
		// SPL-5694 N4: every path asserts both values; a store error is (false, err).
		got, err := s.actAsCloneState(ctx, "tfc", "HUM-9")
		if (err != nil) != tc.err || got != (tc.clone && !tc.err) {
			t.Errorf("%s: actAsCloneState = %v, %v; want clone %v, err %v", tc.name, got, err, tc.clone, tc.err)
		}
		// Two gates the routes call: the file-stream read and the doc tree.
		if refusal := s.fileStreamsStaffRefusal(ctx, "tfc", "HUM-9"); (refusal == "an act-as session does not read file streams") != tc.clone {
			t.Errorf("%s: fileStreamsStaffRefusal = %q, want clone refusal %v", tc.name, refusal, tc.clone)
		}
		if who := s.docTreeHuman(httptest.NewRequest("GET", "/", nil), "tfc", "HUM-9", false); (who == "") != tc.clone {
			t.Errorf("%s: docTreeHuman = %q, want empty (refused) %v", tc.name, who, tc.clone)
		}
		// The realm doors turn the store error into a 503 (realmCaller), not a pass.
		// A non-clone with no seat keeps the realm (false, nil).
		refuse, err := s.realmRefuses(ctx, auth.Session{HumanID: "HUM-9", Tenant: "tfc"})
		if (err != nil) != tc.err || refuse != (tc.clone && !tc.err) {
			t.Errorf("%s: realmRefuses = %v, %v; want refused %v, store error %v", tc.name, refuse, err, tc.clone && !tc.err, tc.err)
		}
		// SPL-5694 N3: the GET /v1/view/me banner carries the store error (503),
		// never reads it as "no clone".
		banner, err := s.actAsMe(ctx, "tfc", "HUM-9")
		if (err != nil) != tc.err || (banner != nil) != (tc.clone && !tc.err) {
			t.Errorf("%s: actAsMe = %v, %v; want banner %v, store error %v", tc.name, banner, err, tc.clone && !tc.err, tc.err)
		}
	}
	// An empty human is never a clone and never reads the store.
	f := cloneFakeStore{Memory: store.NewMemory(), err: errors.New("must not be read")}
	if s := cloneFakeServer(t, &f); s.readerIsActAsClone(ctx, "tfc", "") {
		t.Error("readerIsActAsClone(\"\") = true, want false")
	}
}
