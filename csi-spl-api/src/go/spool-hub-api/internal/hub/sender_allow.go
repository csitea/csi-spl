package hub

import (
	"context"
	"errors"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The per-agent sender allow-list (spec 044 FR-OS-017, T034, SPL-1018, rdb
// 0188; contract specs/044-spool-open-source/contracts/sender-allow-list.md).
// Owner HUM-10, t1 dee4081d, msg e9ec66fa, the five decisions:
//
//  1. the list is per agent in a workspace, of members by HUM id; workspace
//     admins edit it (tenant.settings, like the rest of Workspace settings);
//  2. an agent with no list takes messages from every member;
//  3. it covers a direct message to the agent and an @mention of it, never a
//     channel post that does not name it;
//  4. the hub refuses the send, 403 sender_not_allowed, and the agent never
//     receives it (nothing is stored, no delivery is built);
//  5. the sender sees it: the error frame names the agent.
//
//	GET    /v1/tenant/agent-senders           {tenant_id, lists: [{agent, members, updated_by, updated_at}]}
//	PUT    /v1/tenant/agent-senders/{agent}   {members: ["HUM-3", ...]} ([] = nobody)
//	DELETE /v1/tenant/agent-senders/{agent}   no list: every member again
//
// Agents and the orchestrator / dispatcher seats are never blocked from each
// other: the check runs only on a PERSON's browser send (wuiSend, from a
// HUM-/GST- id), never on a box frame (onSend). Every agent, the orchestrator
// and the dispatcher seats included, sends over its box, and a list can only
// hold member ids, so no list can name, or refuse, an agent.

// TokenSenderNotAllowed is the refusal token (decision 4).
const TokenSenderNotAllowed = "sender_not_allowed"

// senderListMax caps one list: a workspace's members, with headroom.
const senderListMax = 500

func (s *Server) routeSenderAllow(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/tenant/agent-senders", s.handleSenderLists)
	mux.HandleFunc("PUT /v1/tenant/agent-senders/{agent}", s.handlePutSenderList)
	mux.HandleFunc("DELETE /v1/tenant/agent-senders/{agent}", s.handleDropSenderList)
	mux.HandleFunc("OPTIONS /v1/tenant/agent-senders", s.tenantSettingsPreflight)
	mux.HandleFunc("OPTIONS /v1/tenant/agent-senders/{agent}", s.senderListPreflight)
}

// senderListPreflight answers the PUT / DELETE preflight of one list.
func (s *Server) senderListPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "GET, PUT, DELETE")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", corsMaxAge)
	}
	w.WriteHeader(http.StatusNoContent)
}

// senderAllowActor is the tenant.settings check plus the store. ok=false:
// it answered.
func (s *Server) senderAllowActor(w http.ResponseWriter, r *http.Request) (store.Tenant, rbac.Access, store.SenderAllow, bool) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return t, a, nil, false
	}
	sa, ok := s.o.Store.(store.SenderAllow)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no sender allow-lists")
		return t, a, nil, false
	}
	return t, a, sa, true
}

// senderListJSON is one list on the wire.
type senderListJSON struct {
	Agent     string   `json:"agent"`
	Members   []string `json:"members"`
	UpdatedBy string   `json:"updated_by"`
	UpdatedAt string   `json:"updated_at"`
}

// GET /v1/tenant/agent-senders
func (s *Server) handleSenderLists(w http.ResponseWriter, r *http.Request) {
	t, _, sa, ok := s.senderAllowActor(w, r)
	if !ok {
		return
	}
	lists, err := sa.SenderLists(r.Context(), t.ID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("sender lists")
		writeErr(w, http.StatusInternalServerError, "internal", "sender lists unavailable")
		return
	}
	out := make([]senderListJSON, 0, len(lists))
	for _, l := range lists {
		out = append(out, senderListJSON{Agent: l.Agent, Members: l.Members, UpdatedBy: l.UpdatedBy,
			UpdatedAt: l.UpdatedAt.UTC().Format(time.RFC3339)})
	}
	writeJSON(w, http.StatusOK, map[string]any{"tenant_id": t.ID, "lists": out})
}

// listAgent is the {agent} of the path, normalised (C-004 -> c-004, no box):
// "" when it is not an agent id.
func listAgent(r *http.Request) string {
	id, _ := agentid.SplitAtBox(agentid.Normalize(r.PathValue("agent")))
	if !isAgent(id) {
		return ""
	}
	return id
}

// PUT /v1/tenant/agent-senders/{agent} {members}
func (s *Server) handlePutSenderList(w http.ResponseWriter, r *http.Request) {
	t, a, sa, ok := s.senderAllowActor(w, r)
	if !ok {
		return
	}
	agent := listAgent(r)
	if agent == "" {
		writeErr(w, http.StatusBadRequest, "bad_agent", "the path names no agent id")
		return
	}
	var body struct {
		Members *[]string `json:"members"`
	}
	if !decodeMembers(w, r, &body) {
		return
	}
	if body.Members == nil {
		writeErr(w, http.StatusBadRequest, "bad_members", "body must be {members: [HUM ids]}")
		return
	}
	members, bad := senderMembers(*body.Members)
	switch {
	case bad != "":
		writeErr(w, http.StatusBadRequest, "bad_members", bad+" is not a member id (HUM-n)")
		return
	case len(members) > senderListMax:
		writeErr(w, http.StatusBadRequest, "bad_members", "a list holds at most 500 members")
		return
	}
	err := sa.SetSenderList(r.Context(), t.ID, agent, members, a.HumanID, s.o.Now())
	switch {
	case errors.Is(err, store.ErrSenderNotMember):
		writeErr(w, http.StatusBadRequest, "not_a_member", "every id on the list must be a member of this workspace")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Str("agent", agent).Msg("sender list save")
		writeErr(w, http.StatusInternalServerError, "internal", "sender list not saved")
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("agent", agent).Int("members", len(members)).
		Str("by", a.HumanID).Msg("sender list set")
	writeJSON(w, http.StatusOK, senderListJSON{Agent: agent, Members: members, UpdatedBy: a.HumanID,
		UpdatedAt: s.o.Now().UTC().Format(time.RFC3339)})
}

// senderMembers is the sorted, de-duplicated list; bad = the first id that is
// not a HUM id.
func senderMembers(in []string) (out []string, bad string) {
	out = []string{}
	for _, h := range in {
		h = strings.ToUpper(strings.TrimSpace(h))
		if !strings.HasPrefix(h, "HUM-") || !msg.ValidID(h) {
			return nil, h
		}
		out = append(out, h)
	}
	slices.Sort(out)
	return slices.Compact(out), ""
}

// DELETE /v1/tenant/agent-senders/{agent}
func (s *Server) handleDropSenderList(w http.ResponseWriter, r *http.Request) {
	t, a, sa, ok := s.senderAllowActor(w, r)
	if !ok {
		return
	}
	agent := listAgent(r)
	if agent == "" {
		writeErr(w, http.StatusBadRequest, "bad_agent", "the path names no agent id")
		return
	}
	had, err := sa.DropSenderList(r.Context(), t.ID, agent)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Str("agent", agent).Msg("sender list drop")
		writeErr(w, http.StatusInternalServerError, "internal", "sender list not removed")
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("agent", agent).Bool("had", had).Str("by", a.HumanID).Msg("sender list dropped")
	w.WriteHeader(http.StatusNoContent)
}

// mentionRe is an @mention of an agent: "@c-001", "@C-001@sat", "@CLE-7,"; not
// the middle of an address (a@c-001 is not one).
var mentionRe = regexp.MustCompile(`(?:^|[^A-Za-z0-9_.@-])@([A-Za-z]{1,4}-[0-9]+)`)

// sendTargets is every agent a browser send addresses (decision 3): the agent
// it is dispatched to (a DM, "@agent do x", a reply in an agent's topic), an
// agent `to`, and each agent the body @mentions. Bare ids, sorted, once each.
func sendTargets(m *msg.Message, dispatched string) []string {
	var out []string
	add := func(id string) {
		id, _ = agentid.SplitAtBox(agentid.Normalize(id))
		if isAgent(id) && !slices.Contains(out, id) {
			out = append(out, id)
		}
	}
	add(dispatched)
	add(m.To)
	for _, g := range mentionRe.FindAllStringSubmatch(m.Body, -1) {
		add(g[1])
	}
	slices.Sort(out)
	return out
}

// senderAllowed is the allow-list check of a browser send by c (decisions 3
// and 4): a refusal naming the first agent that does not take c's messages,
// or nil. Only a person's send is checked (see the head of this file). A
// store without the lists, and a send that names no agent, read nothing.
func (s *Server) senderAllowed(ctx context.Context, c *wuiConn, m *msg.Message, dispatched string) *frameRefusal {
	if !isPerson(c.from) {
		return nil
	}
	sa, ok := s.o.Store.(store.SenderAllow)
	if !ok {
		return nil
	}
	targets := sendTargets(m, dispatched)
	if len(targets) == 0 {
		return nil
	}
	sender := c.member
	if sender == "" {
		sender = c.from // a door-off guest is on no list
	}
	agent, err := sa.SenderRefusedBy(ctx, c.tenant, sender, targets)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", c.tenant).Str("msg_id", m.MsgID).Msg("sender allow-list")
		return &frameRefusal{"internal", http.StatusInternalServerError, "sender allow-list unavailable"}
	}
	if agent == "" {
		return nil
	}
	return &frameRefusal{TokenSenderNotAllowed, http.StatusForbidden, agent + " does not take messages from you"}
}

// wuiErrAgent is the error frame of a sender_not_allowed refusal: the frame
// every refusal gets, plus the agent it names (decision 5), so the WUI says
// who without reading the English detail.
type wuiErrAgent struct {
	wuiErr
	Agent string `json:"agent"`
}

// refusedAgent is the agent a sender_not_allowed refusal names ("" for any
// other refusal): the detail starts with it.
func refusedAgent(rf *frameRefusal) string {
	if rf.token != TokenSenderNotAllowed {
		return ""
	}
	id, _, _ := strings.Cut(rf.detail, " ")
	return id
}
