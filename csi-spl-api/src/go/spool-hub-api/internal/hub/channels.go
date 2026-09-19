package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Channels, mention-driven routing and presence (specs/003
// contracts/channels-v1.md). channel / parent_task_id are hub-envelope fields;
// the v:1 object is never touched.

const channelNameMax = 80

// mentionRe finds @<agent-id> and @channel on a token boundary.
var mentionRe = regexp.MustCompile(`(?:^|[^A-Za-z0-9_@-])@([A-Z]{2,4}-[0-9]+|channel)(?:$|[^A-Za-z0-9_-])`)

// mentions returns the agent ids mentioned in body and whether @channel is.
func mentions(body string) (map[string]bool, bool) {
	ids := map[string]bool{}
	all := false
	// Matches share boundary characters; scan with overlapping restarts.
	for i := 0; i < len(body); {
		loc := mentionRe.FindStringSubmatchIndex(body[i:])
		if loc == nil {
			break
		}
		tok := body[i+loc[2] : i+loc[3]]
		if tok == "channel" {
			all = true
		} else {
			ids[tok] = true
		}
		i += loc[3]
	}
	return ids, all
}

// addressed returns the agents (of one box, subscribed to the message's
// channel) that m addresses: msg.to, an @mention, or @channel (channels-v1 §4).
func addressed(agents []string, m *msg.Message) []string {
	ids, all := mentions(m.Body)
	var out []string
	for _, a := range agents {
		if all || ids[a] || m.To == a {
			out = append(out, a)
		}
	}
	sort.Strings(out)
	return out
}

// storedChannel is the messages.channel of an envelope: its (normalized)
// channel tag, else lobby on the lobby task, else "" (a DM).
func (s *Server) storedChannel(env *wire.Envelope, m *msg.Message) string {
	if c := store.NormalizeChannel(env.Channel); c != "" {
		return c
	}
	if s.o.LobbyTaskID != "" && m.TaskID == s.o.LobbyTaskID {
		return store.ChannelLobby
	}
	return ""
}

// checkTags validates the optional hub-envelope fields (channels-v1 §2).
func (s *Server) checkTags(ctx context.Context, tenant, channel, parent, taskID string) (string, int, string) {
	if channel != "" {
		c := store.NormalizeChannel(channel)
		ok, err := s.o.Store.ChannelKnown(ctx, tenant, c)
		if err != nil {
			return "internal", http.StatusInternalServerError, "channel lookup failed"
		}
		if !store.ValidChannelID(c) || !ok {
			return "unknown_channel", http.StatusNotFound, "no channel " + channel + " in this tenant"
		}
	}
	if parent != "" && (!uuidRe.MatchString(parent) || parent == taskID) {
		return "bad_json", http.StatusBadRequest, "parent_task_id must be a UUID other than task_id"
	}
	return "", 0, ""
}

// routeChannel adds a delivery for every box with an addressed member of the
// message's channel, other than from_box, the envelope's own to_box and
// box-wui; ambient chat routes nowhere. Unsigned (browser) envelopes are not
// box-routed: a box would refuse them (channels-v1 §4.6, spec 014).
func (s *Server) routeChannel(ctx context.Context, tenant, channel string, env *wire.Envelope, m *msg.Message, canon []byte) {
	if channel == "" || env.Sig == "" {
		return
	}
	members, err := s.o.Store.ChannelMembers(ctx, tenant, channel)
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Msg("channel members")
		return
	}
	now := s.o.Now()
	for box, agents := range members {
		if box == env.FromBox || box == env.ToBox || box == WUIBox || len(addressed(agents, m)) == 0 {
			continue
		}
		if err := s.o.Store.Enqueue(ctx, tenant, m.MsgID, box, now, now.Add(s.o.QueueTTL), s.o.QueueMaxPerBox); err != nil {
			s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Str("to_box", box).Msg("channel enqueue")
			continue
		}
		if target := s.boxSession(tenant, box); target != nil {
			s.push(ctx, target, m.MsgID, canon)
		}
	}
}

// recvAgents is the recv frame's agents list for a channel delivery to a box
// that is not the envelope's to_box; ok=false when nothing there is addressed
// any more (the row stays queued and expires by TTL).
func (s *Server) recvAgents(ctx context.Context, x *session, raw []byte) ([]string, bool) {
	e, err := wire.ParseEnvelope(raw)
	if err != nil || e.ToBox == x.box || e.Channel == "" {
		return nil, true
	}
	m, err := e.Inner()
	if err != nil {
		return nil, false
	}
	members, err := s.o.Store.ChannelMembers(ctx, x.tenant, store.NormalizeChannel(e.Channel))
	if err != nil {
		return nil, false
	}
	a := addressed(members[x.box], m)
	return a, len(a) > 0
}

// ---- presence (wui-live-ws.md §3.2) --------------------------------------------

func presenceFrame(peer, status string) map[string]string {
	return map[string]string{"type": "presence", "peer": peer, "status": status}
}

// presence pushes one frame per agent to every browser socket of tenant.
func (s *Server) presence(ctx context.Context, tenant, box string, agents []string, status string) {
	if len(agents) == 0 {
		return
	}
	s.mu.Lock()
	var targets []*wuiConn
	for c := range s.wui {
		if c.tenant == tenant {
			targets = append(targets, c)
		}
	}
	s.mu.Unlock()
	for _, c := range targets {
		for _, a := range agents {
			c.write(ctx, presenceFrame(a+"@"+box, status)) //nolint:errcheck
		}
	}
}

// onlinePeers is the presence snapshot of tenant: the agents of every live
// role=box session and every human with an open browser socket.
func (s *Server) onlinePeers(ctx context.Context, tenant string) []string {
	s.mu.Lock()
	var boxes []string
	for k := range s.boxes {
		if k[0] == tenant {
			boxes = append(boxes, k[1])
		}
	}
	var peers []string
	for k, n := range s.online {
		if k[0] == tenant && n > 0 {
			peers = append(peers, k[1]+"@"+WUIBox)
		}
	}
	s.mu.Unlock()
	if len(boxes) > 0 {
		roster, _ := s.o.Store.Roster(ctx, tenant)
		for _, b := range boxes {
			for _, a := range roster[b] {
				peers = append(peers, a+"@"+b)
			}
		}
	}
	sort.Strings(peers)
	return peers
}

// humanOnline counts a human's browser sockets; the first open and the last
// close are presence changes.
func (s *Server) humanOnline(ctx context.Context, tenant, id string, delta int) {
	k := [2]string{tenant, id}
	s.mu.Lock()
	before := s.online[k]
	s.online[k] = before + delta
	after := s.online[k]
	if after <= 0 {
		delete(s.online, k)
	}
	s.mu.Unlock()
	switch {
	case before == 0 && after > 0:
		s.presence(ctx, tenant, WUIBox, []string{id}, "online")
	case before > 0 && after <= 0:
		s.presence(ctx, tenant, WUIBox, []string{id}, "offline")
	}
}

// diffAgents returns what is in a but not in b.
func diffAgents(a, b []string) []string {
	in := map[string]bool{}
	for _, x := range b {
		in[x] = true
	}
	var out []string
	for _, x := range a {
		if !in[x] {
			out = append(out, x)
		}
	}
	return out
}

// ---- POST /v1/channels (channels-v1 §5.1) ---------------------------------------

func (s *Server) handleCreateChannel(w http.ResponseWriter, r *http.Request) {
	s.allowOrigin(w, r)
	t, hum, ok := s.humanTenant(w, r)                           // specs/026: the session's active tenant
	if !ok || !s.permit(w, r, t.ID, hum, rbac.ChannelsManage) { // specs/025
		return
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		writeUnpaid(w)
		return
	}
	var body struct {
		Channel string `json:"channel"`
		Name    string `json:"name"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {channel, name?}")
		return
	}
	body.Name = strings.TrimSpace(body.Name)
	if body.Name == "" {
		body.Name = body.Channel
	}
	if !store.ValidChannelID(body.Channel) || utf8.RuneCountInString(body.Name) > channelNameMax {
		writeErr(w, http.StatusBadRequest, "bad_channel", "channel must match ^[a-z0-9][a-z0-9-]{0,63}$ and name be at most 80 characters")
		return
	}
	by := "wui"
	if id, err := s.sessionFor(r, t.ID); err == nil && id != "" {
		by = id
	}
	c := store.Channel{TenantID: t.ID, ChannelID: body.Channel, Name: body.Name, CreatedBy: by, CreatedAt: s.o.Now().UTC()}
	switch err := s.o.Store.CreateChannel(r.Context(), c); {
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, "channel_exists", "channel "+body.Channel+" exists or is reserved")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel not stored")
	default:
		writeJSON(w, http.StatusCreated, map[string]any{"channel": c.ChannelID, "name": c.Name,
			"created_by": c.CreatedBy, "created_at": rfc(c.CreatedAt), "default": false})
	}
}

func (s *Server) channelsPreflight(w http.ResponseWriter, r *http.Request) {
	if s.allowOrigin(w, r) {
		h := w.Header()
		h.Set("Access-Control-Allow-Methods", "POST")
		h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Locale")
		h.Set("Access-Control-Max-Age", "600")
	}
	w.WriteHeader(http.StatusNoContent)
}
