package hub

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Per-workspace agent caps, the workspace's read (spec 147 6.2, SPL-2675):
// every member reads the caps and the live count per vendor; nobody in the
// workspace changes them (P3: only the operator routes write, and rdb 0212
// refuses a workspace-scoped write). Any method but GET / OPTIONS is 405
// (the mux answers it).
//
//	GET /v1/tenant/agent-caps     a member session
//	lane_op agent_caps_get        a box of the workspace (spool caps, the
//	                              desk seating pre-check, spec 147 5.2)

// tenantAgentCapsBody lists every vendor: caps null = uncapped.
type tenantAgentCapsBody struct {
	WorkspaceID string          `json:"workspace_id"`
	Caps        map[string]*int `json:"caps"`
	Live        map[string]int  `json:"live"`
	CanEdit     bool            `json:"can_edit"`
}

// tenantAgentCaps reads the workspace's caps and live counts.
func (s *Server) tenantAgentCaps(ctx context.Context, cs store.AgentCapStore, tenant string) (tenantAgentCapsBody, error) {
	c, err := cs.AgentCaps(ctx, tenant)
	if err != nil {
		return tenantAgentCapsBody{}, err
	}
	live, err := cs.LiveAgents(ctx, tenant, s.o.Now())
	if err != nil {
		return tenantAgentCapsBody{}, err
	}
	out := tenantAgentCapsBody{WorkspaceID: tenant, Caps: map[string]*int{}, Live: map[string]int{}}
	for _, v := range store.AgentCapVendors {
		out.Caps[v] = nil
		if n, ok := c.Caps[v]; ok {
			out.Caps[v] = &n
		}
		out.Live[v] = live[v]
	}
	return out, nil
}

// GET /v1/tenant/agent-caps
func (s *Server) handleTenantAgentCaps(w http.ResponseWriter, r *http.Request) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.TopicsRead)
	if !ok {
		return
	}
	cs, ok := s.o.Store.(store.AgentCapStore)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no agent caps")
		return
	}
	out, err := s.tenantAgentCaps(r.Context(), cs, t.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "agent caps not read")
		return
	}
	// can_edit: only an admin of the operator workspace, in it, edits caps.
	op, err := s.operatorTenant(r.Context())
	out.CanEdit = err == nil && op != "" && op == t.ID && a.Role == rbac.Admin
	writeJSON(w, http.StatusOK, out)
}

// isAgentCapsLaneOp routes a lane frame to onAgentCapsLane.
func isAgentCapsLaneOp(op string) bool { return strings.HasPrefix(op, "agent_caps_") }

// onAgentCapsLane answers agent_caps_get for the box's own workspace; the
// reply rides the lane field, as box_stats_list's does.
func (s *Server) onAgentCapsLane(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a lane frame needs msg_id (a UUID) to pair the reply")
		return
	}
	if f.LaneOp != "agent_caps_get" {
		x.fail(ctx, id, "bad_frame", http.StatusBadRequest, "agent caps lane ops: agent_caps_get")
		return
	}
	cs, ok := s.o.Store.(store.AgentCapStore)
	if !ok {
		x.fail(ctx, id, "unsupported", http.StatusNotImplemented, "this hub's store keeps no agent caps")
		return
	}
	out, err := s.tenantAgentCaps(ctx, cs, x.tenant)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "agent caps not read")
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TLane, MsgID: id, LaneOp: f.LaneOp, Fleet: f.Fleet, Lane: raw}) //nolint:errcheck
}
