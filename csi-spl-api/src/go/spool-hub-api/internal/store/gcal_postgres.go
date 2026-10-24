package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// The Postgres Gcal (rdb 0217, spec 149 B2). Member methods run in the
// tenant's scope and name (tenant_id, human_id) in every WHERE; the two
// cross-workspace reads run under the operator scope (operatorCallers).

const gcalCols = `connection_id::text, tenant_id, human_id, google_email, calendar_id, status, status_detail,
	kms_key_id, access_expiry, coalesce(sync_token, ''), out_cursor, due_at, sync_lease_until,
	coalesce(watch_channel_id::text, ''), coalesce(watch_resource_id, ''), watch_expiry, last_synced_at,
	created_at, updated_at`

func scanGcal(r pgx.Row) (GcalConnection, error) {
	var c GcalConnection
	err := r.Scan(&c.ID, &c.Tenant, &c.Human, &c.GoogleEmail, &c.CalendarID, &c.Status, &c.StatusDetail,
		&c.KMSKeyID, &c.AccessExpiry, &c.SyncToken, &c.OutCursor, &c.DueAt, &c.SyncLeaseUntil,
		&c.WatchChannelID, &c.WatchResourceID, &c.WatchExpiry, &c.LastSyncedAt, &c.CreatedAt, &c.UpdatedAt)
	return c, err
}

func gcalNoRows(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	return err
}

// ConnectGcal implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) ConnectGcal(ctx context.Context, c GcalConnection, tok GcalTokens, now time.Time) (GcalConnection, error) {
	if !gcalConnectOK(c, tok) {
		return GcalConnection{}, ErrInvalidGcal
	}
	var out GcalConnection
	err := s.inTenant(ctx, c.Tenant, func(tx pgx.Tx) error {
		// another Google account: its map rows name another calendar
		if _, err := tx.Exec(ctx, `DELETE FROM gcal_event_map m USING gcal_connections c
			WHERE m.connection_id = c.connection_id AND c.tenant_id = $1 AND c.human_id = $2 AND c.google_email <> $3`,
			c.Tenant, c.Human, c.GoogleEmail); err != nil {
			return err
		}
		var err error
		out, err = scanGcal(tx.QueryRow(ctx, `INSERT INTO gcal_connections AS g (tenant_id, human_id, google_email,
				access_sealed, refresh_sealed, kms_key_id, access_expiry, due_at, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8, $8)
			ON CONFLICT (tenant_id, human_id) DO UPDATE SET
				calendar_id = CASE WHEN g.google_email = EXCLUDED.google_email THEN g.calendar_id ELSE '' END,
				sync_token = CASE WHEN g.google_email = EXCLUDED.google_email THEN g.sync_token END,
				out_cursor = CASE WHEN g.google_email = EXCLUDED.google_email THEN g.out_cursor END,
				watch_channel_id = CASE WHEN g.google_email = EXCLUDED.google_email THEN g.watch_channel_id END,
				watch_resource_id = CASE WHEN g.google_email = EXCLUDED.google_email THEN g.watch_resource_id END,
				watch_expiry = CASE WHEN g.google_email = EXCLUDED.google_email THEN g.watch_expiry END,
				google_email = EXCLUDED.google_email, status = 'connected', status_detail = '',
				access_sealed = EXCLUDED.access_sealed, refresh_sealed = EXCLUDED.refresh_sealed,
				kms_key_id = EXCLUDED.kms_key_id, access_expiry = EXCLUDED.access_expiry,
				due_at = EXCLUDED.due_at, sync_lease_until = NULL, updated_at = EXCLUDED.updated_at
			RETURNING `+gcalCols,
			c.Tenant, c.Human, c.GoogleEmail, tok.AccessSealed, tok.RefreshSealed, tok.KMSKeyID, tok.AccessExpiry, now))
		return err
	})
	return out, err
}

// GcalConnection implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) GcalConnection(ctx context.Context, tenant, human string) (GcalConnection, error) {
	var out GcalConnection
	err := s.queryTenant(ctx, tenant, `SELECT `+gcalCols+` FROM gcal_connections WHERE tenant_id = $1 AND human_id = $2`,
		[]any{tenant, human}, func(r pgx.Rows) error {
			var err error
			out, err = scanGcal(r)
			return err
		})
	if err == nil && out.ID == "" {
		err = ErrNotFound
	}
	return out, err
}

// GcalTokens implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) GcalTokens(ctx context.Context, tenant, human string) (GcalTokens, error) {
	var t GcalTokens
	err := s.queryRowTenant(ctx, tenant, `SELECT access_sealed, refresh_sealed, kms_key_id, access_expiry
		FROM gcal_connections WHERE tenant_id = $1 AND human_id = $2`, []any{tenant, human},
		&t.AccessSealed, &t.RefreshSealed, &t.KMSKeyID, &t.AccessExpiry)
	return t, gcalNoRows(err)
}

// DeleteGcalConnection implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) DeleteGcalConnection(ctx context.Context, tenant, human string) (GcalConnection, error) {
	var out GcalConnection
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		out, err = scanGcal(tx.QueryRow(ctx, `DELETE FROM gcal_connections WHERE tenant_id = $1 AND human_id = $2
			RETURNING `+gcalCols, tenant, human))
		return gcalNoRows(err)
	})
	return out, err
}

// MarkGcalDue implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) MarkGcalDue(ctx context.Context, tenant, human string, now time.Time) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE gcal_connections SET due_at = $3, updated_at = $3
			WHERE tenant_id = $1 AND human_id = $2`, tenant, human, now)
		if err == nil && tag.RowsAffected() == 0 {
			err = ErrNotFound
		}
		return err
	})
}

// GcalEventMaps implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) GcalEventMaps(ctx context.Context, tenant, human string) ([]GcalEventMap, error) {
	out := []GcalEventMap{}
	err := s.queryTenant(ctx, tenant, `SELECT m.event_id::text, m.google_id, m.etag, m.sync_hash, m.synced_at
		FROM gcal_event_map m JOIN gcal_connections c ON c.connection_id = m.connection_id
		WHERE c.tenant_id = $1 AND c.human_id = $2 AND m.tenant_id = $1 ORDER BY m.event_id`,
		[]any{tenant, human}, func(r pgx.Rows) error {
			var m GcalEventMap
			err := r.Scan(&m.EventID, &m.GoogleID, &m.ETag, &m.SyncHash, &m.SyncedAt)
			out = append(out, m)
			return err
		})
	return out, err
}

// ClaimGcalConnection implements Gcal on the Postgres store (rdb 0217): the
// spec 149 2.5 statement, one short UPDATE, SKIP LOCKED.
func (s *Postgres) ClaimGcalConnection(ctx context.Context, now time.Time, lease time.Duration) (GcalConnection, GcalLease, error) {
	until := gcalLeaseUntil(now, lease)
	var out GcalConnection
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = scanGcal(tx.QueryRow(ctx, `UPDATE gcal_connections SET sync_lease_until = $2
			WHERE connection_id = (SELECT connection_id FROM gcal_connections WHERE due_at <= $1
				AND status = 'connected' AND (sync_lease_until IS NULL OR sync_lease_until < $1)
				ORDER BY due_at FOR UPDATE SKIP LOCKED LIMIT 1)
			RETURNING `+gcalCols, now, until))
		return gcalNoRows(err)
	})
	if err != nil {
		return GcalConnection{}, GcalLease{}, err
	}
	return out, GcalLease{Tenant: out.Tenant, Human: out.Human, ConnectionID: out.ID, Until: *out.SyncLeaseUntil}, nil
}

// GcalConnectionByWatch implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) GcalConnectionByWatch(ctx context.Context, watchChannelID string) (GcalConnection, error) {
	if !calendarIDRe.MatchString(watchChannelID) {
		return GcalConnection{}, ErrNotFound
	}
	var out GcalConnection
	err := s.asOperatorQuery(ctx, `SELECT `+gcalCols+` FROM gcal_connections WHERE watch_channel_id = $1::uuid`,
		[]any{watchChannelID}, func(r pgx.Rows) error {
			var err error
			out, err = scanGcal(r)
			return err
		})
	if err == nil && out.ID == "" {
		err = ErrNotFound
	}
	return out, err
}

// gcalFenced runs fn in the lease's tenant scope once the connection is
// locked and still holds the lease l; ErrGcalLeaseLost when it does not.
// The row lock lasts only this short transaction, never a Google call.
func (s *Postgres) gcalFenced(ctx context.Context, l GcalLease, fn func(pgx.Tx) error) error {
	return s.inTenant(ctx, l.Tenant, func(tx pgx.Tx) error {
		var one int
		err := tx.QueryRow(ctx, `SELECT 1 FROM gcal_connections WHERE tenant_id = $1 AND human_id = $2
			AND connection_id = $3::uuid AND sync_lease_until = $4 FOR UPDATE`,
			l.Tenant, l.Human, l.ConnectionID, l.Until).Scan(&one)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrGcalLeaseLost
		}
		if err != nil {
			return err
		}
		return fn(tx)
	})
}

// gcalFencedSet is one fenced UPDATE of the connection: set holds the SET
// list with its own arguments from $3 on ($1 tenant, $2 connection).
func (s *Postgres) gcalFencedSet(ctx context.Context, l GcalLease, set string, args ...any) error {
	if !calendarIDRe.MatchString(l.ConnectionID) {
		return ErrGcalLeaseLost
	}
	return s.gcalFenced(ctx, l, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE gcal_connections SET `+set+` WHERE tenant_id = $1 AND connection_id = $2::uuid`,
			append([]any{l.Tenant, l.ConnectionID}, args...)...)
		return err
	})
}

// RenewGcalLease implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) RenewGcalLease(ctx context.Context, l GcalLease, now time.Time, lease time.Duration) (GcalLease, error) {
	next := l
	next.Until = gcalLeaseUntil(now, lease)
	return next, s.gcalFencedSet(ctx, l, `sync_lease_until = $3`, next.Until)
}

// SetGcalTokens implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) SetGcalTokens(ctx context.Context, l GcalLease, tok GcalTokens, now time.Time) error {
	if !gcalTokensOK(tok) {
		return ErrInvalidGcal
	}
	return s.gcalFencedSet(ctx, l, `access_sealed = $3, refresh_sealed = $4, kms_key_id = $5, access_expiry = $6, updated_at = $7`,
		tok.AccessSealed, tok.RefreshSealed, tok.KMSKeyID, tok.AccessExpiry, now)
}

// SetGcalCalendar implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) SetGcalCalendar(ctx context.Context, l GcalLease, calendarID string, now time.Time) error {
	if len(calendarID) > 255 {
		return ErrInvalidGcal
	}
	return s.gcalFencedSet(ctx, l, `calendar_id = $3, updated_at = $4`, calendarID, now)
}

// SetGcalStatus implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) SetGcalStatus(ctx context.Context, l GcalLease, status, detail string, now time.Time) error {
	if !gcalStatusOK(status, detail) {
		return ErrInvalidGcal
	}
	return s.gcalFencedSet(ctx, l, `status = $3, status_detail = $4, updated_at = $5`, status, detail, now)
}

// SetGcalWatch implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) SetGcalWatch(ctx context.Context, l GcalLease, w GcalWatch, now time.Time) error {
	var ch, res any
	if w.ChannelID != "" {
		if !calendarIDRe.MatchString(w.ChannelID) {
			return ErrInvalidGcal
		}
		ch, res = w.ChannelID, w.ResourceID
	}
	err := s.gcalFencedSet(ctx, l, `watch_channel_id = $3::uuid, watch_resource_id = $4, watch_expiry = $5, updated_at = $6`,
		ch, res, w.Expiry, now)
	if isUniqueViolation(err) { // rdb 0217 gcal_connections_watch
		return ErrConflict
	}
	return err
}

// PutGcalEventMap implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) PutGcalEventMap(ctx context.Context, l GcalLease, m GcalEventMap, now time.Time) error {
	if !gcalMapOK(m) {
		return ErrInvalidGcal
	}
	err := s.gcalFenced(ctx, l, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO gcal_event_map (connection_id, tenant_id, event_id, google_id, etag, sync_hash, synced_at)
			VALUES ($1::uuid, $2, $3::uuid, $4, $5, $6, $7)
			ON CONFLICT (connection_id, event_id) DO UPDATE SET google_id = EXCLUDED.google_id, etag = EXCLUDED.etag,
				sync_hash = EXCLUDED.sync_hash, synced_at = EXCLUDED.synced_at`,
			l.ConnectionID, l.Tenant, m.EventID, m.GoogleID, m.ETag, m.SyncHash, now)
		return err
	})
	if isUniqueViolation(err) {
		return ErrConflict
	}
	if sqlState(err) == "23503" { // the calendar event is gone
		return ErrNotFound
	}
	return err
}

// DeleteGcalEventMap implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) DeleteGcalEventMap(ctx context.Context, l GcalLease, eventID string) error {
	if !calendarIDRe.MatchString(eventID) {
		return ErrInvalidGcal
	}
	return s.gcalFenced(ctx, l, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM gcal_event_map WHERE tenant_id = $1 AND connection_id = $2::uuid AND event_id = $3::uuid`,
			l.Tenant, l.ConnectionID, eventID)
		return err
	})
}

// FinishGcalSync implements Gcal on the Postgres store (rdb 0217).
func (s *Postgres) FinishGcalSync(ctx context.Context, l GcalLease, d GcalSyncDone, now time.Time) error {
	return s.gcalFencedSet(ctx, l, `sync_token = nullif($3, ''), out_cursor = coalesce($4, out_cursor),
		last_synced_at = $5, due_at = $6, sync_lease_until = NULL, updated_at = $5`,
		d.SyncToken, d.OutCursor, now, d.NextDue)
}
