package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The default model per agent kind (spec 184 row H1, contract 7.1.5, rdb
// 0309; owner HUM-10 msg 0d33aa83, Q2 bo and N1).
//
//	GET   /v1/tenant/settings -> {..., agent_models: [{vendor, kind, model, updated_by, updated_at}]}
//	PATCH /v1/tenant/settings {agent_models: {"<vendor>": {"<kind>|*": "<model>" | "" | null}}}
//	PUT   /v1/boxes/{box}/agent-models/{vendor} {cli_version, models: [...], read_at}
//	GET   /v1/tenant/agent-model-readings -> {readings: [{box, vendor, cli_version, models, read_at}]}
//
// agent_models in the PATCH sets the named cells; "" or null drops a cell,
// which then reads as the cnf env.box.agent_model. An unknown vendor or
// kind, or a model outside ^[A-Za-z0-9._:/-]{1,80}$, is 400 bad_model and
// nothing of the PATCH is written.
//
// The PUT is a box's live reading of a vendor's CLI (7.1.6). Auth is the
// box's own upload token (tokenTenant, as every desk REST call): its tenant
// is the reading's tenant, {box} must be the token's box (else 403
// box_mismatch), and a WUI socket's token is 403 box_only. The token is a
// bearer, never a cookie, so the body is read as JSON whatever its
// Content-Type (hubclient's REST sends application/octet-stream). A newer
// read_at replaces the box's reading of that vendor; an older or equal one
// is ignored; 200 either way, with stored true or false. Display only (N1).

// agentModelReadingMaxBody bounds a reading: 500 models of 80 characters.
const agentModelReadingMaxBody = 64 << 10

// agentModelReadingSkew is how far in the future a read_at may be.
const agentModelReadingSkew = 10 * time.Minute

type agentModelJSON struct {
	Vendor    string     `json:"vendor"`
	Kind      string     `json:"kind"`
	Model     string     `json:"model"`
	UpdatedBy string     `json:"updated_by,omitempty"`
	UpdatedAt *time.Time `json:"updated_at,omitempty"`
}

type agentModelReadingJSON struct {
	Box        string    `json:"box"`
	Vendor     string    `json:"vendor"`
	CLIVersion string    `json:"cli_version"`
	Models     []string  `json:"models"`
	ReadAt     time.Time `json:"read_at"`
}

// agentModelsOf is the workspace's overrides for GET /v1/tenant/settings;
// [] when this hub's store keeps none.
func (s *Server) agentModelsOf(ctx context.Context, tenant string) ([]agentModelJSON, error) {
	out := []agentModelJSON{}
	am, ok := s.o.Store.(store.AgentModels)
	if !ok {
		return out, nil
	}
	rows, err := am.AgentModels(ctx, tenant)
	if err != nil {
		return nil, err
	}
	for _, m := range rows {
		j := agentModelJSON{Vendor: m.Vendor, Kind: m.Kind, Model: m.Model, UpdatedBy: m.UpdatedBy}
		if !m.UpdatedAt.IsZero() {
			at := m.UpdatedAt
			j.UpdatedAt = &at
		}
		out = append(out, j)
	}
	return out, nil
}

// agentModelsPatch reads the optional agent_models object of PATCH
// /v1/tenant/settings and checks it before anything is written. nil: no
// cell named. ok=false: it already answered.
func (s *Server) agentModelsPatch(w http.ResponseWriter, in map[string]map[string]*string) (*store.AgentModelPatch, bool) {
	if len(in) == 0 {
		return nil, true
	}
	if _, has := s.o.Store.(store.AgentModels); !has {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no agent models")
		return nil, false
	}
	var p store.AgentModelPatch
	for vendor, kinds := range in {
		for kind, model := range kinds {
			if model == nil || *model == "" {
				p.Reset = append(p.Reset, store.AgentModelKey{Vendor: vendor, Kind: kind})
				continue
			}
			p.Set = append(p.Set, store.AgentModel{Vendor: vendor, Kind: kind, Model: *model})
		}
	}
	if err := p.Check(); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_model", badAgentModelDetail(err))
		return nil, false
	}
	return &p, true
}

func badAgentModelDetail(err error) string {
	return strings.TrimPrefix(err.Error(), store.ErrBadAgentModel.Error()+": ")
}

// saveAgentModels writes a checked agent_models patch. ok=false: it answered.
func (s *Server) saveAgentModels(w http.ResponseWriter, r *http.Request, tenant, by string, p *store.AgentModelPatch) bool {
	if p == nil {
		return true
	}
	p.By = by
	err := s.o.Store.(store.AgentModels).SetAgentModels(r.Context(), tenant, *p, s.o.Now())
	switch {
	case errors.Is(err, store.ErrBadAgentModel):
		writeErr(w, http.StatusBadRequest, "bad_model", badAgentModelDetail(err))
		return false
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "agent models not saved")
		return false
	}
	return true
}

func (s *Server) agentModelsStore(w http.ResponseWriter) (store.AgentModels, bool) {
	am, ok := s.o.Store.(store.AgentModels)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no agent models")
	}
	return am, ok
}

// readingBox runs the PUT's checks on the caller: a box's own token, for the
// box it names, a known vendor. ok=false: it answered.
func (s *Server) readingBox(w http.ResponseWriter, r *http.Request) (tenant, box, vendor string, ok bool) {
	t, tokBox, ok := s.tokenTenant(w, r)
	if !ok {
		return "", "", "", false
	}
	if tokBox == WUIBox {
		writeErr(w, http.StatusForbidden, "box_only", "a model reading comes only from a box's own token")
		return "", "", "", false
	}
	if r.PathValue("box") != tokBox {
		writeErr(w, http.StatusForbidden, "box_mismatch", "a box reports only its own model readings")
		return "", "", "", false
	}
	vendor = r.PathValue("vendor")
	if !slices.Contains(store.AgentKinds, vendor) {
		writeErr(w, http.StatusBadRequest, "bad_vendor", "vendor is one of "+strings.Join(store.AgentKinds, ", "))
		return "", "", "", false
	}
	return t.ID, tokBox, vendor, true
}

// PUT /v1/boxes/{box}/agent-models/{vendor} {cli_version, models, read_at}
func (s *Server) handlePutAgentModelReading(w http.ResponseWriter, r *http.Request) {
	tenant, box, vendor, ok := s.readingBox(w, r)
	if !ok {
		return
	}
	am, ok := s.agentModelsStore(w)
	if !ok {
		return
	}
	var in struct {
		CLIVersion string    `json:"cli_version"`
		Models     []string  `json:"models"`
		ReadAt     time.Time `json:"read_at"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, agentModelReadingMaxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_reading", `body is {"cli_version", "models": [...], "read_at": RFC 3339}`)
		return
	}
	if in.ReadAt.After(s.o.Now().Add(agentModelReadingSkew)) {
		writeErr(w, http.StatusBadRequest, "bad_reading", "read_at is in the future")
		return
	}
	rd := store.AgentModelReading{Box: box, Vendor: vendor, CLIVersion: in.CLIVersion, Models: in.Models, ReadAt: in.ReadAt}
	stored, err := am.PutAgentModelReading(r.Context(), tenant, rd)
	switch {
	case errors.Is(err, store.ErrBadAgentModel):
		writeErr(w, http.StatusBadRequest, "bad_reading", badAgentModelDetail(err))
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "model reading not saved")
		return
	}
	s.o.Log.Info().Str("tenant", tenant).Str("box", box).Str("vendor", vendor).Str("cli", in.CLIVersion).
		Int("models", len(in.Models)).Bool("stored", stored).Msg("tenant.agent_model_reading")
	writeJSON(w, http.StatusOK, map[string]any{"box": box, "vendor": vendor, "stored": stored})
}

// GET /v1/tenant/agent-model-readings
func (s *Server) handleAgentModelReadings(w http.ResponseWriter, r *http.Request) {
	t, _, _, _, ok := s.membersActor(w, r, rbac.TenantSettings)
	if !ok {
		return
	}
	am, ok := s.agentModelsStore(w)
	if !ok {
		return
	}
	rows, err := am.AgentModelReadings(r.Context(), t.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "model readings unavailable")
		return
	}
	out := make([]agentModelReadingJSON, 0, len(rows))
	for _, rd := range rows {
		out = append(out, agentModelReadingJSON{Box: rd.Box, Vendor: rd.Vendor, CLIVersion: rd.CLIVersion,
			Models: rd.Models, ReadAt: rd.ReadAt})
	}
	writeJSON(w, http.StatusOK, map[string]any{"readings": out})
}

func (s *Server) routeAgentModels(mux *http.ServeMux) {
	mux.HandleFunc("PUT /v1/boxes/{box}/agent-models/{vendor}", s.handlePutAgentModelReading)
	mux.HandleFunc("GET /v1/tenant/agent-model-readings", s.handleAgentModelReadings)
	mux.HandleFunc("OPTIONS /v1/tenant/agent-model-readings", s.tenantSettingsPreflight)
}
