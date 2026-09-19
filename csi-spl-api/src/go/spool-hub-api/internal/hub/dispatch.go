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
	id := b[1:]
	if i := strings.IndexAny(id, " \t\r\n"); i >= 0 {
		id = id[:i]
	}
	id = strings.TrimRight(id, ",:;")
	if isAgent(id) {
		return id
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
func (s *Server) dispatchCheck(ctx context.Context, c *wuiConn, m *msg.Message) (box string, pin ed25519.PublicKey, tok string, status int, detail string) {
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
		if b != WUIBox && contains(agents, m.To) {
			boxes = append(boxes, b)
		}
	}
	switch len(boxes) {
	case 0:
		return "", nil, "unknown_agent", http.StatusNotFound, m.To + " is not announced by any box of this tenant"
	case 1:
		box = boxes[0]
	default:
		return "", nil, "ambiguous_to_box", http.StatusConflict, m.To + " is announced on more than one box"
	}
	if _, err := s.o.Store.GetPin(ctx, c.tenant, box); err != nil {
		return "", nil, "unpinned_box", http.StatusNotFound, box + " is not pinned in this tenant"
	}
	pin, err = s.o.Store.GetPin(ctx, c.tenant, WUIBox)
	if err != nil || !pin.Equal(s.wuiPub()) {
		return "", nil, "wui_unpinned", http.StatusConflict, "this tenant has not pinned the hub's box-wui key (GET /v1/wui/pubkey, then pin it with the tenant root key)"
	}
	return box, pin, "", 0, ""
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
