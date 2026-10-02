package store

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// Set reads (perf round 4 G2, kill N+1 query loops): what a route used to
// read once per item, read for the whole set in one round trip. A hub caller
// asks for SetReads with a type assertion and keeps its per-item loop for a
// store without it, so a wrapper or fake store still answers the same.

// ChannelSetting is one channel's admin-list facts: its human members (a
// default channel has none: it carries no rows) and its fallback opt-out.
type ChannelSetting struct {
	Humans     int
	NoFallback bool
}

// SetReads is implemented by Memory and Postgres.
type SetReads interface {
	// ChannelSettings returns ChannelSetting for each of channels, every one
	// in tenant's scope; a channel with no row reads the zero value, as
	// ChannelHumanMembers and ChannelNoFallback read it one at a time.
	ChannelSettings(ctx context.Context, tenantID string, channels []string) (map[string]ChannelSetting, error)
	// LocateTopicOrMessage is the first of tenants (in order) for which
	// HasTopicOrMessage(tenant, id) holds, "" when none does. Each tenant is
	// probed in its own scope, never under the operator scope.
	LocateTopicOrMessage(ctx context.Context, tenants []string, id string) (string, error)
}

var (
	_ SetReads = (*Memory)(nil)
	_ SetReads = (*Postgres)(nil)
)

// ---- Memory ---------------------------------------------------------------

func (s *Memory) ChannelSettings(ctx context.Context, tenant string, channels []string) (map[string]ChannelSetting, error) {
	out := make(map[string]ChannelSetting, len(channels))
	for _, ch := range channels {
		ms, err := s.ChannelHumanMembers(ctx, tenant, ch)
		if err != nil {
			return nil, err
		}
		off, err := s.ChannelNoFallback(ctx, tenant, ch)
		if err != nil {
			return nil, err
		}
		out[ch] = ChannelSetting{Humans: len(ms), NoFallback: off}
	}
	return out, nil
}

func (s *Memory) LocateTopicOrMessage(ctx context.Context, tenants []string, id string) (string, error) {
	for _, t := range tenants {
		if err := checkTenant(t); err != nil {
			return "", err
		}
		ok, err := s.HasTopicOrMessage(ctx, t, id)
		if err != nil {
			return "", err
		}
		if ok {
			return t, nil
		}
	}
	return "", nil
}

// ---- Postgres -------------------------------------------------------------

// ChannelSettings: the opt-outs and the live member counts as two reads of
// ONE tenant batch, where the per-channel loop paid two round trips a channel.
func (s *Postgres) ChannelSettings(ctx context.Context, tenant string, channels []string) (map[string]ChannelSetting, error) {
	out := make(map[string]ChannelSetting, len(channels))
	ids := make([]string, 0, len(channels))
	for _, ch := range channels {
		id := NormalizeChannel(ch)
		ids = append(ids, id)
		out[id] = ChannelSetting{}
	}
	if len(ids) == 0 {
		return out, nil
	}
	err := s.queryTenantBatch(ctx, tenant,
		tenantRead{`SELECT channel_id, no_fallback FROM channels WHERE tenant_id = $1 AND channel_id = ANY($2)`,
			[]any{tenant, ids}, func(r pgx.Rows) error {
				var id string
				var off bool
				if err := r.Scan(&id, &off); err != nil {
					return err
				}
				c := out[id]
				c.NoFallback = off
				out[id] = c
				return nil
			}},
		tenantRead{`SELECT channel_id, count(*)::int FROM channel_humans
			WHERE tenant_id = $1 AND channel_id = ANY($2) AND ` + notArchived("channel_humans.channel_id") + ` GROUP BY channel_id`,
			[]any{tenant, ids}, func(r pgx.Rows) error {
				var id string
				var n int
				if err := r.Scan(&id, &n); err != nil {
					return err
				}
				c := out[id]
				c.Humans = n
				out[id] = c
				return nil
			}})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// LocateTopicOrMessage: every tenant's scope and probe in ONE batch, one round
// trip whatever the tenant count. The batch is one implicit transaction and
// set_config(..., true) is transaction-local, so each probe runs under the
// scope queued just before it, and the last scope ends with the batch.
func (s *Postgres) LocateTopicOrMessage(ctx context.Context, tenants []string, id string) (string, error) {
	if len(tenants) == 0 {
		return "", nil
	}
	b := &pgx.Batch{}
	for _, t := range tenants {
		if err := checkTenant(t); err != nil {
			return "", err
		}
		b.Queue(pgScopeTenant, t)
		b.Queue(`SELECT EXISTS(SELECT 1 FROM messages WHERE tenant_id = $1 AND task_id = $2)
			OR EXISTS(SELECT 1 FROM messages WHERE tenant_id = $1 AND msg_id = $2)`, t, id)
	}
	br := s.pool.SendBatch(ctx, b)
	found := ""
	var err error
	for i := 0; err == nil && i < len(tenants); i++ {
		var ok bool
		if _, err = br.Exec(); err == nil {
			err = br.QueryRow().Scan(&ok)
		}
		if err == nil && ok && found == "" {
			found = tenants[i]
		}
	}
	if cerr := br.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return "", err
	}
	return found, nil
}
