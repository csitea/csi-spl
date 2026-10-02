package hub

import (
	"context"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 061 (agent id rename), wave A: the hub accepts both c-004 and the
// legacy CLE-77952. A legacy id a box frame carries is resolved through the
// tenant's alias table (rdb 0101) at the edge, and after agentid.LegacyUntil
// it is refused with the FR-003 text. A signed envelope's from / to cannot be
// rewritten, so a send is only checked.

// TokenRetiredID is the error token of a legacy id after the deadline.
const TokenRetiredID = "retired_id"

func (s *Server) routeAgentAliases(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/agent-aliases", s.viewHandler(s.handleAgentAliases))
	mux.HandleFunc("OPTIONS /v1/agent-aliases", s.preflight)
}

// agentAliasesBody is GET /api/v1/agent-aliases: the tenant's whole table
// and the deadline, so the WUI resolves an old mention without a constant of
// its own going stale.
type agentAliasesBody struct {
	LegacyUntil string             `json:"legacy_until"`
	Aliases     []store.AgentAlias `json:"aliases"`
}

func (s *Server) handleAgentAliases(w http.ResponseWriter, r *http.Request, t store.Tenant) {
	as, err := s.o.Store.ListAgentAliases(r.Context(), t.ID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", t.ID).Msg("agent aliases")
		writeErr(w, http.StatusInternalServerError, "internal", "aliases unavailable")
		return
	}
	writeJSON(w, http.StatusOK, agentAliasesBody{LegacyUntil: agentid.LegacyUntilText, Aliases: as})
}

// aliasLookup reads the tenant's table once, on the first legacy id it is
// asked about. A store error reads as an empty table: before the deadline
// the id is then accepted as itself (FR-002), after it refused all the same.
func (s *Server) aliasLookup(ctx context.Context, tenant string) agentid.Lookup {
	var m agentid.Table
	return func(old, box string) (string, bool) {
		if m == nil {
			m = agentid.Table{}
			as, err := s.o.Store.ListAgentAliases(ctx, tenant)
			if err != nil {
				s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("agent alias lookup")
			}
			for _, a := range as {
				m[[2]string{a.OldID, a.BoxID}] = a.NewID
			}
		}
		return m.Lookup(old, box)
	}
}

// resolveAgent is the edge rule for an id ("<id>" or "<id>@<box>") a box
// frame carries: the new id of an aliased legacy id, the id itself, or the
// FR-003 refusal after the deadline. "" passes through.
func (s *Server) resolveAgent(ctx context.Context, tenant, id, box string) (string, *issueErr) {
	if id == "" {
		return "", nil
	}
	got, err := agentid.ResolveOn(id, box, s.aliasLookup(ctx, tenant))
	if err != nil {
		return "", &issueErr{http.StatusBadRequest, TokenRetiredID, err.Error()}
	}
	return got, nil
}

// sendIDRefusal: after the deadline a send from or to a legacy agent id is
// refused (FR-003), naming the new id when the table has one.
func (s *Server) sendIDRefusal(ctx context.Context, x *session, from, to, toBox string) *frameRefusal {
	lk := s.aliasLookup(ctx, x.tenant)
	for _, id := range []string{from + "@" + x.box, to + "@" + toBox} {
		if err := agentid.Check(strings.TrimSuffix(id, "@"), lk); err != nil {
			return &frameRefusal{TokenRetiredID, http.StatusBadRequest, err.Error()}
		}
	}
	return nil
}
