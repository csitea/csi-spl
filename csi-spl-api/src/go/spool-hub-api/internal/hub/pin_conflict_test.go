package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 108 T007: the root-key POST /v1/pins refuses a key live on another
// box, in another workspace or this one, with pin_conflict that never names
// the holder (spec 3.2, 3.5 "at pin"). Runs on memory, and on Postgres with
// SPOOL_TEST_PG_DSN. Every case states its n and carries its control.

func pubB64(k ed25519.PrivateKey) string {
	return base64.StdEncoding.EncodeToString(k.Public().(ed25519.PublicKey))
}

// forcePin is postPin with force set, 2 s later so it is no replay of the
// pin just made (ErrStale).
func (e *env) forcePin(tenant string, root ed25519.PrivateKey, boxID, pub string) (int, wire.ErrorBody) {
	e.t.Helper()
	ts := time.Now().Add(2 * time.Second).UTC().Format(time.RFC3339)
	payload, _ := wire.PinPayload(boxID, pub, ts, true)
	body, _ := json.Marshal(wire.PinRequest{BoxID: boxID, PubKey: pub, TS: ts, Force: true, Sig: sign.Sign(root, payload)})
	resp, err := e.client.Post(e.url(tenant)+"/v1/pins", "application/json", bytes.NewReader(body))
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var eb wire.ErrorBody
	json.Unmarshal(raw, &eb) //nolint:errcheck
	return resp.StatusCode, eb
}

func wantKeyLive(t *testing.T, what, holder string, code int, eb wire.ErrorBody) {
	t.Helper()
	if code != http.StatusConflict || eb.Error != "pin_conflict" || strings.Contains(eb.Detail, holder) {
		t.Fatalf("%s: %d %+v, want 409 pin_conflict naming no workspace", what, code, eb)
	}
}

// Pair (c), n = 3 keys pinned in A: each is refused in B under the same box
// id, under another box id, and with force over a box B already holds; each
// is refused on a second box of A. CONTROL: a unique key pins in B.
func TestSpec108PinSameKeyOneWorkspace(t *testing.T) {
	e := newEnv(t)
	a, rootA := e.tenant()
	b, rootB := e.tenant()
	for i := 0; i < 3; i++ {
		k := pubB64(newKey(t))
		box := "box-p" + string(rune('0'+i))
		if code, eb := e.postPin(a, rootA, box, k); code != http.StatusOK {
			t.Fatalf("key %d into A: %d %+v", i, code, eb)
		}
		code, eb := e.postPin(b, rootB, box, k)
		wantKeyLive(t, "same box id into B", a, code, eb)
		code, eb = e.postPin(b, rootB, box+"-b", k)
		wantKeyLive(t, "another box id into B", a, code, eb)
		code, eb = e.postPin(a, rootA, box+"-a", k)
		wantKeyLive(t, "a second box of A", a, code, eb)
		if code, eb := e.postPin(b, rootB, box, pubB64(newKey(t))); code != http.StatusOK {
			t.Fatalf("CONTROL %d: a unique key into B: %d %+v", i, code, eb)
		}
		code, eb = e.forcePin(b, rootB, box, k)
		wantKeyLive(t, "force over B's own box", a, code, eb)
		if code, eb := e.postPin(a, rootA, box, k); code != http.StatusOK {
			t.Fatalf("CONTROL %d: the same pin again in A is a no-op: %d %+v", i, code, eb)
		}
	}
	pins, _ := e.st.ListPins(context.Background(), b)
	if len(pins) != 3 {
		t.Fatalf("B holds %d pins, want the 3 unique keys", len(pins))
	}
}

// A revoked pin frees its key (rdb 0154 counts live pins only). n = 1.
// CONTROL: the same pin is refused before the revoke.
func TestSpec108PinKeyFreedByRevoke(t *testing.T) {
	e := newEnv(t)
	a, rootA := e.tenant()
	b, rootB := e.tenant()
	k := pubB64(newKey(t))
	if code, eb := e.postPin(a, rootA, "box-r", k); code != http.StatusOK {
		t.Fatalf("into A: %d %+v", code, eb)
	}
	code, eb := e.postPin(b, rootB, "box-r", k)
	wantKeyLive(t, "CONTROL: B before the revoke", a, code, eb)
	if err := e.st.RevokePin(context.Background(), a, "box-r", time.Now().Add(time.Second), time.Now()); err != nil {
		t.Fatal(err)
	}
	if code, eb := e.postPin(b, rootB, "box-r", k); code != http.StatusOK {
		t.Fatalf("B after A's revoke: %d %+v", code, eb)
	}
}

// Race: n = 6 workspaces pin one key at once; exactly one wins, every other
// answer is pin_conflict, never a 500 (the lock, with the unique index as the
// backstop).
func TestSpec108PinKeyRaceOneWins(t *testing.T) {
	e := newEnv(t)
	k := pubB64(newKey(t))
	const n = 6
	codes := make([]int, n)
	errs := make([]string, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		tid, root := e.tenant()
		wg.Add(1)
		go func(i int, tid string, root ed25519.PrivateKey) {
			defer wg.Done()
			c, eb := e.postPin(tid, root, "box-race", k)
			codes[i], errs[i] = c, eb.Error
		}(i, tid, root)
	}
	wg.Wait()
	won := 0
	for i := range codes {
		switch {
		case codes[i] == http.StatusOK:
			won++
		case codes[i] != http.StatusConflict || errs[i] != "pin_conflict":
			t.Fatalf("racer %d: %d %s, want 200 or 409 pin_conflict", i, codes[i], errs[i])
		}
	}
	if won != 1 {
		t.Fatalf("%d of %d racers pinned the key, want 1 (codes %v)", won, n, codes)
	}
}
