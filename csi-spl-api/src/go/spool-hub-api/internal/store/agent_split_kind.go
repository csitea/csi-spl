package store

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// The vendor split per task kind (spec 115 sections 2 and 3.2, rdb 0163):
// for each of six task kinds, how new agent work of that kind is shared
// across the five vendors (AgentKinds), out of 100, and the backup vendor
// that takes over after two failed tries of the main. The main is the one
// vendor with the highest weight.
//
// A workspace sets a kind or leaves it unset; an unset kind reads as the
// spec 115 section 2 row (DefaultSplitKinds), which is also the cnf
// env.box.agent_split_by_kind row. CheckSplitKind applies rdb 0163's CHECKs
// and deferred trigger first, so a bad PATCH is a 400 that names the rule;
// the database stays the last word.

// SplitTaskKinds are the six task kinds, in the order the WUI shows them.
// The picker's aliases (spec, hard, default) are never stored.
var SplitTaskKinds = []string{"specs_and_docs", "tests", "simple_coding", "complex_coding", "i18n", "secret"}

// splitCodingKinds are the kinds agy never serves (spec 115 G2): weight 0
// and never the backup.
var splitCodingKinds = []string{"tests", "simple_coding", "complex_coding"}

// splitSecretVendors are the only vendors the secret kind may weigh or name
// as its backup (the data rule).
var splitSecretVendors = []string{"claude", "mistral"}

// SplitKind is one task kind's row.
type SplitKind struct {
	Kind    string
	Weights map[string]int // every vendor of AgentKinds; one left out is 0
	Backup  string
	// Set is false when the workspace has no row for the kind: Weights and
	// Backup are then the default (spec 115 section 2).
	Set       bool
	UpdatedBy string
	UpdatedAt time.Time
}

// Main is the vendor with the strict maximum weight ("" on a tie).
func (k SplitKind) Main() string {
	main, top, tie := "", -1, false
	for _, v := range AgentKinds {
		switch w := k.Weights[v]; {
		case w > top:
			main, top, tie = v, w, false
		case w == top:
			tie = true
		}
	}
	if tie {
		return ""
	}
	return main
}

// DefaultSplitKinds is the spec 115 section 2 table, in SplitTaskKinds
// order, each Set false.
func DefaultSplitKinds() []SplitKind {
	row := func(kind, backup string, w map[string]int) SplitKind {
		return SplitKind{Kind: kind, Weights: fullWeights(w), Backup: backup}
	}
	return []SplitKind{
		row("specs_and_docs", "claude", map[string]int{"agy": 70, "mistral": 20, "claude": 10}),
		row("tests", "mistral", map[string]int{"claude": 70, "mistral": 30}),
		row("simple_coding", "claude", map[string]int{"mistral": 80, "claude": 20}),
		row("complex_coding", "mistral", map[string]int{"claude": 80, "mistral": 20}),
		row("i18n", "claude", map[string]int{"agy": 100}),
		row("secret", "mistral", map[string]int{"claude": 100}),
	}
}

// ErrBadSplitKind: a row outside the spec 115 section 2 rules. The wrapped
// text names the rule.
var ErrBadSplitKind = errors.New("store: bad agent split kind")

func badSplitKind(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrBadSplitKind, fmt.Sprintf(format, a...))
}

// CheckSplitKind applies the rdb 0163 rules to one row: a known kind and
// known vendors, every weight 0..100 summing to 100, one strict main, a
// backup that is a vendor other than the main, agy 0 and never the backup
// in a coding kind, and only claude or mistral in secret.
func CheckSplitKind(k SplitKind) error {
	if !slices.Contains(SplitTaskKinds, k.Kind) {
		return badSplitKind("kind %q is not one of %s", k.Kind, strings.Join(SplitTaskKinds, ", "))
	}
	sum := 0
	for v, w := range k.Weights {
		if !slices.Contains(AgentKinds, v) {
			return badSplitKind("%s: vendor %q is not one of %s", k.Kind, v, strings.Join(AgentKinds, ", "))
		}
		if w < 0 || w > 100 {
			return badSplitKind("%s: %s is %d, want 0..100", k.Kind, v, w)
		}
		sum += w
	}
	if sum != 100 {
		return badSplitKind("%s: the weights sum to %d, want 100", k.Kind, sum)
	}
	main := k.Main()
	if main == "" {
		return badSplitKind("%s: two vendors tie for the highest weight, want one main", k.Kind)
	}
	if !slices.Contains(AgentKinds, k.Backup) {
		return badSplitKind("%s: backup %q is not one of %s", k.Kind, k.Backup, strings.Join(AgentKinds, ", "))
	}
	if k.Backup == main {
		return badSplitKind("%s: the backup is the main (%s)", k.Kind, main)
	}
	if slices.Contains(splitCodingKinds, k.Kind) && (k.Weights["agy"] > 0 || k.Backup == "agy") {
		return badSplitKind("%s: agy writes no code, so it is 0 and never the backup in a coding kind", k.Kind)
	}
	if k.Kind == "secret" {
		for v, w := range k.Weights {
			if w > 0 && !slices.Contains(splitSecretVendors, v) {
				return badSplitKind("secret: only claude and mistral take secret work, %s is %d", v, w)
			}
		}
		if !slices.Contains(splitSecretVendors, k.Backup) {
			return badSplitKind("secret: the backup must be claude or mistral, not %s", k.Backup)
		}
	}
	return nil
}

// fullWeights is w with every vendor of AgentKinds present.
func fullWeights(w map[string]int) map[string]int {
	out := make(map[string]int, len(AgentKinds))
	for _, v := range AgentKinds {
		out[v] = w[v]
	}
	return out
}

// SplitKindPatch replaces the kinds of Set (each whole) and drops the
// workspace's rows of the kinds of Reset, which then read as the default.
type SplitKindPatch struct {
	Set   []SplitKind
	Reset []string
	By    string // the human who changed it
}

// check applies CheckSplitKind to every Set row and refuses an unknown or
// twice-named kind, and an empty patch.
func (p *SplitKindPatch) check() error {
	seen := map[string]bool{}
	for i, k := range p.Set {
		if err := CheckSplitKind(k); err != nil {
			return err
		}
		if seen[k.Kind] {
			return badSplitKind("%s is named twice", k.Kind)
		}
		seen[k.Kind] = true
		p.Set[i].Weights = fullWeights(k.Weights)
	}
	for _, kind := range p.Reset {
		if !slices.Contains(SplitTaskKinds, kind) {
			return badSplitKind("kind %q is not one of %s", kind, strings.Join(SplitTaskKinds, ", "))
		}
		if seen[kind] {
			return badSplitKind("%s is named twice", kind)
		}
		seen[kind] = true
	}
	if len(seen) == 0 {
		return badSplitKind("name at least one kind")
	}
	return nil
}

// SplitKinds is implemented by Memory and Postgres.
type SplitKinds interface {
	// SplitKinds is every kind of SplitTaskKinds, in that order: the
	// workspace's row, or the default with Set false. ErrNotFound: no tenant
	// (Memory; Postgres reads an unknown tenant as all defaults).
	SplitKinds(ctx context.Context, tenant string) ([]SplitKind, error)
	// SetSplitKinds applies p in one transaction; ErrBadSplitKind names a
	// broken rule and nothing is written.
	SetSplitKinds(ctx context.Context, tenant string, p SplitKindPatch, now time.Time) error
}

var (
	_ SplitKinds = (*Memory)(nil)
	_ SplitKinds = (*Postgres)(nil)
)

// mergeSplitKinds lays the stored rows over the defaults.
func mergeSplitKinds(stored map[string]SplitKind) []SplitKind {
	out := DefaultSplitKinds()
	for i, d := range out {
		if k, ok := stored[d.Kind]; ok {
			k.Weights = fullWeights(k.Weights)
			k.Set = true
			out[i] = k
		}
	}
	return out
}

// ---- Memory -----------------------------------------------------------------

func (s *Memory) SplitKinds(_ context.Context, tenant string) ([]SplitKind, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return nil, ErrNotFound
	}
	stored := map[string]SplitKind{}
	for k, v := range s.splitKinds[tenant] {
		v.Weights = maps.Clone(v.Weights)
		stored[k] = v
	}
	return mergeSplitKinds(stored), nil
}

func (s *Memory) SetSplitKinds(_ context.Context, tenant string, p SplitKindPatch, now time.Time) error {
	if err := p.check(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return ErrNotFound
	}
	if s.splitKinds == nil {
		s.splitKinds = map[string]map[string]SplitKind{}
	}
	if s.splitKinds[tenant] == nil {
		s.splitKinds[tenant] = map[string]SplitKind{}
	}
	for _, k := range p.Set {
		k.Weights = maps.Clone(k.Weights)
		k.UpdatedBy, k.UpdatedAt = p.By, now.UTC()
		s.splitKinds[tenant][k.Kind] = k
	}
	for _, kind := range p.Reset {
		delete(s.splitKinds[tenant], kind)
	}
	return nil
}

// ---- Postgres ---------------------------------------------------------------

func (s *Postgres) SplitKinds(ctx context.Context, tenant string) ([]SplitKind, error) {
	stored := map[string]SplitKind{}
	err := s.queryTenant(ctx, tenant, `SELECT kind, vendor, weight, is_backup, updated_by, updated_at
		FROM tenant_agent_split_kind WHERE tenant_id = $1`, []any{tenant}, func(rows pgx.Rows) error {
		var kind, vendor, by string
		var w int16
		var backup bool
		var at time.Time
		if err := rows.Scan(&kind, &vendor, &w, &backup, &by, &at); err != nil {
			return err
		}
		k, ok := stored[kind]
		if !ok {
			k = SplitKind{Kind: kind, Weights: map[string]int{}}
		}
		k.Weights[vendor] = int(w)
		if backup {
			k.Backup = vendor
		}
		if at.After(k.UpdatedAt) {
			k.UpdatedBy, k.UpdatedAt = by, at.UTC()
		}
		stored[kind] = k
		return nil
	})
	if err != nil {
		return nil, err
	}
	return mergeSplitKinds(stored), nil
}

// SetSplitKinds rewrites the named kinds' rows (one per vendor, zeros
// included) in one transaction; rdb 0163's deferred trigger checks each kind
// at commit, and a CHECK it raises is ErrBadSplitKind.
func (s *Postgres) SetSplitKinds(ctx context.Context, tenant string, p SplitKindPatch, now time.Time) error {
	if err := p.check(); err != nil {
		return err
	}
	kinds := slices.Clone(p.Reset)
	for _, k := range p.Set {
		kinds = append(kinds, k.Kind)
	}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM tenant_agent_split_kind WHERE tenant_id = $1 AND kind = ANY($2)`,
			tenant, kinds); err != nil {
			return err
		}
		for _, k := range p.Set {
			for _, v := range AgentKinds {
				if _, err := tx.Exec(ctx, `INSERT INTO tenant_agent_split_kind
					(tenant_id, kind, vendor, weight, is_backup, updated_by, updated_at)
					VALUES ($1, $2, $3, $4, $5, $6, $7)`,
					tenant, k.Kind, v, k.Weights[v], v == k.Backup, p.By, now.UTC()); err != nil {
					return err
				}
			}
		}
		return nil
	})
	var pe *pgconn.PgError
	switch {
	case errors.As(err, &pe) && pe.Code == "23503": // tenant_id REFERENCES tenants
		return ErrNotFound
	case errors.As(err, &pe) && pe.Code == "23514":
		return badSplitKind("%s", pe.Message)
	}
	return err
}
