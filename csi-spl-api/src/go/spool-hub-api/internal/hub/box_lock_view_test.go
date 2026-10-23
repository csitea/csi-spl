package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/files"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// viewRig is one workspace with a locked box (box-own: CLE-01) and an open
// box (box-sh: CLE-02), both in channel #ops, an owner of the lock (a
// developer: the lock reads no role) and another admin, both members of
// #ops (spec 025 box-owner-lock.md, row B5). Each agent posted one line in
// #ops carrying a file, in its own topic, and CLE-02 posted one more to
// box-own (the cross topic, its file named "wombat").
type viewRig struct {
	e                 *env
	tid               string
	root              ed25519.PrivateKey
	own, sh           *box
	owner, admin      string
	ownTask, shTask   string
	ownMsg, shMsg     string
	ownFile, shFile   string
	xTask, xFile      string
	ownToken, shToken string
}

func newViewRig(t *testing.T) *viewRig {
	t.Helper()
	e := rbacEnv(t, func(o *hub.Options) { o.JoinTokenTTL = time.Hour })
	ctx, now := context.Background(), time.Now()
	tid, root := e.tenant()
	r := &viewRig{e: e, tid: tid, root: root, own: e.box(tid, "box-own", "CLE-01"), sh: e.box(tid, "box-sh", "CLE-02")}
	for _, b := range []*box{r.own, r.sh} {
		e.pin(tid, b)
	}
	r.owner, r.admin = seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Admin)
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "ops", Name: "ops",
		CreatedBy: "hub", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	for _, s := range [][2]string{{"box-own", "CLE-01"}, {"box-sh", "CLE-02"}} {
		if err := e.st.InviteChannelAgent(ctx, tid, "ops", s[0], s[1], now); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.st.AddChannelHumans(ctx, tid, "ops", []string{r.owner, r.admin}, "hub", now); err != nil {
		t.Fatal(err)
	}
	r.ownTask, r.ownMsg, r.ownFile = r.post(t, r.own, "CLE-01")
	r.shTask, r.shMsg, r.shFile = r.post(t, r.sh, "CLE-02")
	r.xTask, _, r.xFile = r.postTo(t, r.sh, "CLE-02", "box-own", "CLE-01", "wombat")
	lockTo(t, e, tid, r.own, r.owner)
	r.ownToken, r.shToken = e.uploadToken(tid, r.own), e.uploadToken(tid, r.sh)
	return r
}

// lockTo locks box b of tid to owner (a signed lock row, store side).
func lockTo(t *testing.T, e *env, tid string, b *box, owner string) {
	t.Helper()
	kbox, err := sign.LoadPrivate(b.cfg.KeysDir, b.id)
	if err != nil {
		t.Fatal(err)
	}
	_, klock, _ := ed25519.GenerateKey(nil)
	l := store.BoxLock{TenantID: tid, BoxID: b.id, LockPubKey: lb64(klock.Public().(ed25519.PublicKey)),
		BoxPubKey: lb64(kbox.Public().(ed25519.PublicKey)), Owners: []string{owner}, HidePosts: true, Version: 1}
	l.SignedBody = store.BoxLockBody(l)
	l.Signature = lb64(ed25519.Sign(klock, []byte(l.SignedBody)))
	if err := e.st.(store.BoxLockStore).CreateBoxLock(context.Background(), l, owner, time.Now()); err != nil {
		t.Fatal(err)
	}
}

// post is agent's line in #ops, in a topic of its own, carrying a file
// uploaded by its box: the task, the msg id and the file id.
func (r *viewRig) post(t *testing.T, b *box, agent string) (task, id, file string) {
	t.Helper()
	return r.postTo(t, b, agent, hub.WUIBox, "ALL-0", "quokka")
}

// postTo is post addressed to toBox / to, its body and file named word.
func (r *viewRig) postTo(t *testing.T, b *box, agent, toBox, to, word string) (task, id, file string) {
	t.Helper()
	ctx := context.Background()
	src := filepath.Join(t.TempDir(), word+"-"+agent+".txt")
	if err := os.WriteFile(src, []byte("load report of "+agent), 0o644); err != nil {
		t.Fatal(err)
	}
	att, err := files.PutFile(b.cfg.FilesDir(), src)
	if err != nil {
		t.Fatal(err)
	}
	cli, err := b.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(cli)
	if err := cli.UploadFile(ctx, att.FileID); err != nil {
		t.Fatalf("%s upload: %v", agent, err)
	}
	m := chanMsg(uuidV4(), to, "note", word+" load report from "+agent)
	m.From = agent
	m.Files = []msg.Attachment{{Mode: "blob", Kind: "file", FileID: att.FileID, Name: word + "-" + agent + ".txt"}}
	if _, err := cli.Send(ctx, signedIn(t, b, toBox, "ops", "", m)); err != nil {
		t.Fatalf("%s post: %v", agent, err)
	}
	return m.TaskID, m.MsgID, att.FileID
}

// get is a GET as member hum (no bearer): the status and the raw body.
func (r *viewRig) get(t *testing.T, path, hum string) (int, string) {
	t.Helper()
	code, _, body := viewGet(t, r.e, r.tid, path, memberHeader, hum)
	return code, string(body)
}

// refused counts box-own's refused audit rows of path.
func (r *viewRig) refused(t *testing.T, path string) int {
	t.Helper()
	rows, err := r.e.st.(store.BoxLockStore).BoxLockAudits(context.Background(), r.tid, "box-own", 200)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, a := range rows {
		if a.Path == path && a.Verdict == store.BoxLockRefused {
			n += a.Count
		}
	}
	return n
}

// wantLocked asserts a 403 box_locked and one more refused audit row of path.
func (r *viewRig) wantLocked(t *testing.T, what, path string, before, code int, out map[string]any) {
	t.Helper()
	if code != http.StatusForbidden || out["error"] != "box_locked" {
		t.Fatalf("%s: %d %v, want 403 box_locked", what, code, out)
	}
	if got := r.refused(t, path) - before; got != 1 {
		t.Fatalf("%s: %s refused audit +%d, want +1", what, path, got)
	}
}

// subscribe sends a subscribe frame for task on a member socket and answers
// the first subscribed / error frame's type and error.
func subscribe(t *testing.T, c *websocket.Conn, task string) (string, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := wsjson.Write(ctx, c, map[string]any{"type": "subscribe", "task_id": task}); err != nil {
		t.Fatal(err)
	}
	for {
		var f map[string]any
		if err := wsjson.Read(ctx, c, &f); err != nil {
			t.Fatalf("subscribe %s: %v", task, err)
		}
		switch f["type"] {
		case "subscribed":
			return "subscribed", ""
		case "error":
			s, _ := f["error"].(string)
			return "error", s
		}
	}
}

// Row B5 (section 5.1 paths 4, 4b, 5, 5b, 6, 8, 8b, 8c, 8d, 11): each path
// is a pair, the owner sees or changes what is on box-own and the other admin
// does not (hidden, 404 or 403 box_locked with one refused audit row); the
// admin's control on box-sh passes as before. Memory, and Postgres under
// SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
// RED CONTROL of the row: drop the topicLockHidden call in topicDoor
// (privacy.go, canReadTopic's rule and the fused page door) and
// 4_topic_read and 4b_subscribe go red.
func TestBoxLockViewPaths(t *testing.T) {
	r := newViewRig(t)
	e, ctx := r.e, context.Background()

	t.Run("4_topic_read", func(t *testing.T) {
		if code, body := r.get(t, "/v1/view/topics/"+r.ownTask, r.owner); code != http.StatusOK || !strings.Contains(body, r.ownMsg) {
			t.Fatalf("owner reads CLE-01's topic: %d %s", code, body)
		}
		if code, body := r.get(t, "/v1/view/topics/"+r.ownTask, r.admin); code != http.StatusNotFound {
			t.Fatalf("admin reads CLE-01's topic: %d %s, want 404", code, body)
		}
		if code, body := r.get(t, "/v1/view/topics/"+r.shTask, r.admin); code != http.StatusOK || !strings.Contains(body, r.shMsg) {
			t.Fatalf("CONTROL: admin reads CLE-02's topic: %d %s", code, body)
		}
	})

	t.Run("4_topic_list_and_search", func(t *testing.T) {
		for _, path := range []string{"/v1/view/topics?channel=ops", "/v1/view/search?q=quokka"} {
			_, own := r.get(t, path, r.owner)
			code, adm := r.get(t, path, r.admin)
			if !strings.Contains(own, r.ownTask) || !strings.Contains(own, r.shTask) {
				t.Fatalf("owner %s: %s, want both topics", path, own)
			}
			if code != http.StatusOK || strings.Contains(adm, r.ownTask) || !strings.Contains(adm, r.shTask) {
				t.Fatalf("admin %s: %d %s, want CLE-02's topic only", path, code, adm)
			}
		}
		// R7 D1: a file on CLE-02's line TO box-own is in a topic the admin
		// reads as 404, so no hit of it (file, line or topic) reaches the admin.
		_, own := r.get(t, "/v1/view/search?q=wombat", r.owner)
		code, adm := r.get(t, "/v1/view/search?q=wombat", r.admin)
		if !strings.Contains(own, r.xFile) {
			t.Fatalf("owner search wombat: %s, want the cross file", own)
		}
		if code != http.StatusOK || strings.Contains(adm, r.xFile) || strings.Contains(adm, r.xTask) {
			t.Fatalf("admin search wombat: %d %s, want no hit of the cross topic", code, adm)
		}
		if code, _ := r.get(t, "/v1/view/topics/"+r.xTask, r.admin); code != http.StatusNotFound {
			t.Fatalf("admin reads the cross topic: %d, want 404", code)
		}
	})

	t.Run("4b_subscribe", func(t *testing.T) {
		ownW, admW := dialMember(t, e, r.tid, "Owner", r.owner), dialMember(t, e, r.tid, "Admin", r.admin)
		if typ, _ := subscribe(t, ownW, r.ownTask); typ != "subscribed" {
			t.Fatalf("owner subscribes to CLE-01's topic: %s", typ)
		}
		if typ, tok := subscribe(t, admW, r.ownTask); typ != "error" || tok != "not_found" {
			t.Fatalf("admin subscribes to CLE-01's topic: %s %s, want not_found", typ, tok)
		}
		if typ, _ := subscribe(t, admW, r.shTask); typ != "subscribed" {
			t.Fatalf("CONTROL: admin subscribes to CLE-02's topic: %s", typ)
		}
	})

	t.Run("5_roster", func(t *testing.T) {
		boxes := func(hum string) map[string]bool {
			t.Helper()
			code, body := r.get(t, "/v1/view/roster", hum)
			var v struct {
				Boxes []struct {
					BoxID string `json:"box_id"`
				} `json:"boxes"`
			}
			if code != http.StatusOK || json.Unmarshal([]byte(body), &v) != nil {
				t.Fatalf("roster as %s: %d %s", hum, code, body)
			}
			out := map[string]bool{}
			for _, b := range v.Boxes {
				out[b.BoxID] = true
			}
			return out
		}
		if b := boxes(r.owner); !b["box-own"] || !b["box-sh"] {
			t.Fatalf("owner's roster %v, want both boxes", b)
		}
		if b := boxes(r.admin); b["box-own"] || !b["box-sh"] {
			t.Fatalf("admin's roster %v, want box-sh only", b)
		}
	})

	t.Run("5b_box_stats", func(t *testing.T) {
		for _, b := range []*box{r.own, r.sh} {
			s := `{"box":"` + b.id + `","load1":1,"load5":1,"load15":1,"cpus":8,"mem_total_kb":1000,"mem_avail_kb":600,"swap_used_kb":0,"agents_live":1}`
			if _, err := b.c.Lane(ctx, "box_stats_put", "", json.RawMessage(s)); err != nil {
				t.Fatalf("%s stat: %v", b.id, err)
			}
		}
		code, body := r.get(t, "/v1/tenant/box-stats?since=1d", r.admin)
		if code != http.StatusOK || strings.Contains(body, `"box-own"`) || !strings.Contains(body, `"box-sh"`) {
			t.Fatalf("admin's box stats: %d %s, want box-sh only", code, body)
		}
	})

	t.Run("6_file", func(t *testing.T) {
		if code, _ := r.get(t, "/v1/files/"+r.ownFile, r.owner); code != http.StatusOK {
			t.Fatalf("owner reads CLE-01's file: %d", code)
		}
		if code, _ := r.get(t, "/v1/files/"+r.ownFile, r.admin); code != http.StatusNotFound {
			t.Fatalf("admin reads CLE-01's file: %d, want 404", code)
		}
		if code, _ := r.get(t, "/v1/files/"+r.shFile, r.admin); code != http.StatusOK {
			t.Fatalf("CONTROL: admin reads CLE-02's file: %d", code)
		}
	})

	t.Run("8_pin_and_revoke_with_the_root_key", func(t *testing.T) {
		_, newKey, _ := ed25519.GenerateKey(nil)
		pin := func(box string) (int, map[string]any) {
			ts := time.Now().UTC().Format(time.RFC3339)
			k := base64.StdEncoding.EncodeToString(newKey.Public().(ed25519.PublicKey))
			payload, _ := wire.PinPayload(box, k, ts, true)
			return call(t, e, r.tid, http.MethodPost, "/v1/pins", "",
				wire.PinRequest{BoxID: box, PubKey: k, TS: ts, Force: true, Sig: sign.Sign(r.root, payload)})
		}
		before := r.refused(t, "pin")
		code, out := pin("box-own")
		r.wantLocked(t, "root key re-pins box-own", "pin", before, code, out)
		if code, out := pin("box-new"); code != http.StatusOK {
			t.Fatalf("CONTROL: root key pins box-new: %d %v", code, out)
		}
		ts := time.Now().UTC().Format(time.RFC3339)
		payload, _ := wire.RevokePayload("box-own", ts)
		before = r.refused(t, "revoke")
		code, out = call(t, e, r.tid, http.MethodDelete, "/v1/pins/box-own", "",
			wire.RevokeRequest{BoxID: "box-own", TS: ts, Sig: sign.Sign(r.root, payload)})
		r.wantLocked(t, "root key revokes box-own", "revoke", before, code, out)
	})

	t.Run("8b_list_pins", func(t *testing.T) {
		pins := func(tok string) string {
			t.Helper()
			code, _, body := viewGet(t, e, r.tid, "/v1/pins", "Authorization", "Bearer "+tok)
			if code != http.StatusOK {
				t.Fatalf("pins: %d %s", code, body)
			}
			return string(body)
		}
		if b := pins(r.shToken); strings.Contains(b, `"box-own"`) || !strings.Contains(b, `"box-sh"`) {
			t.Fatalf("box-sh's pin list %s, want no box-own", b)
		}
		if b := pins(r.ownToken); !strings.Contains(b, `"box-own"`) {
			t.Fatalf("box-own's own pin list %s, want box-own", b)
		}
	})

	t.Run("8c_join_and_seat_revoke", func(t *testing.T) {
		if sw, ok := e.st.(store.BoxJoinSwitch); ok {
			if err := sw.SetBoxJoinEnabled(ctx, r.tid, true); err != nil {
				t.Fatal(err)
			}
		}
		before := r.refused(t, "join_token")
		code, out := call(t, e, r.tid, http.MethodPost, "/v1/tenant/agents/join-tokens", r.admin, map[string]any{"box_id": "box-own"})
		r.wantLocked(t, "admin mints a join token for box-own", "join_token", before, code, out)
		if code, out := call(t, e, r.tid, http.MethodPost, "/v1/tenant/agents/join-tokens", r.admin, map[string]any{"box_id": "box-two"}); code != http.StatusCreated {
			t.Fatalf("CONTROL: admin mints a join token for box-two: %d %v", code, out)
		}
		before = r.refused(t, "seat_revoke")
		code, out = call(t, e, r.tid, http.MethodDelete, "/v1/tenant/agents/pins/box-own", r.admin, nil)
		r.wantLocked(t, "admin revokes box-own's seat", "seat_revoke", before, code, out)
	})

	t.Run("8d_sender_list_and_ai_agents", func(t *testing.T) {
		body := map[string]any{"members": []string{r.admin}}
		before := r.refused(t, "sender_allow")
		code, out := call(t, e, r.tid, http.MethodPut, "/v1/tenant/agent-senders/CLE-01", r.admin, body)
		r.wantLocked(t, "admin sets CLE-01's sender list", "sender_allow", before, code, out)
		if code, out := call(t, e, r.tid, http.MethodPut, "/v1/tenant/agent-senders/CLE-02", r.admin, body); code != http.StatusOK {
			t.Fatalf("CONTROL: admin sets CLE-02's sender list: %d %v", code, out)
		}
		before = r.refused(t, "channel_ai_agents")
		code, out = call(t, e, r.tid, http.MethodPut, "/v1/channels/ops/ai-agents", r.admin, map[string]any{"on": false})
		r.wantLocked(t, "admin switches #ops' AI agents", "channel_ai_agents", before, code, out)
	})

	t.Run("11_issue_assignee", func(t *testing.T) {
		before := r.refused(t, "issue_assign")
		code, out := call(t, e, r.tid, http.MethodPost, "/v1/issues", r.admin, map[string]any{"title": "look at the load", "assignee": "CLE-01"})
		r.wantLocked(t, "admin assigns CLE-01", "issue_assign", before, code, out)
		if code, out := call(t, e, r.tid, http.MethodPost, "/v1/issues", r.admin, map[string]any{"title": "look at the load", "assignee": "CLE-02"}); code != http.StatusCreated {
			t.Fatalf("CONTROL: admin assigns CLE-02: %d %v", code, out)
		}
		if code, out := call(t, e, r.tid, http.MethodPost, "/v1/issues", r.owner, map[string]any{"title": "look at the load", "assignee": "CLE-01"}); code != http.StatusCreated {
			t.Fatalf("owner assigns CLE-01: %d %v", code, out)
		}
	})
}

// Row B5 path 10b (R7 follow-up): the operator workspace's admin, not an
// owner of box-own's lock, reads the fleet load without box-own's band and
// order place, and a PATCH of the order or the bands that names box-own (new
// or stored) is a 403 box_locked with one refused audit row. CONTROL: a
// PATCH of the order without box-own lands while none is stored.
func TestBoxLockFleetLoadPaths(t *testing.T) {
	e, op, _, who, _ := operatorEnv(t, func(op, _ string) string { return op })
	ctx, admin := context.Background(), who[rbac.Admin]
	own := e.box(op, "box-own", "CLE-01")
	e.pin(op, own)
	lockTo(t, e, op, own, who[rbac.Developer])
	refused := func() int {
		t.Helper()
		rows, err := e.st.(store.BoxLockStore).BoxLockAudits(ctx, op, "box-own", 200)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for _, a := range rows {
			if a.Path == "operator_workspace" && a.Verdict == store.BoxLockRefused {
				n += a.Count
			}
		}
		return n
	}
	locked := func(what string, body map[string]any) {
		t.Helper()
		before := refused()
		code, out := call(t, e, op, http.MethodPatch, fleetLoadPath, admin, body)
		if code != http.StatusForbidden || out["error"] != "box_locked" || refused()-before != 1 {
			t.Fatalf("%s: %d %v, refused +%d; want 403 box_locked, +1", what, code, out, refused()-before)
		}
	}
	if code, out := call(t, e, op, http.MethodPatch, fleetLoadPath, admin, map[string]any{"box_order": []string{"box-a"}}); code != http.StatusOK {
		t.Fatalf("CONTROL: admin orders box-a: %d %v", code, out)
	}
	locked("admin orders box-own", map[string]any{"box_order": []string{"box-own", "box-a"}})
	locked("admin bands box-own", map[string]any{"boxes": map[string]any{"box-own": map[string]any{"low": 10, "high": 20}}})
	fl := e.st.(store.FleetLoadTarget)
	if _, err := fl.SetFleetLoad(ctx, op, store.FleetLoadPatch{OrderSet: true, BoxOrder: []string{"box-own", "box-a"}}); err != nil {
		t.Fatal(err)
	}
	code, out := call(t, e, op, http.MethodGet, fleetLoadPath, admin, nil)
	if o, _ := out["box_order"].([]any); code != http.StatusOK || len(o) != 1 || o[0] != "box-a" {
		t.Fatalf("admin reads the fleet load: %d %v, want box_order [box-a]", code, out["box_order"])
	}
	locked("admin re-orders over a stored box-own", map[string]any{"box_order": []string{"box-a"}})
}
