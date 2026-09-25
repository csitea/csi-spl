package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Channels, membership routing and presence (specs/003
// contracts/channels-v1.md). channel / parent_task_id are hub-envelope fields;
// the v:1 object is never touched.

const (
	channelNameMax = 80
	// channelDescMax is what the WUI's new-channel dialog accepts in its
	// description field (rdb 0027). A sentence about the channel, not a page.
	channelDescMax = 500
)

// channelTargets returns the agents of one box that a channel post reaches:
// every member of the channel (owner rule 2026-09-22 - "if we are in a channel
// - all of the participants in the channel will receive the msg"). Membership
// IS the address, so a plain post, an @mention and @channel all reach the same
// set and nothing here parses the body. A leading @AGENT still decides the
// envelope's to_box for a browser send (dispatch.go), and msg.to still names
// the one agent the to_box delivery is for - neither narrows the channel.
func channelTargets(agents []string) []string {
	if len(agents) == 0 {
		return nil
	}
	out := append([]string(nil), agents...)
	sort.Strings(out)
	return out
}

// tagChannel is the channel an envelope itself claims: its (normalized)
// channel tag, else lobby on the lobby task, else "". A browser send signs
// what channelOf returns, not the raw tag: a lobby post whose frame carried no
// tag would otherwise be stored under lobby and routed to lobby members with
// an envelope that claims no channel - which every receiving box refuses
// (hubclient.receive, channels-v1 §4.5).
func (s *Server) tagChannel(channel, taskID string) string {
	if c := store.NormalizeChannel(channel); c != "" {
		return c
	}
	if s.o.LobbyTaskID != "" && taskID == s.o.LobbyTaskID {
		return store.ChannelLobby
	}
	return ""
}

// channelOf is the channel a message belongs to: tagChannel, else the channel
// of its task's topic root, else "" (a DM). A thread reply lives on its
// topic's task and the WUI reply pane sends no tag, so without the inherit a
// #lobby reply was stored with channel NULL while its topic said lobby
// (CLE-34977) - and the per-message read door (rdb 0028) then judged the
// reply as a DM. A lookup error keeps the old answer rather than failing the
// send.
func (s *Server) channelOf(ctx context.Context, tenant, channel, taskID string) string {
	if c := s.tagChannel(channel, taskID); c != "" {
		return c
	}
	c, err := s.o.Store.TopicChannel(ctx, tenant, taskID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("task_id", taskID).Msg("topic channel")
		return ""
	}
	return c
}

// storedChannel is the messages.channel of an envelope.
func (s *Server) storedChannel(ctx context.Context, tenant string, env *wire.Envelope, m *msg.Message) string {
	return s.channelOf(ctx, tenant, env.Channel, m.TaskID)
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

// agentInChannel is specs/038 FR-004: a box-signed envelope that CLAIMS a
// channel is a post into that channel, and only a member agent may post one -
// the sending agent itself must be a member on the box that signed it
// (channel_subscriptions, invited agents included). A default channel is no
// exception: since rdb 0036 #lobby / #tasks / #alerts have no agents until a
// member picks them. A non-member is answered like a channel that does not
// exist (unknown_channel, 404 - never 403, the read door's rule, rdb 0028).
func (s *Server) agentInChannel(ctx context.Context, tenant, channel, box, agent string) (bool, error) {
	members, err := s.o.Store.ChannelMembers(ctx, tenant, store.NormalizeChannel(channel))
	if err != nil {
		return false, err
	}
	return contains(members[box], agent), nil
}

// withoutAgent is agents minus id (a fresh slice; the input is not touched).
func withoutAgent(agents []string, id string) []string {
	var out []string
	for _, a := range agents {
		if a != id {
			out = append(out, a)
		}
	}
	return out
}

// routeChannel adds a delivery for every box that hosts a member of the
// message's channel; ambient chat in a DM routes nowhere. Unsigned (browser)
// envelopes are not box-routed: a box would refuse them (channels-v1 §4.6,
// spec 014) - a browser channel post is signed by the hub's box-wui key before
// it gets here (wuiSend), so the unsigned case is one the fan-out is OFF for.
//
// Skips: box-wui (the browser audience, delivered by fanoutWUI) and from_box
// (its own agents wrote the post) - EXCEPT for an agent's own channel post
// (specs/038: a box-signed channel tag), where the other members on the
// sender's box are members like any other and only the sender itself is left
// out (recvAgents drops it from the frame, so it never reads its own post).
// An AGENT-origin envelope also skips its
// to_box, which the shared commit path already delivered. A BROWSER-origin one
// does not: box-wui owns no agent, so a dispatch's to_box is just another
// member box, and the other members sitting on it are exactly what the owner
// rule is about. Enqueue is idempotent per (msg_id, box), so the second row is
// a no-op insert and only the recv frame's agents list changes.
func (s *Server) routeChannel(ctx context.Context, tenant, channel string, env *wire.Envelope, m *msg.Message, canon []byte) {
	if channel == "" || env.Sig == "" {
		return
	}
	members, err := s.o.Store.ChannelMembers(ctx, tenant, channel)
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Msg("channel members")
		return
	}
	fromBrowser := env.FromBox == WUIBox
	agentPost := !fromBrowser && env.Channel != ""
	now := s.o.Now()
	for box, agents := range members {
		if box == WUIBox || (!fromBrowser && box == env.ToBox) {
			continue
		}
		if box == env.FromBox {
			if !agentPost {
				continue
			}
			agents = withoutAgent(agents, m.From)
		}
		if len(channelTargets(agents)) == 0 {
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

// recvAgents is the recv frame's agents list for a channel delivery: the
// channel members this box hosts (channels-v1 §4). ok=false drops the push
// when nothing there is a member any more and the row is only there for the
// channel (it stays queued and expires by TTL); a delivery to the envelope's
// own to_box always stands - msg.to is on that box whether or not it joined.
func (s *Server) recvAgents(ctx context.Context, x *session, raw []byte) ([]string, bool) {
	e, err := wire.ParseEnvelope(raw)
	if err != nil || e.Channel == "" {
		return nil, true
	}
	own := e.ToBox == x.box
	members, err := s.o.Store.ChannelMembers(ctx, x.tenant, store.NormalizeChannel(e.Channel))
	if err != nil {
		return nil, own
	}
	mine := members[x.box]
	if e.FromBox == x.box { // specs/038: an agent never receives its own post
		if m, err := e.Inner(); err == nil {
			mine = withoutAgent(mine, m.From)
		}
	}
	a := channelTargets(mine)
	return a, own || len(a) > 0
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
		Channel     string `json:"channel"`
		Name        string `json:"name"`
		Description string `json:"description"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {channel, name?, description?}")
		return
	}
	body.Name = strings.TrimSpace(body.Name)
	body.Description = strings.TrimSpace(body.Description)
	if body.Name == "" {
		body.Name = body.Channel
	}
	if !store.ValidChannelID(body.Channel) || utf8.RuneCountInString(body.Name) > channelNameMax {
		writeErr(w, http.StatusBadRequest, "bad_channel", "channel must match ^[a-z0-9][a-z0-9-]{0,63}$ and name be at most 80 characters")
		return
	}
	if utf8.RuneCountInString(body.Description) > channelDescMax {
		writeErr(w, http.StatusBadRequest, "bad_channel", "description must be at most 500 characters")
		return
	}
	by := "wui"
	// memberID, not sessionFor: sessionFor bypasses the SessionID seam, so
	// under a seam rig the creator was recorded as "wui" and (since rdb 0028)
	// lost the channel it had just made.
	if id, err := s.memberID(r, t.ID); err == nil && id != "" {
		by = id
	}
	c := store.Channel{TenantID: t.ID, ChannelID: body.Channel, Name: body.Name, Description: body.Description,
		CreatedBy: by, CreatedAt: s.o.Now().UTC()}
	switch err := s.o.Store.CreateChannel(r.Context(), c); {
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, "channel_exists", "channel "+body.Channel+" exists or is reserved")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "channel not stored")
	default:
		// rdb 0028: a created channel is members-only, so it must not be
		// born empty - the creator would lose the channel they just made.
		// Before the fan-out, which is itself members-only now.
		if by != "wui" {
			if err := s.o.Store.AddChannelHumans(r.Context(), t.ID, c.ChannelID, []string{by}, by, s.o.Now()); err != nil {
				s.o.Log.Error().Err(err).Str("channel", c.ChannelID).Msg("channel creator membership")
			}
		}
		/* CLE-3425: every other session's sidebar learns about it at once */
		s.fanoutChannel(r.Context(), t.ID, c)
		writeJSON(w, http.StatusCreated, map[string]any{"channel": c.ChannelID, "name": c.Name,
			"description": c.Description, "created_by": c.CreatedBy, "created_at": rfc(c.CreatedAt), "default": false})
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
