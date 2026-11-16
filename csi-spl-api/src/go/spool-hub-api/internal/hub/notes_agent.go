package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// An agent adds a note on a person's ask (spec 155 v1.5 section 2.11, build
// row B12; owner HUM-10, t1 8c2954b3 msg 13772c97: "the agents shoud be able
// to create a note for me when I ask"). One box-socket frame, note_add, and
// nothing else: no read, list, edit or delete of a note, and every
// /v1/me/realm/notes route still refuses an agent (realm_notes.go).
//
// The agent never names a person. It names the ask, ask_msg_id, a message in
// the session's own workspace, and the note goes to that message's human
// author. Before the person scope opens, the hub proves, in x.tenant:
//
//  1. the message is live within retention (GetEditable), else 404 not_found;
//  2. the acting agent (as, x.box) reads it (agentReadsAsk): the spec 144
//     private / dedicated scope gate, then a per-agent audience (a DM or
//     mention to it, its seat in the channel, or its own envelope in the
//     topic), else 404 not_found, the same answer as an unknown id;
//  3. a signed-in human member wrote it there (askPersonRefusal): box-wui,
//     not a spec 169 copy, a HUM-* id, no act-as clone row live or ended,
//     a person seat in x.tenant, else 403 ask_not_person.
//
// Then one store call, CreateNoteOnAsk, opens the person scope alone. The
// reply is {msg_id, id, created_at}. Switches (section 6): NotesEnabled and
// NotesAgentAddEnabled, either off = 404 notes_off. The log line carries ids
// and the outcome only (2.8), never a title, body, item, label or ref.

const (
	tokenAskNotPerson = "ask_not_person"
	opNotesAgentAdd   = "notes_agent_add"
)

// noteAddItemIn is one checklist line of a note_add request.
type noteAddItemIn struct {
	Text string `json:"text"`
	Done bool   `json:"done"`
}

// noteAddIn is the note_add request: the ask, then every field the WUI sets
// on a note (OQ-2). An unknown field (a person_id) is refused.
type noteAddIn struct {
	AskMsgID string          `json:"ask_msg_id"`
	Title    string          `json:"title"`
	Body     string          `json:"body"`
	Pinned   bool            `json:"pinned"`
	Priority *int            `json:"priority"`
	Archived bool            `json:"archived"`
	Items    []noteAddItemIn `json:"items"`
	Links    []noteLinkIn    `json:"links"`
}

// noteAddOut is all the agent learns of the note it added.
type noteAddOut struct {
	MsgID     string `json:"msg_id"`
	ID        string `json:"id"`
	CreatedAt string `json:"created_at"`
}

// noteAddLog is the one log line of a note_add: ids and the outcome.
type noteAddLog struct {
	person, note, agent, ask, workspace string
}

func (s *Server) noteAddLogLine(l noteAddLog, outcome string) {
	s.o.Log.Info().Str("op", opNotesAgentAdd).Str("person", l.person).Str("note", l.note).Str("agent", l.agent).
		Str("ask_msg", l.ask).Str("ask_workspace", l.workspace).Str("outcome", outcome).Msg("notes")
}

func (s *Server) onNoteAdd(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a note_add frame needs msg_id (a UUID) to pair the reply")
		return
	}
	if detail := senderRefusal(x, f.As); detail != "" {
		x.fail(ctx, id, TokenFromNotAnnounced, http.StatusForbidden, detail)
		return
	}
	lg := noteAddLog{agent: f.As + "@" + x.box, workspace: x.tenant}
	out, ie := s.noteAdd(ctx, x, f, &lg)
	if ie != nil {
		s.noteAddLogLine(lg, ie.token)
		x.fail(ctx, id, ie.token, ie.status, ie.detail)
		return
	}
	s.noteAddLogLine(lg, "created")
	out.MsgID = id
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TNoteAdd, MsgID: id, Note: raw}) //nolint:errcheck
}

// noteAdd runs the switches, the workspace, the ask's proof and the write;
// lg gathers the ids as they are proven.
func (s *Server) noteAdd(ctx context.Context, x *session, f wire.Frame, lg *noteAddLog) (noteAddOut, *issueErr) {
	if !s.o.NotesEnabled || !s.o.NotesAgentAddEnabled {
		return noteAddOut{}, &issueErr{http.StatusNotFound, notesOff, "agent notes are switched off on this hub"}
	}
	ns, ok := s.o.Store.(store.Notes)
	if !ok {
		return noteAddOut{}, &issueErr{http.StatusServiceUnavailable, "realm_unavailable", "notes are not kept by this hub"}
	}
	if ie := s.noteAddTenant(ctx, x.tenant); ie != nil {
		return noteAddOut{}, ie
	}
	in, ie := noteAddDecode(f.Note)
	if ie != nil {
		return noteAddOut{}, ie
	}
	lg.ask = in.AskMsgID
	person, ie := s.noteAddAsker(ctx, x, f.As, in.AskMsgID)
	if ie != nil {
		return noteAddOut{}, ie
	}
	lg.person = person
	got, err := ns.CreateNoteOnAsk(ctx, person, in.onAsk(lg.agent, x.tenant), s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotesFull):
		return noteAddOut{}, &issueErr{http.StatusBadRequest, "notes_full", "the person holds the most notes allowed"}
	case errors.Is(err, store.ErrRealmBad):
		return noteAddOut{}, badNoteAdd(strings.TrimPrefix(err.Error(), "store: "))
	case err != nil:
		s.o.Log.Error().Err(err).Str("op", opNotesAgentAdd).Str("person", person).Str("agent", lg.agent).Msg("notes")
		return noteAddOut{}, &issueErr{http.StatusInternalServerError, "internal", "notes are unavailable"}
	}
	lg.note = got.ID
	return noteAddOut{ID: got.ID, CreatedAt: notesTime(got.CreatedAt)}, nil
}

func badNoteAdd(detail string) *issueErr {
	return &issueErr{http.StatusBadRequest, "bad_note", detail}
}

// noteAddTenant: the workspace pays and is not suspended, as for a send.
func (s *Server) noteAddTenant(ctx context.Context, tenant string) *issueErr {
	t, err := s.o.Store.GetTenant(ctx, tenant)
	if err != nil {
		return &issueErr{http.StatusInternalServerError, "internal", "tenant unavailable"}
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		return &issueErr{billing.HTTPUnpaid, billing.TokenUnpaid, "tenant billing is unpaid"}
	}
	if t.Suspended() {
		return &issueErr{http.StatusForbidden, tokenWorkspaceSuspended, "this workspace is suspended by the operator"}
	}
	return nil
}

// noteAddDecode reads the request strictly: one JSON object, no unknown
// field, the ask a lowercase message uuid.
func noteAddDecode(raw json.RawMessage) (noteAddIn, *issueErr) {
	var in noteAddIn
	if len(raw) > notesBodyMax {
		return in, badNoteAdd("the note is too large")
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil || dec.More() {
		return in, badNoteAdd("note must be one JSON object of ask_msg_id, title, body, pinned, priority, archived, items, links")
	}
	if !uuidRe.MatchString(in.AskMsgID) {
		return in, badNoteAdd("ask_msg_id must be the asking message's lowercase uuid")
	}
	return in, nil
}

// onAsk is the store's request: the agent and the ask's workspace come from
// the session, never from the frame.
func (in noteAddIn) onAsk(agent, tenant string) store.NoteOnAsk {
	out := store.NoteOnAsk{Title: in.Title, Body: in.Body, Pinned: in.Pinned, Priority: in.Priority, Archived: in.Archived,
		Agent: agent, AskMsgID: in.AskMsgID, AskWorkspaceID: tenant}
	for _, it := range in.Items {
		out.Items = append(out.Items, store.NoteItem{Text: it.Text, Done: it.Done})
	}
	for _, l := range in.Links {
		out.Links = append(out.Links, l.link())
	}
	return out
}

// noteAddAsker proves the ask (steps 1-3 above) and answers its author.
func (s *Server) noteAddAsker(ctx context.Context, x *session, as, askID string) (string, *issueErr) {
	notFound := &issueErr{http.StatusNotFound, "not_found", "no such message"}
	m, err := s.o.Store.GetEditable(ctx, x.tenant, askID, s.o.Now())
	if errors.Is(err, store.ErrNotFound) {
		return "", notFound
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("op", opNotesAgentAdd).Str("tenant", x.tenant).Msg("notes")
		return "", &issueErr{http.StatusInternalServerError, "internal", "the ask is unavailable"}
	}
	if !s.agentReadsAsk(ctx, x, as, m) {
		return "", notFound
	}
	if detail, err := s.askPersonRefusal(ctx, x.tenant, m); err != nil {
		s.o.Log.Error().Err(err).Str("op", opNotesAgentAdd).Str("tenant", x.tenant).Msg("notes")
		return "", &issueErr{http.StatusInternalServerError, "internal", "the asker is unavailable"}
	} else if detail != "" {
		return "", &issueErr{http.StatusForbidden, tokenAskNotPerson, detail}
	}
	return m.FromID, nil
}

// agentReadsAsk is the per-agent read door of 2.11 step 2 for agent as on
// x.box: (a) the spec 144 scope gate, then (b) one audience of its own. A
// store that cannot say fails closed.
func (s *Server) agentReadsAsk(ctx context.Context, x *session, as string, m store.EditableMessage) bool {
	ch := store.NormalizeChannel(m.Channel)
	if !s.askScopeOK(ctx, x, as, ch, m.TaskID) {
		return false
	}
	if m.ToBox == x.box && m.ToID == as {
		return true // (i) a DM or mention to this agent on this box
	}
	if ch != "" && !store.ChannelHidden(ch) {
		members, err := s.o.Store.ChannelMembers(ctx, x.tenant, ch)
		if err == nil && slices.Contains(members[x.box], as) {
			return true // (ii) its seat in the channel on this box
		}
	}
	return s.agentInTopic(ctx, x, as, m.TaskID) // (iii) its own envelope in the topic
}

// askScopeOK is store dedicatedTailOK for agent as on x.box: a bound agent
// reads only its bound channel or topic (private or not), an unbound one no
// private topic or channel.
func (s *Server) askScopeOK(ctx context.Context, x *session, as, ch, task string) bool {
	ds, ok := s.o.Store.(store.DedicatedStore)
	if !ok {
		return false
	}
	b, err := ds.GetDedicatedBinding(ctx, x.tenant, as, x.box)
	if err == nil {
		return (b.ScopeType == store.ScopeChannel && b.ScopeID == ch) || (b.ScopeType == store.ScopeTopic && b.ScopeID == task)
	}
	if !errors.Is(err, store.ErrNotFound) {
		return false
	}
	private, err := ds.IsPrivateScope(ctx, x.tenant, store.ScopeTopic, task)
	if err != nil || private {
		return false
	}
	if ch == "" {
		return true
	}
	private, err = ds.IsPrivateScope(ctx, x.tenant, store.ScopeChannel, ch)
	return err == nil && !private
}

// agentInTopic: the topic holds an envelope agent as on x.box sent or was
// addressed, among those the box may read (BoxTaskEnvelopes under the
// agent's own scope).
func (s *Server) agentInTopic(ctx context.Context, x *session, as, task string) bool {
	envs, err := s.o.Store.BoxTaskEnvelopes(store.WithTailAgent(ctx, as), x.tenant, task, x.box, s.o.Now())
	if err != nil {
		return false
	}
	for _, raw := range envs {
		var env struct {
			FromBox string `json:"from_box"`
			ToBox   string `json:"to_box"`
			Msg     struct {
				From string `json:"from"`
				To   string `json:"to"`
			} `json:"msg"`
		}
		if json.Unmarshal(raw, &env) != nil {
			continue
		}
		if (env.FromBox == x.box && env.Msg.From == as) || (env.ToBox == x.box && env.Msg.To == as) {
			return true
		}
	}
	return false
}

// askPersonRefusal is 2.11 step 3 (OQ-1): a signed-in human member of
// tenant wrote m there. "" = the author may have the note; an error = the
// store could not say.
func (s *Server) askPersonRefusal(ctx context.Context, tenant string, m store.EditableMessage) (string, error) {
	if m.FromBox != WUIBox || m.CopiedFrom != "" || !realmPersonRe.MatchString(m.FromID) {
		return "the ask was not written here by a signed-in person", nil
	}
	if cr, ok := s.o.Store.(cloneReader); ok {
		_, err := cr.Clone(ctx, tenant, m.FromID)
		if err == nil {
			return "the ask was written by an act-as clone", nil
		}
		if !errors.Is(err, store.ErrNotFound) {
			return "", err
		}
	}
	ml, ok := s.o.Store.(store.MembershipLister)
	if !ok {
		return "", errors.New("notes: the store lists no memberships")
	}
	seats, err := ml.Memberships(ctx, m.FromID)
	if err != nil {
		return "", err
	}
	if len(seats) == 0 || realmSeatsNotPerson(seats) {
		return "the asker holds no person seat", nil
	}
	for _, st := range seats {
		if st.TenantID == tenant && !realmSeatsNotPerson([]store.Membership{st}) {
			return "", nil
		}
	}
	return "the asker is no person member of this workspace", nil
}
