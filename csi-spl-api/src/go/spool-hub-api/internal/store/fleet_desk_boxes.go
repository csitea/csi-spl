package store

import (
	"context"
	"errors"
	"regexp"
	"sort"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

// The fleet desk boxes (spec 158 section 4.2 item 2, rdb 0230, build row T6):
// the desk boxes of the operator workspace that may self-enrol a key into
// every workspace marked for fleet seating (POST /v1/fleet/enrol, row T7).
// The operator manages them through PUT/DELETE /v1/operator/fleet-desks/{box}
// and the twin action do_spl_fleet_desk_box. The rows are the instance's,
// no tenant_id: operator scope only, like the fleet token rows. Whether a box
// holds a live pin in the operator workspace is the route's check: the
// operator workspace id is cnf, not a constant of the table.

// FleetDeskBoxRx is rdb 0230's box_id CHECK.
var FleetDeskBoxRx = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)

// FleetDeskAddedByMax is rdb 0230's added_by length CHECK.
const FleetDeskAddedByMax = 64

// FleetDeskBox is one row of fleet_desk_boxes.
type FleetDeskBox struct {
	BoxID   string    `json:"box_id"`
	AddedBy string    `json:"added_by"`
	AddedAt time.Time `json:"added_at"`
}

// FleetDeskBoxes is implemented by Memory and Postgres.
type FleetDeskBoxes interface {
	// ListFleetDeskBoxes answers every listed box, by box id.
	ListFleetDeskBoxes(ctx context.Context) ([]FleetDeskBox, error)
	// PutFleetDeskBox lists box (added_by = by); a box already listed is kept
	// as it was and answered with created false.
	PutFleetDeskBox(ctx context.Context, box, by string) (FleetDeskBox, bool, error)
	// DeleteFleetDeskBox unlists box; ErrNotFound when it is not listed.
	DeleteFleetDeskBox(ctx context.Context, box string) error
}

var (
	_ FleetDeskBoxes = (*Memory)(nil)
	_ FleetDeskBoxes = (*Postgres)(nil)
)

// ErrFleetDeskBox is a row rdb 0230's CHECKs would refuse.
var ErrFleetDeskBox = errors.New("fleet desk box: box_id must match ^[a-z0-9][a-z0-9-]{0,31}$ and added_by be 1..64 characters")

func checkFleetDeskBox(box, by string) error {
	if !FleetDeskBoxRx.MatchString(box) || by == "" || len(by) > FleetDeskAddedByMax {
		return ErrFleetDeskBox
	}
	return nil
}

// ---- Memory -----------------------------------------------------------------

// The Memory driver keeps its rows beside the store, like the paid items.
var (
	memFleetDeskMu sync.Mutex
	memFleetDesk   = map[*Memory]map[string]FleetDeskBox{}
)

// ListFleetDeskBoxes is FleetDeskBoxes on Memory.
func (s *Memory) ListFleetDeskBoxes(_ context.Context) ([]FleetDeskBox, error) {
	memFleetDeskMu.Lock()
	defer memFleetDeskMu.Unlock()
	out := []FleetDeskBox{}
	for _, b := range memFleetDesk[s] {
		out = append(out, b)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].BoxID < out[j].BoxID })
	return out, nil
}

// PutFleetDeskBox is FleetDeskBoxes on Memory.
func (s *Memory) PutFleetDeskBox(_ context.Context, box, by string) (FleetDeskBox, bool, error) {
	if err := checkFleetDeskBox(box, by); err != nil {
		return FleetDeskBox{}, false, err
	}
	memFleetDeskMu.Lock()
	defer memFleetDeskMu.Unlock()
	rows := memFleetDesk[s]
	if rows == nil {
		rows = map[string]FleetDeskBox{}
		memFleetDesk[s] = rows
	}
	if b, ok := rows[box]; ok {
		return b, false, nil
	}
	b := FleetDeskBox{BoxID: box, AddedBy: by, AddedAt: time.Now().UTC()}
	rows[box] = b
	return b, true, nil
}

// DeleteFleetDeskBox is FleetDeskBoxes on Memory.
func (s *Memory) DeleteFleetDeskBox(_ context.Context, box string) error {
	memFleetDeskMu.Lock()
	defer memFleetDeskMu.Unlock()
	if _, ok := memFleetDesk[s][box]; !ok {
		return ErrNotFound
	}
	delete(memFleetDesk[s], box)
	return nil
}

// ---- Postgres ---------------------------------------------------------------

const fleetDeskCols = `box_id, added_by, added_at`

func scanFleetDesk(row pgx.Row) (FleetDeskBox, error) {
	var b FleetDeskBox
	err := row.Scan(&b.BoxID, &b.AddedBy, &b.AddedAt)
	b.AddedAt = b.AddedAt.UTC()
	return b, err
}

// ListFleetDeskBoxes is FleetDeskBoxes on Postgres.
func (s *Postgres) ListFleetDeskBoxes(ctx context.Context) ([]FleetDeskBox, error) {
	out := []FleetDeskBox{}
	err := s.asOperatorQuery(ctx, `SELECT `+fleetDeskCols+` FROM fleet_desk_boxes ORDER BY box_id`, nil,
		func(rows pgx.Rows) error {
			b, err := scanFleetDesk(rows)
			out = append(out, b)
			return err
		})
	return out, err
}

// PutFleetDeskBox is FleetDeskBoxes on Postgres: the insert and, for a box
// already listed, the read of its row go in one transaction.
func (s *Postgres) PutFleetDeskBox(ctx context.Context, box, by string) (FleetDeskBox, bool, error) {
	if err := checkFleetDeskBox(box, by); err != nil {
		return FleetDeskBox{}, false, err
	}
	var out FleetDeskBox
	created := true
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = scanFleetDesk(tx.QueryRow(ctx, `INSERT INTO fleet_desk_boxes (box_id, added_by) VALUES ($1, $2)
			ON CONFLICT (box_id) DO NOTHING RETURNING `+fleetDeskCols, box, by))
		if errors.Is(err, pgx.ErrNoRows) {
			created = false
			out, err = scanFleetDesk(tx.QueryRow(ctx, `SELECT `+fleetDeskCols+` FROM fleet_desk_boxes WHERE box_id = $1`, box))
		}
		return err
	})
	return out, created, err
}

// DeleteFleetDeskBox is FleetDeskBoxes on Postgres.
func (s *Postgres) DeleteFleetDeskBox(ctx context.Context, box string) error {
	var n int64
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM fleet_desk_boxes WHERE box_id = $1`, box)
		n = tag.RowsAffected()
		return err
	})
	if err == nil && n == 0 {
		return ErrNotFound
	}
	return err
}
