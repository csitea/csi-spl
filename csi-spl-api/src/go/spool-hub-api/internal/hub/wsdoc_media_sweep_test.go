package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 190 row H3 (SPL-6152, Q6 A): the doc media sweep on a fake clock.
// Red on origin/master: no sweep walks qto-media/ or .doctree/, so the
// deleted doc's video and pictures outlive grace + 1 s. Red control of the
// row: the sweep without the qto-media/ prefix in its per-doc walk leaves
// the gone doc's video and fails here (the commit body holds the run).
//
//	go test ./internal/hub -run 'WorkspaceDocMediaSweep' -v

func TestWorkspaceDocMediaSweep(t *testing.T) {
	e, d, tid, as, x := mediaEnv(t)
	ctx := context.Background()
	newDoc := func(who, title string, locked bool) (string, int64) {
		t.Helper()
		out := mustCall(t, e, tid, http.MethodPost, docTreeAPI, who, map[string]any{"title": title, "restricted": locked}, 200)
		return docTreeAPI + "/" + dtStr(out, "id"), dtNum(out, "rev")
	}
	up := func(doc, who string, body []byte) string {
		t.Helper()
		code, out := mediaPost(t, e, tid, doc, who, "", "video/mp4", "", bytes.NewReader(body), int64(len(body)))
		if code != http.StatusCreated {
			t.Fatalf("upload to %s: %d %v", doc, code, out)
		}
		return dtStr(out, "http_path")
	}
	pic := func(doc string, level uint8) string {
		t.Helper()
		code, out, _ := rawCall(t, e, tid, http.MethodPost, doc+"/images", as, "image/png", pngOf(t, level))
		if code != 200 {
			t.Fatalf("picture to %s: %d %s", doc, code, out)
		}
		return string(out)
	}
	y, yRev := newDoc(as, "kept", false)
	owner := seat(t, e, tid, rbac.Admin)
	z, _ := newDoc(owner, "locked", true)
	vx, vy, vc, vz := up(x, as, mp4Of(1001)), up(y, as, mp4Of(1002)), up(y, as, mp4Of(1003)), up(z, owner, mp4Of(1004))
	px, pyNamed, pyLoose := pic(x, 31), pic(y, 32), pic(y, 33)
	named := jsonField(t, pyNamed, "img_http_path")
	mustCall(t, e, tid, http.MethodPost, y+"/items", as, map[string]any{"rev": yRev, "where": "child", "title": "s",
		"body": "![clip](" + vy + ") and ![fig](" + named + ")"}, 200)
	loc := mustLoc(t, d, tid)
	keyOf := func(p string) string { // a hub path's object in the own store
		doc, rest, _ := strings.Cut(strings.TrimPrefix(p, docTreeAPI+"/"), "/")
		kind, name, _ := strings.Cut(rest, "/")
		if kind == "images" {
			return filepath.Join(loc, ".doctree", doc, name)
		}
		return filepath.Join(loc, "qto-media", doc, name)
	}
	all := map[string]string{"gone doc video": vx, "named video": vy, "unnamed video": vc, "locked doc video": vz,
		"gone doc picture": jsonField(t, px, "img_http_path"), "named picture": named, "loose picture": jsonField(t, pyLoose, "img_http_path")}
	old := time.Now().Add(-2 * hub.DocMediaGrace)
	for _, p := range all {
		if err := os.Chtimes(keyOf(p), old, old); err != nil {
			t.Fatal(err)
		}
	}
	mustCall(t, e, tid, http.MethodDelete, x, as, nil, 200)
	t0 := time.Now()
	sweep := func(at time.Time) {
		t.Helper()
		if _, err := e.srv.SweepFiles(ctx, at); err != nil {
			t.Fatalf("sweep at %v: %v", at, err)
		}
	}
	there := func(name string) bool { _, err := os.Stat(keyOf(all[name])); return err == nil }
	sweep(t0)
	sweep(t0.Add(hub.DocMediaGrace - time.Second))
	for _, n := range []string{"gone doc video", "gone doc picture", "unnamed video"} {
		if !there(n) {
			t.Fatalf("%s deleted before the grace", n)
		}
	}
	sweep(t0.Add(hub.DocMediaGrace + time.Second))
	for n := range all {
		want := n == "named video" || n == "named picture" || n == "locked doc video"
		if there(n) != want {
			t.Errorf("after grace + 1 s: %s present=%v, want %v", n, there(n), want)
		}
	}
	sweep(t0.Add(3 * hub.DocMediaGrace))
	if !there("locked doc video") || !there("named video") {
		t.Fatalf("CONTROL: a later sweep deleted a locked doc's or a named video")
	}
	t.Logf("sweep: at grace-1s the gone doc's files and the unnamed video kept; at grace+1s they and the loose picture gone, " +
		"the named video, the named picture and the locked doc's video kept, and still at 3x grace")
}

// jsonField is k of the JSON object raw.
func jsonField(t *testing.T, raw, k string) string {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		t.Fatalf("%s: %v", raw, err)
	}
	return dtStr(m, k)
}
