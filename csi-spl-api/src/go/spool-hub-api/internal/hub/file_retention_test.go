package hub_test

// CLE-34962 — a file must not outlive the privacy of the messages carrying it.
//
// The read door (rdb 0030) let an UNATTACHED blob through to any member or
// pinned box of the tenant, for the upload-then-send window. Retention
// deleted expired messages and never their blobs, so the moment a private
// message expired its attachment became readable by the whole tenant, for
// ever, to anyone holding the file_id. An unattached blob is now readable
// only within hub.FileUploadGrace of its upload; after that it is 404, the
// same answer as "no such file".

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// ageBlob backdates the stored object, as if it had been uploaded at `at`.
func ageBlob(t *testing.T, e *env, tenant, fileID string, at time.Time) {
	t.Helper()
	key, err := blob.Key(tenant, fileID)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(filepath.Join(e.blobs, filepath.FromSlash(key)), at, at); err != nil {
		t.Fatal(err)
	}
}

// privateChannel creates channel id with members.
func privateChannel(t *testing.T, e *env, tid, id string, members ...string) {
	t.Helper()
	ctx := context.Background()
	now := time.Now().UTC()
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: id,
		Name: id, CreatedBy: members[0], CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, id, members, members[0], now); err != nil {
		t.Fatal(err)
	}
}

// An expired private message's attachment is 404 for a member who was never
// in the channel AND for one who was; the CONTROL is a live message's file in
// the same channel, readable by its member, so "nobody reads anything" cannot
// pass this.
func TestExpiredPrivateFileIsNotTenantReadable(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	now := time.Now().UTC().Truncate(time.Microsecond)
	privateChannel(t, e, tid, "priv", "HUM-1", "HUM-3")
	old := now.Add(-31 * 24 * time.Hour)

	chOld := strings.Repeat("1", 64)
	dmOld := strings.Repeat("2", 64)
	live := strings.Repeat("3", 64)
	putFileRow(t, e, tid, uuidV4(), "priv", "HUM-1", "CLE-07", chOld, old)
	putFileRow(t, e, tid, uuidV4(), "", "HUM-1", "HUM-3", dmOld, old)
	putFileRow(t, e, tid, uuidV4(), "priv", "HUM-1", "CLE-07", live, now)
	ageBlob(t, e, tid, chOld, old)
	ageBlob(t, e, tid, dmOld, old)
	ageBlob(t, e, tid, live, old) // a live message keeps an old blob readable

	// CONTROL: the live message's file, to its members.
	if got := getFile(t, e, tid, live, "HUM-3"); got != http.StatusOK {
		t.Fatalf("CONTROL live channel file, member HUM-3: got %d, want 200", got)
	}
	for _, tc := range []struct{ what, file, as string }{
		{"expired channel file, never a member", chOld, "HUM-2"},
		{"expired channel file, the channel's member", chOld, "HUM-3"},
		{"expired DM file, not an end", dmOld, "HUM-2"},
		{"expired DM file, an end of it", dmOld, "HUM-3"},
	} {
		if got := getFile(t, e, tid, tc.file, tc.as); got != http.StatusNotFound {
			t.Errorf("%s (%s): got %d, want 404", tc.what, tc.as, got)
		}
	}

	// A member REMOVED from the channel loses its live file at once.
	if err := e.st.RemoveChannelHuman(context.Background(), tid, "priv", "HUM-3"); err != nil {
		t.Fatal(err)
	}
	if got := getFile(t, e, tid, live, "HUM-3"); got != http.StatusNotFound {
		t.Errorf("live channel file after HUM-3 left the channel: got %d, want 404", got)
	}
	if got := getFile(t, e, tid, live, "HUM-1"); got != http.StatusOK { // CONTROL
		t.Errorf("live channel file, remaining member HUM-1: got %d, want 200", got)
	}
}

// The upload grace: a fresh unattached upload is readable (the box fetches
// back what it just uploaded), the same blob past the grace is not.
func TestUnattachedFileGraceEnds(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	id := strings.Repeat("4", 64)
	key, _ := blob.Key(tid, id)
	if err := (blob.Dir{Root: e.blobs}).Put(ctx, key, []byte("never sent")); err != nil {
		t.Fatal(err)
	}
	if got := getFile(t, e, tid, id, "HUM-2"); got != http.StatusOK { // CONTROL
		t.Fatalf("fresh unattached upload: got %d, want 200", got)
	}
	ageBlob(t, e, tid, id, time.Now().Add(-hub.FileUploadGrace-time.Minute))
	for _, as := range []string{"HUM-1", "HUM-2"} {
		if got := getFile(t, e, tid, id, as); got != http.StatusNotFound {
			t.Errorf("unattached upload past the grace (%s): got %d, want 404", as, got)
		}
	}
}

// A box that is neither end of a message nor a delivery target of it gets
// 404 on its file; an end gets 200 (the CONTROL).
func TestFileBoxNotAnEndIs404(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	a, b, c := e.box(tid, "box-a", "GRK-03"), e.box(tid, "box-b", "CLE-07"), e.box(tid, "box-c", "CLE-09")
	for _, x := range []*box{a, b, c} {
		e.pin(tid, x)
	}
	data := []byte("between a and b")
	id := sha256Hex(data)
	files := `[{"mode":"blob","kind":"file","file_id":"` + id + `","name":"x.pdf","sha256":"` + id + `"}]`
	m := store.Message{TenantID: tid, MsgID: uuidV4(), TaskID: uuidV4(), TS: now,
		FromBox: "box-a", FromID: "GRK-03", ToBox: "box-b", ToID: "CLE-07", Kind: "note", Body: "b",
		Files: []byte(files), Msg: []byte(`{}`), Env: []byte(`{}`), ReceivedAt: now, ExpiresAt: now.Add(24 * time.Hour)}
	if _, err := e.st.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	key, _ := blob.Key(tid, id)
	if err := (blob.Dir{Root: e.blobs}).Put(ctx, key, data); err != nil {
		t.Fatal(err)
	}
	ageBlob(t, e, tid, id, now.Add(-2*hub.FileUploadGrace))
	for _, tc := range []struct {
		b    *box
		want int
	}{{a, http.StatusOK}, {b, http.StatusOK}, {c, http.StatusNotFound}} {
		if got, _ := e.getFile(tid, id, e.uploadToken(tid, tc.b)); got != tc.want {
			t.Errorf("%s: got %d, want %d", tc.b.id, got, tc.want)
		}
	}
	// The same door through the box client (spool hub-get-file, the live
	// probe's path): the end fetches, the stranger is not_found.
	for _, tc := range []struct {
		b  *box
		ok bool
	}{{a, true}, {c, false}} {
		sess, err := tc.b.c.Dial(ctx, wire.RoleCLI)
		if err != nil {
			t.Fatal(err)
		}
		err = sess.FetchFile(ctx, id)
		sess.Close()
		var he *hubclient.HubError
		if tc.ok && err != nil {
			t.Errorf("%s FetchFile: %v", tc.b.id, err)
		}
		if !tc.ok && (!errors.As(err, &he) || he.Token != "not_found") {
			t.Errorf("%s FetchFile: %v, want not_found", tc.b.id, err)
		}
	}
}

// Retention deletes a blob only when no retained message carries it, it is
// no member's avatar and it is older than the orphan grace. Each deletion is
// paired with a blob that must survive, so "delete everything" fails too.
func TestSweepFilesDeletesOnlyOrphans(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	old := now.Add(-31 * 24 * time.Hour)
	stale := now.Add(-hub.FileOrphanGrace - time.Hour)
	fresh := now.Add(-2 * hub.FileUploadGrace) // past the read grace, not the orphan grace

	expired := strings.Repeat("6", 64) // carried only by an expired message
	shared := strings.Repeat("7", 64)  // one expired and one live message carry it
	unsent := strings.Repeat("8", 64)  // uploaded, not sent yet
	avatar := strings.Repeat("9", 64)  // a member's picture, no message carries it
	putFileRow(t, e, tid, uuidV4(), "lobby", "HUM-1", "CLE-07", expired, old)
	putFileRow(t, e, tid, uuidV4(), "", "HUM-1", "HUM-2", shared, old)
	putFileRow(t, e, tid, uuidV4(), "", "HUM-1", "HUM-2", shared, now)
	bl := blob.Dir{Root: e.blobs}
	for _, id := range []string{unsent, avatar} {
		key, _ := blob.Key(tid, id)
		if err := bl.Put(ctx, key, []byte(id)); err != nil {
			t.Fatal(err)
		}
	}
	h := e.st.(store.Humans)
	hum, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: "sweep-" + tid}, tid,
		store.AdmitPolicy{BootstrapOwner: true}, now)
	if err != nil {
		t.Fatal(err)
	}
	if err := h.SetAvatar(ctx, hum, avatar); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{expired, shared, avatar} {
		ageBlob(t, e, tid, id, stale)
	}
	ageBlob(t, e, tid, unsent, fresh)
	staleTmp, freshTmp := blob.TmpKey(tid, "crashed"), blob.TmpKey(tid, "inflight")
	for _, k := range []string{staleTmp, freshTmp} {
		if err := bl.Put(ctx, k, []byte("partial")); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chtimes(filepath.Join(e.blobs, filepath.FromSlash(staleTmp)), stale, stale); err != nil {
		t.Fatal(err)
	}

	r, err := e.srv.SweepFiles(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	has := func(key string) bool { ok, _ := bl.Exists(ctx, key); return ok }
	for _, tc := range []struct {
		what, key string
		want      bool
	}{
		{"blob of an expired message", "t/" + tid + "/files/" + expired, false},
		{"blob a live message still carries", "t/" + tid + "/files/" + shared, true},
		{"fresh unsent upload", "t/" + tid + "/files/" + unsent, true},
		{"member avatar", "t/" + tid + "/files/" + avatar, true},
		{"stale tmp upload", staleTmp, false},
		{"in-flight tmp upload", freshTmp, true},
	} {
		if got := has(tc.key); got != tc.want {
			t.Errorf("%s: present=%v, want %v", tc.what, got, tc.want)
		}
	}
	if r.Deleted != 2 {
		t.Errorf("deleted %d, want 2 (%+v)", r.Deleted, r)
	}
	if got := getFile(t, e, tid, expired, "HUM-1"); got != http.StatusNotFound {
		t.Errorf("swept blob: got %d, want 404", got)
	}
}
