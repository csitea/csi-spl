package store

import (
	"context"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// MarketingXDispatch is what the X dispatcher (spec 090 X row, SPL-5194)
// reads beyond Marketing and MarketingMetaDispatch; rdb 0272 only widens the
// platform CHECK. An X channel is never auto_publish, so neither the
// LinkedIn sweep nor the Meta dispatch lists one.
type MarketingXDispatch interface {
	// XMarketingChannels lists every active X channel, all tenants (the
	// dispatch sweep; operator scope).
	XMarketingChannels(ctx context.Context) ([]MarketingChannel, error)
	// SwapMarketingToken replaces the channel's sealed token with next only
	// while it still is old: false when another hub refreshed it first (X
	// rotates the refresh token, so only one refresh may win).
	SwapMarketingToken(ctx context.Context, tenant, channelID string, old, next MarketingToken, now time.Time) (bool, error)
}

// XMarketingChannels implements MarketingXDispatch on the Postgres store.
func (s *Postgres) XMarketingChannels(ctx context.Context) ([]MarketingChannel, error) {
	out := []MarketingChannel{}
	err := s.asOperatorQuery(ctx, `SELECT `+mktChannelCols+` FROM marketing_channels
		WHERE status = 'active' AND platform = 'x' ORDER BY tenant_id, created_at`, nil,
		func(r pgx.Rows) error {
			c, err := scanMktChannel(r)
			out = append(out, c)
			return err
		})
	return out, err
}

// SwapMarketingToken implements MarketingXDispatch on the Postgres store:
// one guarded UPDATE.
func (s *Postgres) SwapMarketingToken(ctx context.Context, tenant, channelID string, old, next MarketingToken, now time.Time) (bool, error) {
	won := false
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE marketing_channel_tokens SET ciphertext = $4, kms_key_id = $5, updated_at = $6
			WHERE tenant_id = $1 AND channel_id = $2::uuid AND ciphertext = $3`,
			tenant, channelID, old.Ciphertext, next.Ciphertext, next.KMSKeyID, now)
		won = err == nil && tag.RowsAffected() == 1
		return err
	})
	return won, err
}

// XMarketingChannels implements MarketingXDispatch on the Memory store.
func (s *Memory) XMarketingChannels(_ context.Context) ([]MarketingChannel, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []MarketingChannel{}
	for _, c := range s.mkt().channels {
		if c.Status == MarketingActive && c.Platform == MarketingPlatformX {
			out = append(out, *c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

// SwapMarketingToken implements MarketingXDispatch on the Memory store.
func (s *Memory) SwapMarketingToken(_ context.Context, tenant, channelID string, old, next MarketingToken, _ time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.mkt()
	c, ok := m.channels[channelID]
	if !ok || c.Tenant != tenant || m.tokens[channelID] != old {
		return false, nil
	}
	m.tokens[channelID] = next
	return true, nil
}
