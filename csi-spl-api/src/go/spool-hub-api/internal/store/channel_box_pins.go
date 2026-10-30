package store

import (
	"context"
	"errors"
	"fmt"
	"slices"

	"github.com/jackc/pgx/v5"
)

// Channel-level box pins (spec 164 section 3, rdb 0246, SPL-4438): the boxes
// a channel is pinned to. No row = unpinned = any pinned box of the
// workspace. The hub's checks (unknown or revoked box, default channel,
// TenantSettings) are spec 164 4.1, built in B2; the store keeps only what
// the table enforces: the channel exists and the workspace has a pins row
// for each box (a revoked one included).

// ChannelBoxPins is implemented by Memory and Postgres.
type ChannelBoxPins interface {
	// GetChannelBoxPins returns the boxes channel is pinned to, sorted; nil
	// = unpinned. A caller reads an error as "pinned to nobody", never as
	// unpinned (spec 164 3.3, fail closed).
	GetChannelBoxPins(ctx context.Context, tenant, channel string) ([]string, error)
	// SetChannelBoxPins replaces channel's pins with boxes, written by by
	// (HUM-<n> or "operator"); an empty boxes clears the pin. ErrNotFound:
	// the channel or one of the boxes has no row. Nothing is written then.
	SetChannelBoxPins(ctx context.Context, tenant, channel string, boxes []string, by string) error
	// ListChannelBoxPins returns channel -> sorted boxes for every pinned
	// channel of tenant; an unpinned channel has no key.
	ListChannelBoxPins(ctx context.Context, tenant string) (map[string][]string, error)
}

var (
	_ ChannelBoxPins = (*Memory)(nil)
	_ ChannelBoxPins = (*Postgres)(nil)
)

// errChannelBoxPinsBy refuses a pin with no pinned_by (the column is NOT NULL).
var errChannelBoxPinsBy = errors.New("store: channel box pins without pinned_by")

// channelBoxPinsArgs normalizes a SetChannelBoxPins call: the channel alias,
// the boxes sorted and deduplicated. An empty box id or an empty by on a
// non-empty set is refused before the database sees it.
func channelBoxPinsArgs(channel string, boxes []string, by string) (string, []string, error) {
	out := slices.Clone(boxes)
	slices.Sort(out)
	out = slices.Compact(out)
	if len(out) > 0 && out[0] == "" {
		return "", nil, fmt.Errorf("%w: empty box id", ErrNotFound)
	}
	if len(out) > 0 && by == "" {
		return "", nil, errChannelBoxPinsBy
	}
	return NormalizeChannel(channel), out, nil
}

// GetChannelBoxPins reads one channel's pins (ChannelBoxPins).
func (s *Memory) GetChannelBoxPins(_ context.Context, tenant, channel string) ([]string, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.chBoxPins[[2]string{tenant, NormalizeChannel(channel)}]), nil
}

// SetChannelBoxPins replaces one channel's pins (ChannelBoxPins).
func (s *Memory) SetChannelBoxPins(_ context.Context, tenant, channel string, boxes []string, by string) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	channel, boxes, err := channelBoxPinsArgs(channel, boxes, by)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	k := [2]string{tenant, channel}
	if _, ok := s.ch.rows[k]; !ok && !s.ch.archivedCh(tenant, channel) {
		return fmt.Errorf("%w: channel %s", ErrNotFound, channel)
	}
	for _, b := range boxes {
		if _, ok := s.pins[[2]string{tenant, b}]; !ok { // a revoked pin keeps its row, as in pins
			return fmt.Errorf("%w: box %s", ErrNotFound, b)
		}
	}
	if s.chBoxPins == nil {
		s.chBoxPins = map[[2]string][]string{}
	}
	if len(boxes) == 0 {
		delete(s.chBoxPins, k)
		return nil
	}
	s.chBoxPins[k] = boxes
	return nil
}

// ListChannelBoxPins reads every pinned channel of tenant (ChannelBoxPins).
func (s *Memory) ListChannelBoxPins(_ context.Context, tenant string) (map[string][]string, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string][]string{}
	for k, boxes := range s.chBoxPins {
		if k[0] == tenant {
			out[k[1]] = slices.Clone(boxes)
		}
	}
	return out, nil
}

// GetChannelBoxPins reads one channel's pins (ChannelBoxPins).
func (s *Postgres) GetChannelBoxPins(ctx context.Context, tenant, channel string) ([]string, error) {
	var out []string
	err := s.queryTenant(ctx, tenant, `SELECT box_id FROM channel_box_pins
		WHERE tenant_id = $1 AND channel_id = $2 ORDER BY box_id`, []any{tenant, NormalizeChannel(channel)},
		func(r pgx.Rows) error {
			var b string
			if err := r.Scan(&b); err != nil {
				return err
			}
			out = append(out, b)
			return nil
		})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// SetChannelBoxPins replaces one channel's pins in one transaction
// (ChannelBoxPins): a missing channel or box (23503) is ErrNotFound and
// rolls the delete back with it.
func (s *Postgres) SetChannelBoxPins(ctx context.Context, tenant, channel string, boxes []string, by string) error {
	channel, boxes, err := channelBoxPinsArgs(channel, boxes, by)
	if err != nil {
		return err
	}
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM channel_box_pins WHERE tenant_id = $1 AND channel_id = $2`, tenant, channel); err != nil {
			return err
		}
		if len(boxes) > 0 {
			_, err := tx.Exec(ctx, `INSERT INTO channel_box_pins (tenant_id, channel_id, box_id, pinned_by)
				SELECT $1, $2, b, $4 FROM unnest($3::text[]) AS b`, tenant, channel, boxes, by)
			return err
		}
		// Clearing an unknown channel is refused as setting one is: the
		// DELETE alone cannot tell a missing channel from an unpinned one.
		var ok bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM channels WHERE tenant_id = $1 AND channel_id = $2)`,
			tenant, channel).Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("%w: channel %s", ErrNotFound, channel)
		}
		return nil
	})
	if sqlState(err) == "23503" {
		return fmt.Errorf("%w: %v", ErrNotFound, err)
	}
	return err
}

// ListChannelBoxPins reads every pinned channel of tenant (ChannelBoxPins).
func (s *Postgres) ListChannelBoxPins(ctx context.Context, tenant string) (map[string][]string, error) {
	out := map[string][]string{}
	err := s.queryTenant(ctx, tenant, `SELECT channel_id, box_id FROM channel_box_pins
		WHERE tenant_id = $1 ORDER BY channel_id, box_id`, []any{tenant}, func(r pgx.Rows) error {
		var c, b string
		if err := r.Scan(&c, &b); err != nil {
			return err
		}
		out[c] = append(out[c], b)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}
