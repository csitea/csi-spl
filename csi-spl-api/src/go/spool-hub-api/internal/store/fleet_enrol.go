package store

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// A fleet desk box enrols a key (spec 158 section 4.2 item 4, build row T7,
// POST /v1/fleet/enrol, rdb 0243): the hub pins pub in tenant as box with
// box_mode 'fleet'. The route has already checked both signatures, the
// listing (rdb 0230 fleet_desk_boxes) and tenants.fleet_seating; the store
// keeps the pin rules:
//
//   - a pin revoked at or after the box was listed is never re-enrolled
//     (ErrFleetPinRevoked) until the operator lists the box again;
//   - the op ts is later than the pin's last op (ErrStale, a replay);
//   - a live pin of another key is kept (ErrConflict), and pub live on any
//     other box of any workspace is refused (ErrKeyLive, spec 108 3.2);
//   - the same key already live writes only the op ts (created false).

// BoxModeFleet is a pin a fleet desk box enrolled (rdb 0243).
const BoxModeFleet = "fleet"

// ErrFleetPinRevoked is a pin revoked since the box was listed as a fleet desk.
var ErrFleetPinRevoked = errors.New("fleet enrol: this box's pin in the workspace was revoked after it was listed")

// FleetEnrolPin is one enrolment: ListedAt is the box's fleet_desk_boxes
// added_at, OpTS the signed ts.
type FleetEnrolPin struct {
	Tenant, Box string
	PubKey      ed25519.PublicKey
	ListedAt    time.Time
	OpTS, Now   time.Time
}

// FleetWorkspace is one workspace a fleet desk box may seat, and whether the
// box already holds a live pin in it.
type FleetWorkspace struct {
	Tenant string `json:"tenant"`
	Pinned bool   `json:"pinned"`
}

// FleetEnrol is implemented by Memory and Postgres.
type FleetEnrol interface {
	// EnrolFleetPin applies the rules above; created false = the same key
	// was already live.
	EnrolFleetPin(ctx context.Context, p FleetEnrolPin) (bool, error)
	// ListFleetWorkspaces answers every workspace with fleet_seating true,
	// not suspended, not archived, the system workspace aside, by id.
	ListFleetWorkspaces(ctx context.Context, box string) ([]FleetWorkspace, error)
}

var (
	_ FleetEnrol = (*Memory)(nil)
	_ FleetEnrol = (*Postgres)(nil)
)

// fleetPinGate is the rules on the pin row as it is: revoked is its
// revoked_at (nil = live or no row), had false = no row.
func fleetPinGate(p FleetEnrolPin, had bool, old []byte, revoked, lastOp *time.Time) (same bool, err error) {
	switch {
	case !had:
		return false, nil
	case revoked != nil && !revoked.Before(p.ListedAt):
		return false, ErrFleetPinRevoked
	case lastOp != nil && !p.OpTS.After(*lastOp):
		return false, ErrStale
	case revoked == nil && bytes.Equal(old, p.PubKey):
		return true, nil
	case revoked == nil:
		return false, ErrConflict
	}
	return false, nil
}

// ---- Memory -----------------------------------------------------------------

// EnrolFleetPin is FleetEnrol on Memory; a pin's revoke time is its newest
// revoke history row.
func (s *Memory) EnrolFleetPin(_ context.Context, p FleetEnrolPin) (bool, error) {
	p.OpTS = p.OpTS.Truncate(time.Microsecond)
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[p.Tenant]; !ok {
		return false, ErrNotFound
	}
	k := [2]string{p.Tenant, p.Box}
	old, had := s.pins[k]
	var pub []byte
	var revoked, lastOp *time.Time
	if had {
		pub, revoked, lastOp = old.pub, s.memRevokedAt(k, old), &old.lastOp
		if old.lastOp.IsZero() {
			lastOp = nil
		}
	}
	same, err := fleetPinGate(p, had, pub, revoked, lastOp)
	switch {
	case err != nil:
		return false, err
	case same:
		old.lastOp = p.OpTS
		return false, nil
	case s.keyLiveElsewhere(p.Tenant, p.Box, p.PubKey):
		return false, ErrKeyLive
	}
	cp := append(ed25519.PublicKey(nil), p.PubKey...)
	s.pins[k] = &memPin{pub: cp, lastOp: p.OpTS, mode: BoxModeFleet}
	s.history = append(s.history, memHist{tenant: p.Tenant, box: p.Box, reason: BoxModeFleet, pub: cp, at: p.Now})
	return true, nil
}

// memRevokedAt is the newest revoke-like history row of a revoked pin;
// nil for a live one. Under s.mu.
func (s *Memory) memRevokedAt(k [2]string, p *memPin) *time.Time {
	if !p.revoked {
		return nil
	}
	at := time.Time{}
	for _, h := range s.history {
		revoke := h.reason == "revoke" || h.reason == "wui-revoke" || h.reason == "membership-end"
		if revoke && h.tenant == k[0] && h.box == k[1] && h.at.After(at) {
			at = h.at
		}
	}
	return &at
}

// ListFleetWorkspaces is FleetEnrol on Memory.
func (s *Memory) ListFleetWorkspaces(_ context.Context, box string) ([]FleetWorkspace, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []FleetWorkspace{}
	for id, t := range s.tenants {
		if id == SystemTenant || !s.fleetSeating[id] || !t.SuspendedAt.IsZero() || !t.ArchivedAt.IsZero() {
			continue
		}
		p, ok := s.pins[[2]string{id, box}]
		out = append(out, FleetWorkspace{Tenant: id, Pinned: ok && !p.revoked})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Tenant < out[j].Tenant })
	return out, nil
}

// ---- Postgres ---------------------------------------------------------------

// EnrolFleetPin is FleetEnrol on Postgres: the pin row is read FOR UPDATE and
// written in the workspace's own scope, the key claimed on its advisory lock.
func (s *Postgres) EnrolFleetPin(ctx context.Context, p FleetEnrolPin) (bool, error) {
	defer s.hot.forget()
	p.OpTS = p.OpTS.Truncate(time.Microsecond) // timestamptz precision: compare like Postgres stores
	created := false
	err := s.inTenant(ctx, p.Tenant, func(tx pgx.Tx) error {
		var old []byte
		var revoked, lastOp *time.Time
		err := tx.QueryRow(ctx, `SELECT pubkey, revoked_at, last_op_ts FROM pins
			WHERE tenant_id = $1 AND box_id = $2 FOR UPDATE`, p.Tenant, p.Box).Scan(&old, &revoked, &lastOp)
		had := err == nil
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		same, err := fleetPinGate(p, had, old, revoked, lastOp)
		switch {
		case err != nil:
			return err
		case same:
			_, err = tx.Exec(ctx, `UPDATE pins SET last_op_ts = $3 WHERE tenant_id = $1 AND box_id = $2`,
				p.Tenant, p.Box, p.OpTS)
			return err
		}
		if err := s.claimKey(ctx, tx, p.Tenant, p.Box, p.PubKey); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO pins (tenant_id, box_id, pubkey, updated_at, revoked_at, last_op_ts, box_mode)
			VALUES ($1, $2, $3, $4, NULL, $5, $6)
			ON CONFLICT (tenant_id, box_id) DO UPDATE SET pubkey = EXCLUDED.pubkey, updated_at = EXCLUDED.updated_at,
				revoked_at = NULL, last_op_ts = EXCLUDED.last_op_ts, box_mode = EXCLUDED.box_mode`,
			p.Tenant, p.Box, []byte(p.PubKey), p.Now, p.OpTS, BoxModeFleet); err != nil {
			return mapPinErr(err)
		}
		created = true
		_, err = tx.Exec(ctx, `INSERT INTO pins_history (tenant_id, box_id, pubkey, at, reason)
			VALUES ($1, $2, $3, $4, $5)`, p.Tenant, p.Box, []byte(p.PubKey), p.Now, BoxModeFleet)
		return err
	})
	return created, err
}

// ListFleetWorkspaces is FleetEnrol on Postgres. It reads every workspace's
// row, so it runs in the operator scope; only a listed fleet desk box that
// proved its operator-workspace key reaches it (GET /v1/fleet/workspaces).
func (s *Postgres) ListFleetWorkspaces(ctx context.Context, box string) ([]FleetWorkspace, error) {
	out := []FleetWorkspace{}
	err := s.asOperatorQuery(ctx, `SELECT t.tenant_id, EXISTS (SELECT 1 FROM pins p
			WHERE p.tenant_id = t.tenant_id AND p.box_id = $2 AND p.revoked_at IS NULL)
		FROM tenants t
		WHERE t.fleet_seating AND t.suspended_at IS NULL AND t.archived_at IS NULL AND t.tenant_id <> $1
		ORDER BY t.tenant_id`, []any{SystemTenant, box}, func(rows pgx.Rows) error {
		var w FleetWorkspace
		err := rows.Scan(&w.Tenant, &w.Pinned)
		out = append(out, w)
		return err
	})
	return out, err
}
