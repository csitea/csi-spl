package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 067 L4 (dm_ref.go): a DM claims the channel topic it is about as the
// send frame's ref_task_id, kept only when the sender may read the topic and
// inherited by later DMs of the thread; a PERSON's DM to an agent on such a
// thread is also stored in the topic as a reply with mirror_of = the DM, in
// the same transaction; edits and archives of the DM follow to the copy; no
// copy is ever copied again; and nothing of it reaches a box envelope.
// Memory, and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

// dmRefRig: HUM-1 is in the private #dm-ref, HUM-2 is not; topic is a topic
// in #dm-ref; agent CLE-07 on box-a (pinned, with box-wui pinned so a
// person's DM to it is a signed dispatch, as on prd), not in #dm-ref.
type dmRefRig struct {
	t      *testing.T
	e      *env
	tid    string
	a      *box
	rb     *rawBox
	w1, w2 *websocket.Conn
	topic  string
	other  string // the topic's unrelated reply, which nothing may touch
}

const dmRefChannel = "dm-ref"

func newDMRefRig(t *testing.T) *dmRefRig {
	t.Helper()
	pub, key, _ := ed25519.GenerateKey(nil)
	e := dispatchEnv(t, true, key)
	tid, root := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	if err := e.st.SetRoster(ctx, tid, "box-a", []string{"CLE-07"}, now); err != nil {
		t.Fatal(err)
	}
	if code, eb := e.postPin(tid, root, hub.WUIBox, b64(pub)); code != http.StatusOK {
		t.Fatalf("pin box-wui: %d %+v", code, eb)
	}
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: dmRefChannel,
		Name: dmRefChannel, CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, dmRefChannel, []string{"HUM-1"}, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	r := &dmRefRig{t: t, e: e, tid: tid, a: a, topic: uuidV4()}
	putRow(t, e, tid, r.topic, dmRefChannel, "HUM-1", "CLE-07", "the topic", now.Add(-time.Minute))
	r.other = putRow(t, e, tid, r.topic, dmRefChannel, "HUM-1", "CLE-07", "an unrelated reply", now.Add(-time.Second)).MsgID
	r.rb = e.rawBox(tid, a, []string{"CLE-07"}, nil)
	t.Cleanup(func() { r.rb.c.CloseNow() }) //nolint:errcheck
	r.w1 = dialMember(t, e, tid, "HUM-1", "HUM-1")
	r.w2 = dialMember(t, e, tid, "HUM-2", "HUM-2")
	return r
}

// dm sends a person's DM to CLE-07 on task through the browser socket and
// answers its msg_id; ref "" claims none.
func (r *dmRefRig) dm(w *websocket.Conn, id, task, ref, body string) string {
	r.t.Helper()
	f := map[string]any{"type": "send", "msg_id": id, "task_id": task, "kind": "note", "body": body, "to": "CLE-07"}
	if ref != "" {
		f["ref_task_id"] = ref
	}
	wsjson.Write(context.Background(), w, f) //nolint:errcheck
	if ack := readType(r.t, w, "ack"); ack["type"] != "ack" || ack["msg_id"] != id {
		r.t.Fatalf("dm on %s: %v", task, ack)
	}
	return id
}

// agentDM sends CLE-07's DM to HUM-1 on task from box-a, the frame claiming
// ref ("" = none).
func (r *dmRefRig) agentDM(task, ref, body string) string {
	r.t.Helper()
	m := &msg.Message{V: 1, MsgID: uuidV4(), TaskID: task, TS: time.Now().UTC().Format(time.RFC3339),
		From: "CLE-07", To: "HUM-1", Kind: "note", Body: body, Files: []msg.Attachment{}}
	raw, err := signedIn(r.t, r.a, hub.WUIBox, "", "", m).Marshal()
	if err != nil {
		r.t.Fatal(err)
	}
	wsjson.Write(context.Background(), r.rb.c, wire.Frame{Type: wire.TSend, Env: raw, RefTaskID: ref}) //nolint:errcheck
	if f := r.rb.next(wire.TSent); f.MsgID != m.MsgID {
		r.t.Fatalf("agent dm on %s: %+v", task, f)
	}
	return m.MsgID
}

// row is the stored view row id of task.
func (r *dmRefRig) row(task, id string) store.ViewMsg {
	r.t.Helper()
	for _, v := range r.rows(task) {
		if v.MsgID == id {
			return v
		}
	}
	r.t.Fatalf("no row %s on task %s", id, task)
	return store.ViewMsg{}
}

func (r *dmRefRig) rows(task string) []store.ViewMsg {
	r.t.Helper()
	got, err := r.e.st.ViewTopic(context.Background(), r.tid, store.TopicMsgQuery{TaskID: task, Limit: 100, Now: time.Now()})
	if err != nil {
		r.t.Fatal(err)
	}
	return got
}

// copies are the topic's rows that mirror a DM, by the DM they mirror.
func (r *dmRefRig) copies() map[string]store.ViewMsg {
	r.t.Helper()
	out := map[string]store.ViewMsg{}
	for _, v := range r.rows(r.topic) {
		if v.MirrorOf != "" {
			if _, dup := out[v.MirrorOf]; dup {
				r.t.Fatalf("DM %s mirrored twice", v.MirrorOf)
			}
			out[v.MirrorOf] = v
		}
	}
	return out
}

func (r *dmRefRig) stored(id string) store.EditableMessage {
	r.t.Helper()
	m, err := r.e.st.GetEditable(context.Background(), r.tid, id, time.Now())
	if err != nil {
		r.t.Fatal(err)
	}
	return m
}

// Rules 3 and 4: the claim is kept, the person's answer is in the topic with
// mirror_of, a later DM of the thread inherits the ref and is mirrored too.
// CONTROLS: a DM claiming nothing on a fresh thread, and claims that are not
// a channel topic (no uuid, a DM task), are plain DMs.
func TestDMRefMirrorsPersonAnswer(t *testing.T) {
	r := newDMRefRig(t)
	d := uuidV4()
	first := r.dm(r.w1, uuidV4(), d, strings.ToUpper(r.topic), "my answer, in the DM")
	if v := r.row(d, first); v.RefTaskID != r.topic || v.RowChannel != "" || v.MirrorOf != "" {
		t.Fatalf("the DM: ref_task_id %q channel %q mirror_of %q, want %q, a DM, no mirror_of", v.RefTaskID, v.RowChannel, v.MirrorOf, r.topic)
	}
	cp, ok := r.copies()[first]
	if !ok {
		t.Fatalf("no copy of the person's DM answer in the topic: %+v", r.rows(r.topic))
	}
	if cp.RowChannel != dmRefChannel || cp.IsParent != 0 || cp.RefTaskID != "" || !bytes.Contains(cp.Env, []byte("my answer, in the DM")) {
		t.Fatalf("copy: channel %q is_parent %d ref %q env %s", cp.RowChannel, cp.IsParent, cp.RefTaskID, cp.Env)
	}
	if s := r.stored(cp.MsgID); !strings.HasPrefix(s.FromID, "HUM-") || s.ToID != "CLE-07" || s.ToBox != hub.WUIBox || s.TaskID != r.topic {
		t.Fatalf("copy row: from %q to %q to_box %q task %q", s.FromID, s.ToID, s.ToBox, s.TaskID)
	}

	second := r.dm(r.w1, uuidV4(), d, "", "a second line, claiming nothing")
	if v := r.row(d, second); v.RefTaskID != r.topic {
		t.Fatalf("a DM reply did not inherit the thread's ref: %q", v.RefTaskID)
	}
	if _, ok := r.copies()[second]; !ok {
		t.Fatal("the inheriting DM answer was not mirrored")
	}

	for _, c := range []struct{ name, ref string }{
		{"no claim on a fresh thread (edge 1)", ""},
		{"a claim that is no uuid", "not-a-uuid"},
		{"a claim naming a DM task, not a channel topic", d},
	} {
		task := uuidV4()
		id := r.dm(r.w1, uuidV4(), task, c.ref, "a plain DM")
		if v := r.row(task, id); v.RefTaskID != "" {
			t.Errorf("CONTROL %s: ref_task_id %q kept", c.name, v.RefTaskID)
		}
		if _, ok := r.copies()[id]; ok {
			t.Errorf("CONTROL %s: mirrored", c.name)
		}
	}
	if n := len(r.copies()); n != 2 {
		t.Fatalf("%d copies in the topic, want 2", n)
	}
}

// Q5: an agent's DM is never mirrored, whether it inherits the ref or claims
// one. CONTROL: the agent's claim on a topic it is not in is dropped, the
// same claim on a topic it is in (#lobby) is kept - the door is the agent's.
func TestDMRefNotForAgentToPerson(t *testing.T) {
	r := newDMRefRig(t)
	d := uuidV4()
	r.dm(r.w1, uuidV4(), d, r.topic, "the person's answer")
	reply := r.agentDM(d, "", "the agent's DM reply")
	if v := r.row(d, reply); v.RefTaskID != r.topic {
		t.Fatalf("the agent's DM reply did not inherit the ref: %q", v.RefTaskID)
	}
	if n := len(r.copies()); n != 1 {
		t.Fatalf("%d copies after an agent's DM reply, want the person's 1", n)
	}

	own := uuidV4()
	kept := r.agentDM(own, lobby, "about a lobby topic")
	if v := r.row(own, kept); v.RefTaskID != lobby {
		t.Fatalf("CONTROL: the agent's claim on #lobby, which it may read, was dropped: %q", v.RefTaskID)
	}
	if n := len(r.copies()); n != 1 {
		t.Fatalf("an agent's DM was mirrored: %d copies", n)
	}
	for _, v := range r.rows(lobby) {
		if v.MirrorOf != "" {
			t.Fatalf("an agent's DM was mirrored into #lobby: %+v", v)
		}
	}
	dropped := uuidV4()
	if v := r.row(dropped, r.agentDM(dropped, r.topic, "about a topic in a channel I am not in")); v.RefTaskID != "" {
		t.Fatalf("the agent's claim on #%s, which it is not in, was kept", dmRefChannel)
	}
}

// Edge case 2 and section 7: a claim on a topic the person cannot read is
// dropped and nothing is mirrored; an inherited ref is mirrored only while the
// channel is open. CONTROL: the same claim by the member is kept and mirrored.
func TestDMRefNotIntoUnreadableChannel(t *testing.T) {
	r := newDMRefRig(t)
	ctx := context.Background()
	outsider := uuidV4()
	id := r.dm(r.w2, uuidV4(), outsider, r.topic, "an outsider's DM about a private topic")
	if v := r.row(outsider, id); v.RefTaskID != "" {
		t.Fatalf("a claim on a topic the sender cannot read was kept: %q", v.RefTaskID)
	}
	if n := len(r.copies()); n != 0 {
		t.Fatalf("mirrored into a channel the person cannot see: %d copies", n)
	}

	d := uuidV4()
	member := r.dm(r.w1, uuidV4(), d, r.topic, "the member's DM about it")
	if _, ok := r.copies()[member]; !ok || r.row(d, member).RefTaskID != r.topic {
		t.Fatal("CONTROL: the member's same claim was not kept and mirrored")
	}

	if err := r.e.st.ArchiveChannel(ctx, r.tid, dmRefChannel, "HUM-1", time.Now()); err != nil {
		t.Fatal(err)
	}
	later := r.dm(r.w1, uuidV4(), d, "", "a DM after the channel was archived")
	if v := r.row(d, later); v.RefTaskID != r.topic {
		t.Fatalf("the thread's ref was not inherited: %q", v.RefTaskID)
	}
	if _, ok := r.copies()[later]; ok {
		t.Fatal("mirrored into an archived channel")
	}
}

// Edge case 3: an edit and an archive of the DM are applied to its copy (in
// the store's same transaction). CONTROL: the topic's unrelated reply is
// untouched by both.
func TestDMRefEditAndArchiveFollow(t *testing.T) {
	r := newDMRefRig(t)
	d := uuidV4()
	id := r.dm(r.w1, uuidV4(), d, r.topic, "the first wording")
	cp := r.copies()[id]
	if cp.MsgID == "" {
		t.Fatal("no copy")
	}

	if code, out := call(t, r.e, r.tid, http.MethodPatch, "/v1/messages/"+id, "HUM-1", map[string]string{"body": "the second wording"}); code != http.StatusOK {
		t.Fatalf("edit the DM: %d %v", code, out)
	}
	if s := r.stored(cp.MsgID); s.Body != "the second wording" || s.EditedAt.IsZero() || !strings.HasPrefix(s.EditedBy, "HUM-") {
		t.Fatalf("copy after the edit: body %q edited_at %v by %q", s.Body, s.EditedAt, s.EditedBy)
	}
	env := r.row(r.topic, cp.MsgID).Env
	if !bytes.Contains(env, []byte("the second wording")) || bytes.Contains(env, []byte("the first wording")) {
		t.Fatalf("the copy's envelope did not follow the edit: %s", env)
	}
	inner, err := wire.ParseEnvelope(env)
	if err != nil {
		t.Fatal(err)
	}
	if m, err := inner.Inner(); err != nil || m.MsgID != cp.MsgID || m.TaskID != r.topic {
		t.Fatalf("the edited copy's inner msg: %v %+v", err, m)
	}
	if revs, err := r.e.st.MessageRevisions(context.Background(), r.tid, cp.MsgID); err != nil || len(revs) != 2 {
		t.Fatalf("copy revisions: %v %d, want 2", err, len(revs))
	}

	archived := func(id string) bool {
		t.Helper()
		c, err := r.e.st.CardState(context.Background(), r.tid, id, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		return !c.ArchivedAt.IsZero()
	}
	if code, out := call(t, r.e, r.tid, http.MethodPut, "/v1/messages/"+id+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("archive the DM: %d %v", code, out)
	}
	if !archived(id) || !archived(cp.MsgID) {
		t.Fatalf("after archive: DM %v, copy %v", archived(id), archived(cp.MsgID))
	}
	if code, out := call(t, r.e, r.tid, http.MethodDelete, "/v1/messages/"+id+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("unarchive the DM: %d %v", code, out)
	}
	if archived(cp.MsgID) {
		t.Fatal("the copy stayed archived after the DM was restored")
	}

	if s := r.stored(r.other); s.Body != "an unrelated reply" || !s.EditedAt.IsZero() || archived(r.other) {
		t.Fatalf("CONTROL: the unrelated reply changed: body %q edited %v archived %v", s.Body, s.EditedAt, archived(r.other))
	}
}

// Edge case 5: one copy per DM, ever. A resend of the DM, the agent's DM
// reply and the copy itself are never mirrored; no copy has a copy.
func TestDMRefNoLoop(t *testing.T) {
	r := newDMRefRig(t)
	d := uuidV4()
	id := uuidV4()
	r.dm(r.w1, id, d, r.topic, "once")
	r.dm(r.w1, id, d, r.topic, "once") // the browser's resend of the same msg_id
	r.agentDM(d, "", "the agent answers in the DM")
	cs := r.copies()
	if len(cs) != 1 {
		t.Fatalf("%d copies, want 1", len(cs))
	}
	cp := cs[id]
	if cp.RefTaskID != "" {
		t.Fatalf("the copy carries ref_task_id %q: it could be mirrored again", cp.RefTaskID)
	}
	for _, v := range r.rows(r.topic) {
		if v.MirrorOf == cp.MsgID {
			t.Fatalf("the copy was copied: %s", v.MsgID)
		}
	}
	for _, v := range r.rows(d) {
		if v.MirrorOf != "" {
			t.Fatalf("a copy landed in the DM thread: %+v", v)
		}
	}
}

// preL3Msg is msg.Message as a box binary older than rdb 0112's L3 (commit
// 31053328) decodes it: the same strict decoder (msg.Parse disallows unknown
// keys) without ref_task_id.
type preL3Msg struct {
	V      int               `json:"v"`
	MsgID  string            `json:"msg_id"`
	TaskID string            `json:"task_id"`
	TS     string            `json:"ts"`
	From   string            `json:"from"`
	To     string            `json:"to"`
	Kind   string            `json:"kind"`
	Body   string            `json:"body"`
	Files  []json.RawMessage `json:"files"`
	Sig    string            `json:"sig,omitempty"`
}

func preL3Parse(raw []byte) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var m preL3Msg
	return dec.Decode(&m)
}

// L3's warning: the envelope a box receives for a DM that claimed a topic
// carries no ref_task_id, so a box binary that predates it still parses it.
// CONTROL: the same strict decode refuses an inner msg that does carry it.
func TestDMRefOldBoxEnvelope(t *testing.T) {
	r := newDMRefRig(t)
	id := r.dm(r.w1, uuidV4(), uuidV4(), r.topic, "dispatched to box-a")
	if r.copies()[id].MsgID == "" {
		t.Fatal("no copy: the claim did not take, so this test proves nothing")
	}
	var boxEnv []byte // what box-a is pushed
	for f := r.rb.next(wire.TRecv); ; f = r.rb.next(wire.TRecv) {
		if e, err := wire.ParseEnvelope(f.Env); err == nil {
			if m, err := e.Inner(); err == nil && m.MsgID == id {
				boxEnv = f.Env
				break
			}
		}
	}
	if bytes.Contains(boxEnv, []byte("ref_task_id")) || bytes.Contains(boxEnv, []byte("mirror_of")) {
		t.Fatalf("the box-bound envelope carries the hub-only fields: %s", boxEnv)
	}
	env, err := wire.ParseEnvelope(boxEnv)
	if err != nil {
		t.Fatal(err)
	}
	if env.ToBox != "box-a" || env.Sig == "" {
		t.Fatalf("not the signed dispatch to box-a: %+v", env)
	}
	if err := preL3Parse(env.Msg); err != nil {
		t.Fatalf("a pre-L3 box refuses the DM's envelope: %v", err)
	}

	m, err := env.Inner()
	if err != nil {
		t.Fatal(err)
	}
	m.RefTaskID = r.topic
	carrying, err := msg.Canonical(m)
	if err != nil {
		t.Fatal(err)
	}
	if err := preL3Parse(carrying); err == nil {
		t.Fatal("CONTROL: the pre-L3 decode accepted an inner msg with ref_task_id, so it proves nothing")
	}
}
