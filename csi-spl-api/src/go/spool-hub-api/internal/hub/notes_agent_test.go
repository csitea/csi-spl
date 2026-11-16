package hub_test

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"net/http"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 155 v1.5 section 2.11, build row B12: an agent adds a note on a
// person's ask over its box socket (note_add), cases C35-C39. Memory, and
// Postgres under SPOOL_TEST_PG_DSN (hub-live-stack.sh). The agent calls go
// through the real front end: action.NoteAdd (== `spool note add`) or the
// hubclient session verb, on a pinned box-a that announces a-101..a-103.

// agentNotesStore is the hub's store with three seams the fixtures cannot
// reach through the store API: an act-as clone row (live or ended), a spec
// 169 copy (CopiedFrom) and a disabled human (humans.disabled_at, which both
// stores answer as no seat at all). Everything else is the real store.
type agentNotesStore struct {
	store.Store
	store.Realm
	store.Notes
	store.MembershipLister
	store.DedicatedStore
	mu       sync.Mutex
	clones   map[string]*time.Time // human -> ended_at (nil = live)
	copied   map[string]bool       // msg_id -> a spec 169 copy
	disabled map[string]bool       // human -> humans.disabled_at set
}

func (s *agentNotesStore) Clone(_ context.Context, tenant, clone string) (store.Clone, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if ended, ok := s.clones[clone]; ok {
		return store.Clone{CloneHum: clone, TenantID: tenant, EndedAt: ended}, nil
	}
	return store.Clone{}, store.ErrNotFound
}

func (s *agentNotesStore) GetEditable(ctx context.Context, tenant, msgID string, now time.Time) (store.EditableMessage, error) {
	m, err := s.Store.GetEditable(ctx, tenant, msgID, now)
	s.mu.Lock()
	defer s.mu.Unlock()
	if err == nil && s.copied[msgID] {
		m.CopiedFrom = "00000000-0000-4000-8000-000000000001"
	}
	return m, err
}

func (s *agentNotesStore) Memberships(ctx context.Context, human string) ([]store.Membership, error) {
	s.mu.Lock()
	off := s.disabled[human]
	s.mu.Unlock()
	if off {
		return nil, nil
	}
	return s.MembershipLister.Memberships(ctx, human)
}

// agentNotesRig: P1 (the signed-in owner of W1), asker A (a developer of
// W1, signed in on its own browser), box-a pinned in W1 announcing
// a-101..a-103, and channel #plan with a-101 seated on box-a.
type agentNotesRig struct {
	n    *notesRig
	st   *agentNotesStore
	box  *box
	askC *http.Client
	ask  string // A's HUM id
}

const (
	notesAgent  = "a-101"
	notesBoxA   = "box-a"
	notesPlanCh = "plan"
)

func newAgentNotesRig(t *testing.T, notesOn, agentOn bool) *agentNotesRig {
	t.Helper()
	st := &agentNotesStore{clones: map[string]*time.Time{}, copied: map[string]bool{}, disabled: map[string]bool{}}
	buf := &lockedBuf{}
	r, _, w1 := realmRigAs(t, buf, "notes-agent-"+freshEmail(), func(o *hub.Options) {
		o.NotesEnabled, o.NotesAgentAddEnabled = notesOn, agentOn
		st.Store, st.Realm, st.Notes = o.Store, o.Store.(store.Realm), o.Store.(store.Notes)
		st.MembershipLister, st.DedicatedStore = o.Store.(store.MembershipLister), o.Store.(store.DedicatedStore)
		o.Store = st
	})
	n := &notesRig{r: r, logs: buf, w1: w1, p1: r.session(t).HumanID}
	g := &agentNotesRig{n: n, st: st}
	g.askC, g.ask = n.browserAs(t, w1, rbac.Developer)
	g.channel(t, notesPlanCh, notesAgent)
	g.box = r.e.box(w1, notesBoxA, "a-101", "a-102", "a-103")
	r.e.pin(w1, g.box)
	return g
}

// channel creates ch in W1 and seats agents on box-a there.
func (g *agentNotesRig) channel(t *testing.T, ch string, agents ...string) {
	t.Helper()
	ctx, now := context.Background(), time.Now().UTC()
	if err := g.n.r.e.st.CreateChannel(ctx, store.Channel{TenantID: g.n.w1, ChannelID: ch, Name: ch, CreatedBy: g.n.p1, CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	for _, a := range agents {
		if err := g.n.r.e.st.InviteChannelAgent(ctx, g.n.w1, ch, notesBoxA, a, now); err != nil {
			t.Fatal(err)
		}
	}
}

// notesMsg is one stored message: the fields the read door and the author
// check look at.
type notesMsg struct {
	tenant, task, channel, fromBox, fromID, toBox, toID string
}

// put stores m as a live message and answers its msg_id; task "" = a new topic.
func (g *agentNotesRig) put(t *testing.T, m notesMsg) (msgID, task string) {
	t.Helper()
	if m.tenant == "" {
		m.tenant = g.n.w1
	}
	if m.task == "" {
		m.task = uuidV4()
	}
	msgID = uuidV4()
	now := time.Now().UTC().Truncate(time.Microsecond)
	body := "please add a note for me"
	inner, _ := json.Marshal(map[string]any{"v": 1, "msg_id": msgID, "task_id": m.task, "ts": now.Format(time.RFC3339Nano),
		"from": m.fromID, "to": m.toID, "kind": "note", "body": body, "files": []any{}})
	env, _ := json.Marshal(map[string]any{"from_box": m.fromBox, "to_box": m.toBox, "channel": m.channel, "msg": json.RawMessage(inner), "sig": ""})
	row := store.Message{TenantID: m.tenant, MsgID: msgID, TaskID: m.task, Channel: m.channel, TS: now, IsParent: 1,
		FromBox: m.fromBox, FromID: m.fromID, ToBox: m.toBox, ToID: m.toID, Kind: "note", Body: body,
		Files: []byte("[]"), Msg: inner, Env: env, ReceivedAt: now, ExpiresAt: now.Add(30 * 24 * time.Hour)}
	if _, err := g.n.r.e.st.InsertMessage(context.Background(), row); err != nil {
		t.Fatal(err)
	}
	return msgID, m.task
}

// askIn posts A's ask in #plan (where a-101 sits) and answers its msg_id.
func (g *agentNotesRig) askIn(t *testing.T, from string) string {
	t.Helper()
	id, _ := g.put(t, notesMsg{channel: notesPlanCh, fromBox: hub.WUIBox, fromID: from, toBox: hub.WUIBox, toID: notesAgent})
	return id
}

// add sends one note_add as agent through action.NoteAdd (`spool note add`).
func (g *agentNotesRig) add(t *testing.T, in action.NoteAddArgs) (map[string]any, error) {
	t.Helper()
	in.Hub = g.box.c
	raw, err := action.NoteAdd(context.Background(), g.box.cfg, in)
	if err != nil {
		return nil, err
	}
	out := map[string]any{}
	if jerr := json.Unmarshal(raw, &out); jerr != nil {
		t.Fatalf("reply %s: %v", raw, jerr)
	}
	return out, nil
}

// addRaw sends one note_add frame with the note object as given.
func (g *agentNotesRig) addRaw(t *testing.T, as string, note map[string]any) error {
	t.Helper()
	raw, _ := json.Marshal(note)
	_, err := g.box.c.NoteAdd(context.Background(), as, raw)
	return err
}

// hubErr asserts err is a hub refusal with token and status.
func hubErr(t *testing.T, what string, err error, token string, status int) *hubclient.HubError {
	t.Helper()
	var he *hubclient.HubError
	if !errors.As(err, &he) || he.Token != token || he.Status != status {
		t.Errorf("%s: %v, want %d %s", what, err, status, token)
		return nil
	}
	return he
}

// notesOf counts the person's notes in the store.
func (g *agentNotesRig) notesOf(t *testing.T, person string) int {
	t.Helper()
	ns, err := g.n.r.e.st.(store.Notes).ListNotes(context.Background(), person)
	if err != nil {
		t.Fatal(err)
	}
	return len(ns)
}

// seat makes a fresh human seated with role in tid and in each of also
// (operator invites, one identity).
func (g *agentNotesRig) seat(t *testing.T, tid, role string, also ...string) string {
	t.Helper()
	h := g.n.r.e.st.(store.Humans)
	email, now := freshEmail(), time.Now()
	var hum string
	for _, w := range append([]string{tid}, also...) {
		if err := h.PutInvite(context.Background(), store.Invite{TenantID: w, Email: email, Role: role,
			InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
		got, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-" + email, Email: email}, w, store.AdmitPolicy{}, now)
		if err != nil || (hum != "" && got != hum) {
			t.Fatalf("admit %s to %s: %s %v", email, w, got, err)
		}
		hum = got
	}
	return hum
}

// C35 (OQ-1 A, OQ-2, OQ-3): a member who is not the owner asks in a topic
// a-101 reads; a-101 adds a note with every WUI field, then a second note on
// the same ask. Both answer {msg_id, id, created_at} alone; A reads every
// field plus the provenance on GET /{id} and /export; P1 gets 404 / 0 rows.
func TestNotesC35AgentAdd(t *testing.T) {
	g := newAgentNotesRig(t, true, true)
	ask := g.askIn(t, g.ask)
	topic := uuidV4()
	in := action.NoteAddArgs{As: notesAgent, AskMsgID: ask, Title: "Plan", Body: "the body", Priority: 2, Pinned: true,
		Items: []action.NoteItemArg{{Text: "one"}, {Text: "two", Done: true}},
		Links: []action.NoteLinkArg{{Kind: "topic", Ref: topic, Label: "the topic"}, {Kind: "url", Ref: "https://example.com/a"}}}
	first, err := g.add(t, in)
	if err != nil {
		t.Fatal(err)
	}
	if keys := slices.Sorted(maps.Keys(first)); strings.Join(keys, ",") != "created_at,id,msg_id" || first["msg_id"] == "" {
		t.Fatalf("reply = %v, want exactly msg_id, id, created_at", first)
	}
	second, err := g.add(t, action.NoteAddArgs{As: notesAgent, AskMsgID: ask, Title: "again"})
	if err != nil || second["id"] == first["id"] {
		t.Fatalf("a second note on the same ask: %v %v, want a new note (OQ-3)", second, err)
	}
	id := first["id"].(string)
	code, out, _ := g.n.do(t, g.askC, http.MethodGet, notesBase+"/"+id, nil, nil)
	if code != http.StatusOK {
		t.Fatalf("A GET = %d %v", code, out)
	}
	want := map[string]any{"title": "Plan", "body": "the body", "priority": float64(2), "pinned": true, "archived": false,
		"added_by_agent": notesAgent + "@" + notesBoxA, "ask_msg_id": ask, "ask_workspace_id": g.n.w1}
	for k, v := range want {
		if out[k] != v {
			t.Errorf("A GET %s = %v, want %v", k, out[k], v)
		}
	}
	if items, _ := out["items"].([]any); len(items) != 2 || items[1].(map[string]any)["done"] != true {
		t.Errorf("items = %v", out["items"])
	}
	links, _ := out["links"].([]any)
	if len(links) != 2 {
		t.Fatalf("links = %v, want 2", out["links"])
	}
	if l := links[0].(map[string]any); l["kind"] != "topic" || l["ref"] != topic || l["label"] != "the topic" || l["workspace_id"] != g.n.w1 {
		t.Errorf("the topic link (it takes the ask's workspace) = %v", l)
	}
	if l := links[1].(map[string]any); l["kind"] != "url" || l["ref"] != "https://example.com/a" || l["workspace_id"] != nil {
		t.Errorf("the url link = %v", l)
	}
	_, ex, _ := g.n.do(t, g.askC, http.MethodGet, notesBase+"/export", nil, nil)
	if got := exportProvenance(ex); got[id] != notesAgent+"@"+notesBoxA || got[second["id"].(string)] == "" {
		t.Errorf("export provenance = %v", got)
	}
	if code, _, _ := g.n.do(t, nil, http.MethodGet, notesBase+"/"+id, nil, nil); code != http.StatusNotFound {
		t.Errorf("P1 GET A's note = %d, want 404", code)
	}
	if _, ok := exportProvenance(mustExport(t, g.n))[id]; ok {
		t.Error("P1's export holds A's note")
	}
}

func mustExport(t *testing.T, n *notesRig) map[string]any {
	t.Helper()
	code, out, _ := n.do(t, nil, http.MethodGet, notesBase+"/export", nil, nil)
	if code != http.StatusOK {
		t.Fatalf("export = %d %v", code, out)
	}
	return out
}

// exportProvenance maps each exported note id to its added_by_agent.
func exportProvenance(out map[string]any) map[string]string {
	got := map[string]string{}
	ns, _ := out["notes"].([]any)
	for _, x := range ns {
		m := x.(map[string]any)
		a, _ := m["added_by_agent"].(string)
		got[m["id"].(string)] = a
	}
	return got
}

// C36: the sender and the author gates. An unannounced as and as = HUM-*
// are 403 from_not_announced; an ask written by a box, a spec 169 copy, a
// live and an ended act-as clone, a non-person seat, a disabled human and a
// member removed after posting are 403 ask_not_person; 0 notes created.
// Twin: C35's member ask is 201.
func TestNotesC36AskerGates(t *testing.T) {
	g := newAgentNotesRig(t, true, true)
	ask := g.askIn(t, g.ask)
	for _, as := range []string{"a-199", "HUM-1"} {
		_, err := g.add(t, action.NoteAddArgs{As: as, AskMsgID: ask, Title: "x"})
		hubErr(t, "as "+as, err, hub.TokenFromNotAnnounced, http.StatusForbidden)
	}
	ctx, now := context.Background(), time.Now().UTC()
	byBox, _ := g.put(t, notesMsg{channel: notesPlanCh, fromBox: notesBoxA, fromID: g.ask, toBox: hub.WUIBox, toID: notesAgent})
	copied := g.askIn(t, g.ask)
	g.st.copied[copied] = true
	live, ended := g.seat(t, g.n.w1, rbac.Developer), g.seat(t, g.n.w1, rbac.Developer)
	g.st.clones[live], g.st.clones[ended] = nil, &now
	agentSeat := g.seat(t, g.n.w1, rbac.PureAgent)
	disabled := g.seat(t, g.n.w1, rbac.Developer)
	g.st.disabled[disabled] = true
	removed := g.seat(t, g.n.w1, rbac.Developer)
	w2, _ := g.n.r.e.tenant()
	elsewhere := g.seat(t, g.n.w1, rbac.Developer, w2) // keeps a person seat in W2 only
	cases := map[string]string{"box-sent": byBox, "spec 169 copy": copied, "live clone": g.askIn(t, live),
		"ended clone": g.askIn(t, ended), "agent seat": g.askIn(t, agentSeat), "disabled human": g.askIn(t, disabled),
		"removed member": g.askIn(t, removed), "removed here, seated in W2": g.askIn(t, elsewhere)}
	rm := g.n.r.e.st.(interface {
		RemoveMember(ctx context.Context, tenant, humanID string) error
	})
	for _, h := range []string{removed, elsewhere} {
		if err := rm.RemoveMember(ctx, g.n.w1, h); err != nil {
			t.Fatal(err)
		}
	}
	for what, m := range cases {
		_, err := g.add(t, action.NoteAddArgs{As: notesAgent, AskMsgID: m, Title: "x"})
		hubErr(t, what, err, "ask_not_person", http.StatusForbidden)
	}
	for _, p := range []string{g.ask, live, ended, agentSeat, disabled, removed, elsewhere} {
		if n := g.notesOf(t, p); n != 0 {
			t.Errorf("%s holds %d notes after the refusals, want 0", p, n)
		}
	}
	if _, err := g.add(t, action.NoteAddArgs{As: notesAgent, AskMsgID: ask, Title: "twin"}); err != nil {
		t.Errorf("CONTROL: the member's own ask: %v", err)
	}
}

// C37: the per-agent read door (agentReadsAsk), no oracle. Every case is
// 404 not_found with the same detail as an unknown uuid and adds no note;
// twins: a-102 on its DM and its #ch2 seat, a-103 on its bound private
// channel, a-101 on a topic it posted in.
func TestNotesC37ReadDoor(t *testing.T) {
	g := newAgentNotesRig(t, true, true)
	ctx, now := context.Background(), time.Now().UTC()
	ds := g.n.r.e.st.(store.DedicatedStore)
	g.channel(t, "ch2", "a-102", "a-103")
	g.channel(t, "vault", "a-101", "a-103")
	if err := ds.SetPrivateScope(ctx, g.n.w1, store.ScopeChannel, "vault", true, now); err != nil {
		t.Fatal(err)
	}
	if _, err := ds.SetDedicatedBinding(ctx, store.DedicatedBinding{TenantID: g.n.w1, AgentID: "a-103", BoxID: notesBoxA,
		ScopeType: store.ScopeChannel, ScopeID: "vault", BoundBy: g.n.p1}); err != nil {
		t.Fatal(err)
	}
	w2, _ := g.n.r.e.tenant()
	from := func(ch, toBox, toID string) notesMsg {
		return notesMsg{channel: ch, fromBox: hub.WUIBox, fromID: g.ask, toBox: toBox, toID: toID}
	}
	inW2 := from("", hub.WUIBox, notesAgent)
	inW2.tenant = w2
	otherBox, _ := g.put(t, from("", "box-b", "b-101"))
	dmA2, _ := g.put(t, from("", notesBoxA, "a-102"))
	ch2, _ := g.put(t, from("ch2", hub.WUIBox, "a-102"))
	vault, _ := g.put(t, from("vault", hub.WUIBox, "a-103"))
	privTopic, privTask := g.put(t, from(notesPlanCh, hub.WUIBox, "HUM-1"))
	if err := ds.SetPrivateScope(ctx, g.n.w1, store.ScopeTopic, privTask, true, now); err != nil {
		t.Fatal(err)
	}
	_, part := g.put(t, notesMsg{fromBox: notesBoxA, fromID: notesAgent, toBox: "box-b", toID: "b-101"})
	inPart, _ := g.put(t, notesMsg{task: part, fromBox: hub.WUIBox, fromID: g.ask, toBox: "box-b", toID: "b-101"})
	w2msg, _ := g.put(t, inW2)
	unknown := hubErr(t, "unknown uuid", g.addRaw(t, notesAgent, map[string]any{"ask_msg_id": uuidV4()}), "not_found", http.StatusNotFound)
	refused := []struct{ what, as, msg string }{
		{"W2 message", notesAgent, w2msg}, {"DM to another box", notesAgent, otherBox}, {"DM to a-102", notesAgent, dmA2},
		{"#ch2 seating a-102 only", notesAgent, ch2}, {"vault, a-101 unbound", notesAgent, vault},
		{"private topic in #plan", notesAgent, privTopic}, {"a-103 bound to vault, on #ch2", "a-103", ch2},
		{"a-102 never in the topic a-101 posted in", "a-102", inPart},
	}
	for _, c := range refused {
		he := hubErr(t, c.what, g.addRaw(t, c.as, map[string]any{"ask_msg_id": c.msg}), "not_found", http.StatusNotFound)
		if he != nil && unknown != nil && he.Detail != unknown.Detail {
			t.Errorf("%s: detail %q differs from an unknown uuid's %q (an oracle)", c.what, he.Detail, unknown.Detail)
		}
	}
	if n := g.notesOf(t, g.ask); n != 0 {
		t.Fatalf("A holds %d notes after the refusals, want 0", n)
	}
	for _, c := range []struct{ what, as, msg string }{
		{"a-102 on its DM", "a-102", dmA2}, {"a-102 on #ch2", "a-102", ch2},
		{"a-103 on its bound vault", "a-103", vault}, {"a-101 in its own topic", notesAgent, inPart},
	} {
		if err := g.addRaw(t, c.as, map[string]any{"ask_msg_id": c.msg}); err != nil {
			t.Errorf("CONTROL %s: %v", c.what, err)
		}
	}
	if n := g.notesOf(t, g.ask); n != 4 {
		t.Errorf("A holds %d notes after the 4 twins, want 4", n)
	}
}

// C38: the limits and the log. Priority 0 / 6, a 201-character title, a
// javascript: url, a link into another workspace, a person_id field and an
// upper-case ask are 400 bad_note; the log line holds the ids, never a
// value. Twin: priority 1 and a 200-character title pass.
func TestNotesC38LimitsAndLog(t *testing.T) {
	g := newAgentNotesRig(t, true, true)
	ask := g.askIn(t, g.ask)
	w2, _ := g.n.r.e.tenant()
	for what, note := range map[string]map[string]any{
		"priority 0":       {"priority": 0},
		"priority 6":       {"priority": 6},
		"201-char title":   {"title": strings.Repeat("t", 201)},
		"javascript: url":  {"links": []map[string]any{{"kind": "url", "ref": "javascript:x"}}},
		"link into W2":     {"links": []map[string]any{{"kind": "topic", "workspace_id": w2, "ref": uuidV4()}}},
		"person_id field":  {"person_id": g.n.p1},
		"upper-case ask":   {"ask_msg_id": strings.ToUpper(ask)},
		"ask is not uuid":  {"ask_msg_id": "SPL-1"},
		"items not a list": {"items": "one"},
	} {
		if _, ok := note["ask_msg_id"]; !ok {
			note["ask_msg_id"] = ask
		}
		hubErr(t, what, g.addRaw(t, notesAgent, note), "bad_note", http.StatusBadRequest)
	}
	if n := g.notesOf(t, g.ask); n != 0 {
		t.Fatalf("A holds %d notes after the refusals, want 0", n)
	}
	secret := "the-secret-title-" + strings.Repeat("s", 150)
	err := g.addRaw(t, notesAgent, map[string]any{"ask_msg_id": ask, "priority": 1, "title": secret, "body": "secret-body",
		"items": []map[string]any{{"text": "secret-item"}}, "links": []map[string]any{{"kind": "url", "ref": "https://example.com/secret-ref", "label": "secret-label"}}})
	if err != nil {
		t.Fatalf("CONTROL: priority 1 and a long title: %v", err)
	}
	lines := g.n.logs.lines(t)
	var line map[string]any
	for _, l := range lines {
		if l["op"] == "notes_agent_add" && l["outcome"] == "created" {
			line = l
		}
	}
	want := map[string]any{"person": g.ask, "agent": "a-101@box-a", "ask_msg": ask, "ask_workspace": g.n.w1}
	for k, v := range want {
		if line[k] != v {
			t.Errorf("log line %v: %s = %v, want %v", line, k, line[k], v)
		}
	}
	if s, _ := line["note"].(string); s == "" {
		t.Errorf("log line %v names no note", line)
	}
	all, _ := json.Marshal(lines)
	for _, leak := range []string{"the-secret-title", "secret-body", "secret-item", "secret-label", "secret-ref"} {
		if strings.Contains(string(all), leak) {
			t.Errorf("the hub log holds %q", leak)
		}
	}
}

// C39 (OQ-5 A): Notes off answers note_add and the routes 404 notes_off;
// Notes on with the agent switch off answers note_add 404 notes_off while
// A's own list is 200. Twin: both on is C35's 201.
func TestNotesC39Switches(t *testing.T) {
	for _, c := range []struct {
		name         string
		notes, agent bool
		listCode     int
	}{
		{"notes off", false, true, http.StatusNotFound},
		{"agent add off", true, false, http.StatusOK},
	} {
		t.Run(c.name, func(t *testing.T) {
			g := newAgentNotesRig(t, c.notes, c.agent)
			ask := g.askIn(t, g.ask)
			_, err := g.add(t, action.NoteAddArgs{As: notesAgent, AskMsgID: ask, Title: "x"})
			hubErr(t, "note_add", err, "notes_off", http.StatusNotFound)
			if code, out, _ := g.n.do(t, g.askC, http.MethodGet, notesBase, nil, nil); code != c.listCode {
				t.Errorf("A GET list = %d %v, want %d", code, out, c.listCode)
			}
			if n := g.notesOf(t, g.ask); n != 0 {
				t.Errorf("A holds %d notes, want 0", n)
			}
		})
	}
}
