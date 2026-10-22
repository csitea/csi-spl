package action

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/lockkey"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

// A box sealed by the owner lock (spec 025 box-owner-lock.md 4.2, row B4)
// joins only with its sealed key, taken from the unlocked holder. Sealed and
// not unlocked: refused before the hub is called, and no clear key appears.
// n = 2. CONTROL: the unlocked join's pubkey is the sealed box key.
func TestJoinSealedBox(t *testing.T) {
	h := newJoinHubStub(t, http.StatusOK, `{}`)
	cfg := testkit.NewConfig(t)
	keys, err := os.MkdirTemp("", "jk")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(keys)
	cfg.KeysDir = keys
	const secret = "correct horse battery staple"
	res, err := lockkey.Seal(keys, "t1", "box-j", []byte(secret), lockkey.Params{Time: 1, MemKiB: 64, Threads: 1})
	if err != nil {
		t.Fatal(err)
	}
	tok := "spj1.t1." + joinSecret
	args := JoinArgs{HubURL: h.srv.URL, Token: tok, Box: "box-j", WorkspaceBase: joinBase(t, "t1")}

	if _, err := Join(cfg, args); !errors.Is(err, lockkey.ErrSealed) {
		t.Fatalf("sealed, no holder: %v, want ErrSealed", err)
	}
	if len(h.reqs) != 0 {
		t.Fatal("a sealed box reached the hub")
	}
	if _, err := os.Stat(filepath.Join(keys, "box-box-j.key")); !os.IsNotExist(err) {
		t.Fatal("join made a clear key for a sealed box")
	}

	hold := &lockkey.Holder{KeysDir: keys, Backoff: time.Minute}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- hold.Serve(ctx) }()
	defer func() { cancel(); <-done }()
	for i := 0; i < 200 && !lockkey.HolderAlive(keys); i++ {
		time.Sleep(10 * time.Millisecond)
	}
	var uerr error
	for i := 0; i < 200; i++ {
		if uerr = lockkey.HolderUnlock(keys, []byte(secret)); !errors.Is(uerr, lockkey.ErrNotRunning) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if uerr != nil {
		t.Fatal(uerr)
	}
	got, err := Join(cfg, args)
	if err != nil {
		t.Fatal(err)
	}
	if got.PubKey != res.Meta.BoxPubkey || len(h.reqs) != 1 || h.reqs[0].PubKey != res.Meta.BoxPubkey {
		t.Fatalf("joined with %s, want the sealed box key %s", got.PubKey, res.Meta.BoxPubkey)
	}
}
