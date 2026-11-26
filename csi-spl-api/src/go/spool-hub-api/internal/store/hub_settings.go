package store

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
)

// Instance settings (spec 187 5.1, row S1, rdb 0331 hub_settings): one JSON
// value per key, with who set it and when. The table has no tenant column
// and only an operator policy, so Postgres reads and writes it in the
// operator scope; only the instance routes and the scheduled-task runner
// call it (rows S3, S6).

// hubSettingKeyRe is rdb 0331's key CHECK.
var hubSettingKeyRe = regexp.MustCompile(`^[a-z][a-z0-9_.]{0,63}$`)

// ErrBadHubSetting: a key outside hubSettingKeyRe, a value that is not one
// JSON value, or a set_by not 1..64 characters. Before any write.
var ErrBadHubSetting = errors.New("store: a hub setting needs a key [a-z][a-z0-9_.]{0,63}, one JSON value and who (1..64)")

// memHubSettings is one Memory store's hub_settings, key -> value.
var memHubSettings = map[*Memory]map[string]json.RawMessage{}

// checkHubSetting validates a write; the value is answered compacted, as
// jsonb would store it.
func checkHubSetting(key string, v json.RawMessage, by string) (json.RawMessage, error) {
	if !hubSettingKeyRe.MatchString(key) || !runeLen(by, taskIDLen) || !json.Valid(v) {
		return nil, ErrBadHubSetting
	}
	var x any
	if err := json.Unmarshal(v, &x); err != nil {
		return nil, ErrBadHubSetting
	}
	out, err := json.Marshal(x)
	return out, err
}

// HubSetting implements ScheduledTaskStore: false when key was never set.
func (s *Memory) HubSetting(_ context.Context, key string) (json.RawMessage, bool, error) {
	if !hubSettingKeyRe.MatchString(key) {
		return nil, false, ErrBadHubSetting
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := memHubSettings[s][key]
	return append(json.RawMessage(nil), v...), ok, nil
}

// SetHubSetting implements ScheduledTaskStore.
func (s *Memory) SetHubSetting(_ context.Context, key string, v json.RawMessage, by string, _ time.Time) error {
	val, err := checkHubSetting(key, v, by)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if memHubSettings[s] == nil {
		memHubSettings[s] = map[string]json.RawMessage{}
	}
	memHubSettings[s][key] = val
	return nil
}

// HubSetting implements ScheduledTaskStore: one primary-key read.
func (s *Postgres) HubSetting(ctx context.Context, key string) (json.RawMessage, bool, error) {
	if !hubSettingKeyRe.MatchString(key) {
		return nil, false, ErrBadHubSetting
	}
	var v json.RawMessage
	err := s.asOperatorQuery(ctx, `SELECT value FROM hub_settings WHERE key = $1`, []any{key},
		func(r pgx.Rows) error { return r.Scan(&v) })
	if err != nil {
		return nil, false, err
	}
	return v, v != nil, nil
}

// SetHubSetting implements ScheduledTaskStore: an upsert of the key.
func (s *Postgres) SetHubSetting(ctx context.Context, key string, v json.RawMessage, by string, at time.Time) error {
	val, err := checkHubSetting(key, v, by)
	if err != nil {
		return err
	}
	return s.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO hub_settings (key, value, set_by, set_at) VALUES ($1, $2, $3, $4)
			ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_by = EXCLUDED.set_by, set_at = EXCLUDED.set_at`,
			key, string(val), by, followAt(at))
		return err
	})
}
