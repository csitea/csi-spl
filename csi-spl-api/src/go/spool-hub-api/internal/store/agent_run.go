package store

import (
	"context"
	"sync"
)

// Agent run state (t1 bc1a43e1, fix A; rdb 0153 roster.running). A box
// reports on its hello and announce which of its agents really run; the
// roster view then serves agent_presence "not_running" for an agent whose
// box is online but whose process is gone or stuck. An agent the box did not
// report (an older box, a stale report) has no entry and reads its box's
// presence, as before. The roster is replaced on every announcement
// (SetRoster), which clears every reported value, so the hub calls
// SetAgentRun right after SetRoster with the same frame's report.

// AgentRunner is the store half. Optional: a store without it never serves
// "not_running".
type AgentRunner interface {
	// SetAgentRun records run for the box's roster agents it names; an agent
	// not in the box's roster is ignored, one not in run stays unreported.
	SetAgentRun(ctx context.Context, tenantID, box string, run map[string]bool) error
}

// The Memory driver keeps its run state beside the store, like memBoxBeats.
var (
	memAgentRunMu sync.Mutex
	memAgentRun   = map[*Memory]map[[2]string]map[string]bool{} // (tenant, box) -> agent -> runs
)

func (s *Memory) SetAgentRun(_ context.Context, tenant, box string, run map[string]bool) error {
	s.mu.Lock()
	roster := append([]string(nil), s.roster[[2]string{tenant, box}]...)
	s.mu.Unlock()
	memAgentRunMu.Lock()
	defer memAgentRunMu.Unlock()
	got := map[string]bool{}
	for _, id := range roster {
		if r, ok := run[id]; ok {
			got[id] = r
		}
	}
	if memAgentRun[s] == nil {
		memAgentRun[s] = map[[2]string]map[string]bool{}
	}
	memAgentRun[s][[2]string{tenant, box}] = got
	return nil
}

// clearAgentRun drops the box's reported run state: SetRoster replaced its
// roster (Postgres re-inserts the rows with running NULL).
func (s *Memory) clearAgentRun(tenant, box string) {
	memAgentRunMu.Lock()
	defer memAgentRunMu.Unlock()
	delete(memAgentRun[s], [2]string{tenant, box})
}

// agentRun is the box's reported run state (ViewBox.Running); nil = none.
func (s *Memory) agentRun(tenant, box string) map[string]bool {
	memAgentRunMu.Lock()
	defer memAgentRunMu.Unlock()
	got := memAgentRun[s][[2]string{tenant, box}]
	if len(got) == 0 {
		return nil
	}
	out := make(map[string]bool, len(got))
	for id, r := range got {
		out[id] = r
	}
	return out
}

// hasAgentRun is the catalogue probe for rdb 0153. The hub may roll before
// the migration reaches its database, so until the column is there the
// roster is read and written without it: no run state, never a 500. Same
// re-check cadence as the agent_seats probe.
func (s *Postgres) hasAgentRun(ctx context.Context) bool {
	return s.run.present(ctx, func(ctx context.Context) (ok bool, err error) {
		err = s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_attribute
			WHERE attrelid = to_regclass('roster') AND attname = 'running' AND NOT attisdropped)`).Scan(&ok)
		return ok, err
	}, s.now())
}

func (s *Postgres) SetAgentRun(ctx context.Context, tenant, box string, run map[string]bool) error {
	if len(run) == 0 || !s.hasAgentRun(ctx) {
		return nil
	}
	ids := make([]string, 0, len(run))
	runs := make([]bool, 0, len(run))
	for id, r := range run {
		ids = append(ids, id)
		runs = append(runs, r)
	}
	_, err := s.execTenant(ctx, tenant, `UPDATE roster r SET running = u.run
		FROM unnest($3::text[], $4::boolean[]) AS u(agent_id, run)
		WHERE r.tenant_id = $1 AND r.box_id = $2 AND r.agent_id = u.agent_id`, tenant, box, ids, runs)
	return err
}
