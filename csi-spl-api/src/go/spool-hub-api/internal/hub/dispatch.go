package hub

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// WUI dispatch (specs/014 contracts/wui-dispatch.md): a signed-in member's
// browser send that names an agent is signed by the hub-held box-wui key and
// delivered to that agent's box like any box send. The box verifies it with
// the same code as any other envelope, against the tenant-root-signed
// box-wui pin; the key never leaves this process.

// wuiPub returns the box-wui public key, or nil when the hub has no key.
func (s *Server) wuiPub() ed25519.PublicKey {
	if len(s.o.WUIKey) != ed25519.PrivateKeySize {
		return nil
	}
	return s.o.WUIKey.Public().(ed25519.PublicKey)
}

// GET /v1/wui/pubkey: the key a tenant operator pins as box-wui (§2.2). The
// key is hub-wide, so it answers on any host (specs/026: the api host).
func (s *Server) handleWUIPubkey(w http.ResponseWriter, r *http.Request) {
	pub := s.wuiPub()
	if pub == nil {
		writeErr(w, http.StatusNotFound, "not_found", "this hub has no box-wui key")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"box_id": WUIBox,
		"pubkey": base64.StdEncoding.EncodeToString(pub), "dispatch": s.o.WUIDispatch})
}

// wuiSession is the member-session human id of a browser upgrade ("" = none).
func (s *Server) wuiSession(r *http.Request, tenant string) (string, error) {
	if s.o.SessionID != nil {
		return s.o.SessionID(r, tenant)
	}
	return s.sessionFor(r, tenant)
}

// dispatchAgent is the agent a browser send commands, or "" when it is a
// browser-only send (§3): an agent `to`, else a leading @AGENT-ID mention
// when `to` is empty or the broadcast id.
func dispatchAgent(to, body string) string {
	if to != "" && to != BroadcastID {
		if isAgent(to) {
			return to
		}
		return ""
	}
	b := strings.TrimLeft(body, " \t")
	if !strings.HasPrefix(b, "@") {
		return ""
	}
	rest := b[1:]
	id, after := rest, ""
	if i := strings.IndexAny(rest, " \t\r\n"); i >= 0 {
		id, after = rest[:i], rest[i:]
	}
	id = strings.TrimRight(id, ",:;")
	// specs/058: "@CLE-002@sat do x" names the box too (mentionBox reads it).
	if i := strings.IndexByte(id, '@'); i > 0 {
		id = id[:i]
	}
	// e09a72f7 (owner): a BARE @AGENT with no instructions after it is a
	// mention, not a command. Dispatching it would 404 an offline agent
	// (unknown_agent) and drop the person's message, which read to the owner as
	// "a message that starts with @ cannot be sent" - the WUI now sends a bare
	// mention as a note (channel-feed parseMention) with the @id kept in the
	// body, and this is where that body used to be force-dispatched. Only
	// "@AGENT <instructions>" commands the box; a bare mention posts as a normal
	// message and the mention poke (spec 042 K3) still notifies the agent.
	if strings.TrimSpace(after) == "" {
		return ""
	}
	if isAgent(id) {
		return id
	}
	return ""
}

// dispatchBox is the box a browser send pins its agent to (specs/058: agents
// are addressed <ID>@<box>, and the reserved ids 001-003 live on every box):
// the frame's to_box, else the box of a leading "@ID@box" mention, else ""
// (resolve the bare id across the roster, as before).
func dispatchBox(f wuiIn) string {
	if f.ToBox != "" {
		return f.ToBox
	}
	if f.To != "" && f.To != BroadcastID {
		return ""
	}
	b := strings.TrimLeft(f.Body, " \t")
	if !strings.HasPrefix(b, "@") {
		return ""
	}
	tok := b[1:]
	if i := strings.IndexAny(tok, " \t\r\n"); i >= 0 {
		tok = tok[:i]
	}
	tok = strings.TrimRight(tok, ",:;")
	if i := strings.IndexByte(tok, '@'); i > 0 {
		return tok[i+1:]
	}
	return ""
}

// isAgent: a v:1 agent id that is neither the broadcast id nor a human
// (member HUM-* or door-off guest GST-*).
func isAgent(id string) bool {
	return msg.ValidID(id) && id != BroadcastID && !strings.HasPrefix(id, "HUM-") && !strings.HasPrefix(id, GuestPrefix)
}

// dispatchCheck runs contract §3 steps 1-5 for a built message and returns
// the target box and the tenant's box-wui pin, or an error frame triple.
// want (specs/058) pins the box: the agent must be announced THERE, and the
// same id on another box is then not ambiguous.
func (s *Server) dispatchCheck(ctx context.Context, c *wuiConn, m *msg.Message, want string) (box string, pin ed25519.PublicKey, tok string, status int, detail string) {
	if c.member == "" {
		return "", nil, "dispatch_unauthenticated", http.StatusUnauthorized, "commanding an agent needs a signed-in member session"
	}
	if m.Kind != "task" && m.Kind != "note" {
		return "", nil, "dispatch_kind", http.StatusBadRequest, "box-wui may only send kind task or note"
	}
	roster, err := s.o.Store.Roster(ctx, c.tenant)
	if err != nil {
		return "", nil, "internal", http.StatusInternalServerError, "roster unavailable"
	}
	var boxes []string
	for b, agents := range roster {
		if b != WUIBox && (want == "" || b == want) && contains(agents, m.To) {
			boxes = append(boxes, b)
		}
	}
	if want == "" && len(boxes) > 1 { // a role id: its lease holder's box
		boxes = s.roleSeats(ctx, c.tenant).narrow(m.To, boxes)
	}
	switch len(boxes) {
	case 0:
		if want != "" {
			return "", nil, "unknown_agent", http.StatusNotFound, m.To + " is not announced by box " + want + " of this tenant"
		}
		return "", nil, "unknown_agent", http.StatusNotFound, m.To + " is not announced by any box of this tenant"
	case 1:
		box = boxes[0]
	default:
		return "", nil, "ambiguous_to_box", http.StatusConflict, m.To + " is announced on more than one box"
	}
	if _, err := s.o.Store.GetPin(ctx, c.tenant, box); err != nil {
		return "", nil, "unpinned_box", http.StatusNotFound, box + " is not pinned in this tenant"
	}
	if pin = s.wuiPin(ctx, c.tenant); pin == nil {
		return "", nil, "wui_unpinned", http.StatusConflict, "this tenant has not pinned the hub's box-wui key (GET /v1/wui/pubkey, then pin it with the tenant root key)"
	}
	return box, pin, "", 0, ""
}

// wuiPin is the tenant's active box-wui pin when it is this hub's own key,
// else nil: the one condition under which the hub may sign for box-wui and a
// receiving box will verify it (§3 step 5). Both signers - a dispatch to one
// agent's box and a channel post fanned out to every member box - go through
// it, so a rotation window closes them together.
func (s *Server) wuiPin(ctx context.Context, tenant string) ed25519.PublicKey {
	pub := s.wuiPub()
	if pub == nil {
		return nil
	}
	pin, err := s.o.Store.GetPin(ctx, tenant, WUIBox)
	if err != nil || !pin.Equal(pub) {
		return nil
	}
	return pin
}

// warnUnpinnedAgents names the one case where the browser-only fallback of a
// channel post drops something someone asked for: the channel HAS agent
// members, but the tenant never pinned box-wui, so the post is stored
// unsigned and routeChannel builds no box delivery (SPL-950, prd csi-rel
// 2026-09-26: 9 human posts, box-wui row only, no log line anywhere). A
// channel without agents stays silent - it never asked for a box to read it.
func (s *Server) warnUnpinnedAgents(ctx context.Context, tenant, channel, msgID string) {
	members, err := s.o.Store.ChannelMembers(ctx, tenant, channel)
	if err != nil {
		return
	}
	for box, agents := range members {
		if box != WUIBox && len(agents) > 0 {
			s.o.Log.Warn().Str("tenant", tenant).Str("channel", channel).Str("msg_id", msgID).
				Msg("wui_unpinned: channel has agents but the tenant has no box-wui pin; post stays browser-only (do_spl_cloud_pin_box_wui)")
			return
		}
	}
}

// dispatchEnvelope signs m for box (with the send's channel / parent tags,
// "" = none) and verifies the result against the tenant's box-wui pin with
// the exact check a receiving box runs.
func (s *Server) dispatchEnvelope(box, channel, parentTaskID string, pin ed25519.PublicKey, m *msg.Message) (*wire.Envelope, error) {
	env, err := wire.NewEnvelopeIn(s.o.WUIKey, WUIBox, box, channel, parentTaskID, m)
	if err != nil {
		return nil, err
	}
	if err := env.Verify(pin); err != nil {
		return nil, err
	}
	return env, nil
}
