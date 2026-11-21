package store

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// The default model per agent kind (spec 184 row H1, contract 7.1.5, rdb
// 0309; owner HUM-10 msg 0d33aa83, Q2 bo and N1).
//
//   - tenant_agent_model: a workspace's override of the cnf
//     env.box.agent_model, one model per (vendor, kind); kind "*" is the
//     vendor's default. No row = not set: the resolver (7.1.2) falls back to
//     the cnf. Set and read through the tenant settings (field agent_models).
//   - agent_model_reading: the latest live list a box read of a vendor's CLI
//     (7.1.6), with the CLI's version. A newer read_at replaces the row; an
//     older or equal one is ignored. Display only (N1), never a gate.
//
// CheckAgentModel and CheckAgentModelReading apply rdb 0309's CHECKs first,
// so a bad PATCH or PUT is a 400 that names the rule; the database stays the
// last word.

// AgentModelKindAll is the kind of a vendor's default row.
const AgentModelKindAll = "*"

// MaxAgentModelsListed bounds one reading's list (rdb 0309 models_check).
const MaxAgentModelsListed = 500

// agentModelRx is contract 7.1.2's model syntax (rdb 0309 model_check).
var agentModelRx = regexp.MustCompile(`^[A-Za-z0-9._:/-]{1,80}$`)

// ErrBadAgentModel: a row or a reading outside rdb 0309's rules. The wrapped
// text names the rule.
var ErrBadAgentModel = errors.New("store: bad agent model")

func badAgentModel(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrBadAgentModel, fmt.Sprintf(format, a...))
}

// ValidAgentModel reports whether m is a model contract 7.1.2 lets reach a
// command line.
func ValidAgentModel(m string) bool { return agentModelRx.MatchString(m) }

// AgentModel is one workspace override.
type AgentModel struct {
	Vendor    string
	Kind      string // one of SplitTaskKinds, or AgentModelKindAll
	Model     string
	UpdatedBy string
	UpdatedAt time.Time
}

// AgentModelKey names one (vendor, kind) cell.
type AgentModelKey struct{ Vendor, Kind string }

// checkAgentModelKey refuses a vendor outside AgentKinds and a kind outside
// SplitTaskKinds and "*".
func checkAgentModelKey(k AgentModelKey) error {
	if !slices.Contains(AgentKinds, k.Vendor) {
		return badAgentModel("vendor %q is not one of %s", k.Vendor, strings.Join(AgentKinds, ", "))
	}
	if k.Kind != AgentModelKindAll && !slices.Contains(SplitTaskKinds, k.Kind) {
		return badAgentModel("%s: kind %q is not * or one of %s", k.Vendor, k.Kind, strings.Join(SplitTaskKinds, ", "))
	}
	return nil
}

// CheckAgentModel applies rdb 0309's row CHECKs to m.
func CheckAgentModel(m AgentModel) error {
	if err := checkAgentModelKey(AgentModelKey{m.Vendor, m.Kind}); err != nil {
		return err
	}
	if !ValidAgentModel(m.Model) {
		return badAgentModel("%s:%s: model %q is not 1..80 of A-Z a-z 0-9 . _ : / -", m.Vendor, m.Kind, m.Model)
	}
	return nil
}

// AgentModelPatch sets the cells of Set and drops the cells of Reset, which
// then read as not set (the cnf).
type AgentModelPatch struct {
	Set   []AgentModel
	Reset []AgentModelKey
	By    string // the human who changed it
}

// Check applies CheckAgentModel to every Set row and refuses a twice-named
// cell and an empty patch.
func (p *AgentModelPatch) Check() error {
	seen := map[AgentModelKey]bool{}
	name := func(k AgentModelKey) error {
		if seen[k] {
			return badAgentModel("%s:%s is named twice", k.Vendor, k.Kind)
		}
		seen[k] = true
		return nil
	}
	for _, m := range p.Set {
		if err := CheckAgentModel(m); err != nil {
			return err
		}
		if err := name(AgentModelKey{m.Vendor, m.Kind}); err != nil {
			return err
		}
	}
	for _, k := range p.Reset {
		if err := checkAgentModelKey(k); err != nil {
			return err
		}
		if err := name(k); err != nil {
			return err
		}
	}
	if len(seen) == 0 {
		return badAgentModel("name at least one vendor and kind")
	}
	return nil
}

// AgentModelReading is one box's latest live list of one vendor's models.
type AgentModelReading struct {
	Box        string
	Vendor     string
	CLIVersion string
	Models     []string
	ReadAt     time.Time
}

// CheckAgentModelReading applies rdb 0309's reading CHECKs: a box id, a
// known vendor, a printable CLI version of at most 80 characters, at most
// MaxAgentModelsListed models each in the 7.1.2 syntax, and a read time.
func CheckAgentModelReading(r AgentModelReading) error {
	if !msg.ValidBoxID(r.Box) {
		return badAgentModel("box %q is not a box id", r.Box)
	}
	if !slices.Contains(AgentKinds, r.Vendor) {
		return badAgentModel("vendor %q is not one of %s", r.Vendor, strings.Join(AgentKinds, ", "))
	}
	if len(r.CLIVersion) > 80 || strings.IndexFunc(r.CLIVersion, func(c rune) bool { return !unicode.IsPrint(c) }) >= 0 {
		return badAgentModel("cli_version is at most 80 printable characters")
	}
	if len(r.Models) > MaxAgentModelsListed {
		return badAgentModel("%d models, at most %d", len(r.Models), MaxAgentModelsListed)
	}
	for _, m := range r.Models {
		if !ValidAgentModel(m) {
			return badAgentModel("model %q is not 1..80 of A-Z a-z 0-9 . _ : / -", m)
		}
	}
	if r.ReadAt.IsZero() {
		return badAgentModel("read_at is required")
	}
	return nil
}

// AgentModels is implemented by Memory and Postgres.
type AgentModels interface {
	// AgentModels is the workspace's overrides, by vendor (AgentKinds
	// order), then kind ("*" first, then SplitTaskKinds order).
	AgentModels(ctx context.Context, tenant string) ([]AgentModel, error)
	// SetAgentModels applies p in one transaction; ErrBadAgentModel names a
	// broken rule and nothing is written. ErrNotFound: no such tenant.
	SetAgentModels(ctx context.Context, tenant string, p AgentModelPatch, now time.Time) error
	// PutAgentModelReading stores r when its ReadAt is newer than the stored
	// one (or none is stored); stored is false when it was ignored.
	PutAgentModelReading(ctx context.Context, tenant string, r AgentModelReading) (stored bool, err error)
	// AgentModelReadings is every reading of the workspace, by box, then
	// vendor (AgentKinds order).
	AgentModelReadings(ctx context.Context, tenant string) ([]AgentModelReading, error)
}

var (
	_ AgentModels = (*Memory)(nil)
	_ AgentModels = (*Postgres)(nil)
)

// agentModelKindRank orders "*" first, then SplitTaskKinds.
func agentModelKindRank(kind string) int {
	if kind == AgentModelKindAll {
		return -1
	}
	return slices.Index(SplitTaskKinds, kind)
}

func sortAgentModels(rows []AgentModel) {
	slices.SortFunc(rows, func(a, b AgentModel) int {
		if d := slices.Index(AgentKinds, a.Vendor) - slices.Index(AgentKinds, b.Vendor); d != 0 {
			return d
		}
		return agentModelKindRank(a.Kind) - agentModelKindRank(b.Kind)
	})
}

func sortAgentModelReadings(rows []AgentModelReading) {
	slices.SortFunc(rows, func(a, b AgentModelReading) int {
		if c := strings.Compare(a.Box, b.Box); c != 0 {
			return c
		}
		return slices.Index(AgentKinds, a.Vendor) - slices.Index(AgentKinds, b.Vendor)
	})
}

// memAgentModels is the Memory side, guarded by Memory.mu.
type memAgentModels struct {
	cells    map[string]map[AgentModelKey]AgentModel    // tenant -> cell -> row
	readings map[string]map[[2]string]AgentModelReading // tenant -> (box, vendor) -> reading
}

// ---- Memory -----------------------------------------------------------------

// AgentModels implements AgentModels on Memory.
func (s *Memory) AgentModels(_ context.Context, tenant string) ([]AgentModel, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return nil, ErrNotFound
	}
	out := []AgentModel{}
	for _, m := range s.agentModels.cells[tenant] {
		out = append(out, m)
	}
	sortAgentModels(out)
	return out, nil
}

// SetAgentModels implements AgentModels on Memory: p is checked whole first.
func (s *Memory) SetAgentModels(_ context.Context, tenant string, p AgentModelPatch, now time.Time) error {
	if err := p.Check(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return ErrNotFound
	}
	if s.agentModels.cells == nil {
		s.agentModels.cells = map[string]map[AgentModelKey]AgentModel{}
	}
	cells := s.agentModels.cells[tenant]
	if cells == nil {
		cells = map[AgentModelKey]AgentModel{}
		s.agentModels.cells[tenant] = cells
	}
	for _, m := range p.Set {
		m.UpdatedBy, m.UpdatedAt = p.By, now.UTC()
		cells[AgentModelKey{m.Vendor, m.Kind}] = m
	}
	for _, k := range p.Reset {
		delete(cells, k)
	}
	return nil
}

// PutAgentModelReading implements AgentModels on Memory: only a newer read_at replaces.
func (s *Memory) PutAgentModelReading(_ context.Context, tenant string, r AgentModelReading) (bool, error) {
	if err := CheckAgentModelReading(r); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return false, ErrNotFound
	}
	if s.agentModels.readings == nil {
		s.agentModels.readings = map[string]map[[2]string]AgentModelReading{}
	}
	rs := s.agentModels.readings[tenant]
	if rs == nil {
		rs = map[[2]string]AgentModelReading{}
		s.agentModels.readings[tenant] = rs
	}
	key := [2]string{r.Box, r.Vendor}
	if old, ok := rs[key]; ok && !r.ReadAt.After(old.ReadAt) {
		return false, nil
	}
	r.Models = append([]string{}, r.Models...)
	r.ReadAt = r.ReadAt.UTC()
	rs[key] = r
	return true, nil
}

// AgentModelReadings implements AgentModels on Memory.
func (s *Memory) AgentModelReadings(_ context.Context, tenant string) ([]AgentModelReading, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return nil, ErrNotFound
	}
	out := []AgentModelReading{}
	for _, r := range s.agentModels.readings[tenant] {
		r.Models = append([]string{}, r.Models...)
		out = append(out, r)
	}
	sortAgentModelReadings(out)
	return out, nil
}

// ---- Postgres ---------------------------------------------------------------

// AgentModels reads tenant_agent_model under the tenant's RLS scope.
func (s *Postgres) AgentModels(ctx context.Context, tenant string) ([]AgentModel, error) {
	out := []AgentModel{}
	err := s.queryTenant(ctx, tenant, `SELECT vendor, kind, model, updated_by, updated_at
		FROM tenant_agent_model WHERE tenant_id = $1`, []any{tenant}, func(rows pgx.Rows) error {
		var m AgentModel
		if err := rows.Scan(&m.Vendor, &m.Kind, &m.Model, &m.UpdatedBy, &m.UpdatedAt); err != nil {
			return err
		}
		m.UpdatedAt = m.UpdatedAt.UTC()
		out = append(out, m)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sortAgentModels(out)
	return out, nil
}

// SetAgentModels upserts the Set cells and deletes the Reset ones in one
// transaction; a CHECK rdb 0309 raises is ErrBadAgentModel.
func (s *Postgres) SetAgentModels(ctx context.Context, tenant string, p AgentModelPatch, now time.Time) error {
	if err := p.Check(); err != nil {
		return err
	}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		for _, k := range p.Reset {
			if _, err := tx.Exec(ctx, `DELETE FROM tenant_agent_model
				WHERE tenant_id = $1 AND vendor = $2 AND kind = $3`, tenant, k.Vendor, k.Kind); err != nil {
				return err
			}
		}
		for _, m := range p.Set {
			if _, err := tx.Exec(ctx, `INSERT INTO tenant_agent_model
				(tenant_id, vendor, kind, model, updated_by, updated_at) VALUES ($1, $2, $3, $4, $5, $6)
				ON CONFLICT (tenant_id, vendor, kind) DO UPDATE
				SET model = EXCLUDED.model, updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at`,
				tenant, m.Vendor, m.Kind, m.Model, p.By, now.UTC()); err != nil {
				return err
			}
		}
		return nil
	})
	return agentModelPgErr(err)
}

// agentModelPgErr maps a missing tenant to ErrNotFound and a CHECK to
// ErrBadAgentModel.
func agentModelPgErr(err error) error {
	var pe *pgconn.PgError
	switch {
	case errors.As(err, &pe) && pe.Code == "23503": // tenant_id REFERENCES tenants
		return ErrNotFound
	case errors.As(err, &pe) && pe.Code == "23514":
		return badAgentModel("%s", pe.ConstraintName)
	}
	return err
}

// PutAgentModelReading upserts the reading only over an older one: the
// conflict's WHERE leaves a newer or equal stored read_at in place.
func (s *Postgres) PutAgentModelReading(ctx context.Context, tenant string, r AgentModelReading) (bool, error) {
	if err := CheckAgentModelReading(r); err != nil {
		return false, err
	}
	models := r.Models
	if models == nil {
		models = []string{}
	}
	var n int64
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO agent_model_reading
			(tenant_id, box, vendor, cli_version, models, read_at) VALUES ($1, $2, $3, $4, $5, $6)
			ON CONFLICT (tenant_id, box, vendor) DO UPDATE
			SET cli_version = EXCLUDED.cli_version, models = EXCLUDED.models, read_at = EXCLUDED.read_at
			WHERE agent_model_reading.read_at < EXCLUDED.read_at`,
			tenant, r.Box, r.Vendor, r.CLIVersion, models, r.ReadAt.UTC())
		n = tag.RowsAffected()
		return err
	})
	if err != nil {
		return false, agentModelPgErr(err)
	}
	return n == 1, nil
}

// AgentModelReadings reads agent_model_reading under the tenant's RLS scope.
func (s *Postgres) AgentModelReadings(ctx context.Context, tenant string) ([]AgentModelReading, error) {
	out := []AgentModelReading{}
	err := s.queryTenant(ctx, tenant, `SELECT box, vendor, cli_version, models, read_at
		FROM agent_model_reading WHERE tenant_id = $1`, []any{tenant}, func(rows pgx.Rows) error {
		var r AgentModelReading
		if err := rows.Scan(&r.Box, &r.Vendor, &r.CLIVersion, &r.Models, &r.ReadAt); err != nil {
			return err
		}
		if r.Models == nil {
			r.Models = []string{}
		}
		r.ReadAt = r.ReadAt.UTC()
		out = append(out, r)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sortAgentModelReadings(out)
	return out, nil
}
