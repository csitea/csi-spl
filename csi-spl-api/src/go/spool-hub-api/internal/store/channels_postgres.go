package store

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of channels-v1 (channels.go). Default channel rows are seeded
// by 0008 (existing tenants + an AFTER INSERT trigger on tenants); every
// statement here still treats the defaults as known, so a tenant created
// before 0008 ran behaves the same.

const pgSeedDefaults = `INSERT INTO channels (tenant_id, channel_id, name, created_by, members_open_invite)
	SELECT $1, d, d, 'hub', false FROM unnest($2::text[]) AS d
	ON CONFLICT (tenant_id, channel_id) DO NOTHING`

func (s *Postgres) CreateChannel(ctx context.Context, c Channel) error {
	if c.ChannelID == ChannelGeneralAlias || !ValidChannelID(c.ChannelID) || IsDefaultChannel(c.ChannelID) {
		return ErrConflict
	}
	var created *time.Time
	if !c.CreatedAt.IsZero() {
		created = &c.CreatedAt
	}
	tag, err := s.execTenant(ctx, c.TenantID, `INSERT INTO channels (tenant_id, channel_id, name, description, created_by, created_at, members_open_invite)
		VALUES ($1, $2, $3, $4, $5, COALESCE($6::timestamptz, now()), $7) ON CONFLICT (tenant_id, channel_id) DO NOTHING`,
		c.TenantID, c.ChannelID, c.Name, c.Description, c.CreatedBy, created, c.MembersOpenInvite)
	if err != nil {
		return mapFK(err)
	}
	if tag.RowsAffected() == 0 {
		return ErrConflict
	}
	return nil
}

func (s *Postgres) Channel(ctx context.Context, tenant, id string) (Channel, error) {
	id = NormalizeChannel(id)
	var c Channel
	err := s.queryRowTenant(ctx, tenant, `SELECT channel_id, name, description, created_by, created_at, members_open_invite
		FROM channels WHERE tenant_id = $1 AND channel_id = $2`,
		[]any{tenant, id}, &c.ChannelID, &c.Name, &c.Description, &c.CreatedBy, &c.CreatedAt, &c.MembersOpenInvite)
	if errors.Is(err, pgx.ErrNoRows) {
		if IsDefaultChannel(id) {
			return Channel{TenantID: tenant, ChannelID: id, Name: id, CreatedBy: "hub"}, nil
		}
		return Channel{}, ErrNotFound
	}
	if err != nil {
		return Channel{}, err
	}
	c.TenantID = tenant
	return c, nil
}

func (s *Postgres) SetMembersOpenInvite(ctx context.Context, tenant, id string, open bool) error {
	id = NormalizeChannel(id)
	if ChannelPublic(id) {
		return ErrConflict
	}
	tag, err := s.execTenant(ctx, tenant, `UPDATE channels SET members_open_invite = $3
		WHERE tenant_id = $1 AND channel_id = $2`, tenant, id, open)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) ChannelKnown(ctx context.Context, tenant, id string) (bool, error) {
	if IsDefaultChannel(id) {
		return true, nil
	}
	var ok bool
	err := s.queryRowTenant(ctx, tenant, `SELECT EXISTS (SELECT 1 FROM channels WHERE tenant_id = $1 AND channel_id = $2)`,
		[]any{tenant, id}, &ok)
	return ok, err
}

func (s *Postgres) SetSubscriptions(ctx context.Context, tenant, box string, agents, channels []string, now time.Time) error {
	var chs []string
	for _, c := range channels {
		if c != ChannelLobby && ValidChannelID(c) {
			chs = append(chs, c)
		}
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		// An invited agent stays. Only the set this box announced last time
		// is replaced by the set it is announcing now.
		if _, err := tx.Exec(ctx, `DELETE FROM channel_subscriptions
			WHERE tenant_id = $1 AND box_id = $2 AND origin = 'announce'`, tenant, box); err != nil {
			return err
		}
		if len(chs) == 0 || len(agents) == 0 {
			return nil
		}
		if _, err := tx.Exec(ctx, pgSeedDefaults, tenant, DefaultChannels); err != nil {
			return mapFK(err)
		}
		_, err := tx.Exec(ctx, `INSERT INTO channel_subscriptions (tenant_id, channel_id, agent_id, box_id, subscribed_at)
			SELECT $1, c.channel_id, a, $2, $5
			FROM channels c CROSS JOIN unnest($4::text[]) AS a
			WHERE c.tenant_id = $1 AND c.channel_id = ANY($3::text[])
			ON CONFLICT DO NOTHING`, tenant, box, chs, agents, now)
		return err
	})
}

// InviteChannelAgent records one agent the members asked for. A later
// announce deletes origin 'announce' only, so this row stays.
func (s *Postgres) InviteChannelAgent(ctx context.Context, tenant, channel, box, agent string, now time.Time) error {
	if IsDefaultChannel(channel) || !ValidChannelID(channel) {
		return ErrConflict
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO channel_subscriptions
			(tenant_id, channel_id, agent_id, box_id, subscribed_at, origin)
			VALUES ($1, $2, $3, $4, $5, 'invite')
			ON CONFLICT (tenant_id, channel_id, agent_id, box_id)
			DO UPDATE SET origin = 'invite'`, tenant, channel, agent, box, now)
		return mapFK(err)
	})
}

// RemoveChannelAgent marks the agent removed. ON CONFLICT keeps that mark
// when a later announce tries to insert the same row.
func (s *Postgres) RemoveChannelAgent(ctx context.Context, tenant, channel, box, agent string, now time.Time) error {
	if IsDefaultChannel(channel) || !ValidChannelID(channel) {
		return ErrConflict
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO channel_subscriptions
			(tenant_id, channel_id, agent_id, box_id, subscribed_at, origin)
			VALUES ($1, $2, $3, $4, $5, 'removed')
			ON CONFLICT (tenant_id, channel_id, agent_id, box_id)
			DO UPDATE SET origin = 'removed'`, tenant, channel, agent, box, now)
		return mapFK(err)
	})
}

func (s *Postgres) ChannelMembers(ctx context.Context, tenant, channel string) (map[string][]string, error) {
	if channel == ChannelLobby {
		return s.Roster(ctx, tenant)
	}
	out := map[string][]string{}
	err := s.queryTenant(ctx, tenant, `SELECT box_id, agent_id FROM channel_subscriptions
		WHERE tenant_id = $1 AND channel_id = $2 AND origin <> 'removed'
		ORDER BY box_id, agent_id`, []any{tenant, channel},
		func(rows pgx.Rows) error {
			var box, agent string
			if err := rows.Scan(&box, &agent); err != nil {
				return err
			}
			out[box] = append(out[box], agent)
			return nil
		})
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Postgres) ViewChannelStats(ctx context.Context, tenant string, now time.Time, reads map[string]ReadMark) ([]ChannelStat, error) {
	by := map[string]*ChannelStat{}
	get := func(id string) *ChannelStat {
		st := by[id]
		if st == nil {
			st = &ChannelStat{Channel: Channel{TenantID: tenant, ChannelID: id, Name: id}, Default: IsDefaultChannel(id)}
			if st.Default {
				st.CreatedBy = "hub"
			}
			by[id] = st
		}
		return st
	}
	for _, d := range DefaultChannels {
		get(d)
	}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		scan := func(q string, args []any, fn func(pgx.Rows) error) error {
			return eachRow(ctx, tx, q, args, fn)
		}
		if err := scan(`SELECT channel_id, name, description, created_by, created_at, members_open_invite FROM channels WHERE tenant_id = $1`,
			[]any{tenant}, func(r pgx.Rows) error {
				var c Channel
				if err := r.Scan(&c.ChannelID, &c.Name, &c.Description, &c.CreatedBy, &c.CreatedAt, &c.MembersOpenInvite); err != nil {
					return err
				}
				st := get(c.ChannelID)
				st.Name, st.Description, st.CreatedBy, st.CreatedAt, st.MembersOpenInvite = c.Name, c.Description, c.CreatedBy, c.CreatedAt, c.MembersOpenInvite
				return nil
			}); err != nil {
			return err
		}
		if err := scan(`SELECT channel, count(*)::int, max(received_at),
				(array_agg(msg_id::text ORDER BY received_at DESC, msg_id::text DESC))[1], count(DISTINCT from_id)::int
			FROM messages WHERE tenant_id = $1 AND channel IS NOT NULL AND expires_at > $2 GROUP BY channel`,
			[]any{tenant, now}, func(r pgx.Rows) error {
				var id string
				var n, posters int
				var last time.Time
				var lastID string
				if err := r.Scan(&id, &n, &last, &lastID, &posters); err != nil {
					return err
				}
				st := get(id)
				st.Count, st.LastAt, st.LastMsgID, st.Posters, st.Unread = n, last, lastID, posters, n
				return nil
			}); err != nil {
			return err
		}
		for id, mark := range reads {
			st, ok := by[id]
			if !ok || st.Count == 0 {
				continue
			}
			if err := tx.QueryRow(ctx, `SELECT count(*)::int FROM messages
				WHERE tenant_id = $1 AND channel = $2 AND expires_at > $3 AND (received_at, msg_id::text) > ($4::timestamptz, $5::text)`,
				tenant, id, now, mark.At, mark.MsgID).Scan(&st.Unread); err != nil {
				return err
			}
		}
		if err := scan(`SELECT channel_id, count(*)::int, count(DISTINCT box_id)::int FROM channel_subscriptions
			WHERE tenant_id = $1 GROUP BY channel_id`, []any{tenant}, func(r pgx.Rows) error {
			var id string
			var agents, boxes int
			if err := r.Scan(&id, &agents, &boxes); err != nil {
				return err
			}
			if st, ok := by[id]; ok && id != ChannelLobby {
				st.Agents, st.Boxes = agents, boxes
			}
			return nil
		}); err != nil {
			return err
		}
		lobby := by[ChannelLobby]
		if err := tx.QueryRow(ctx, `SELECT count(*)::int, count(DISTINCT box_id)::int FROM roster WHERE tenant_id = $1`,
			tenant).Scan(&lobby.Agents, &lobby.Boxes); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	out := make([]ChannelStat, 0, len(by))
	for _, st := range by {
		out = append(out, *st)
	}
	SortChannelStats(out) // CLE-3425: newest activity first
	return out, nil
}

// ---- human channel membership (rdb 0028, channel_humans.go) ---------------

func (s *Postgres) ChannelHumanMembers(ctx context.Context, tenant, channel string) ([]string, error) {
	var out []string
	err := s.queryTenant(ctx, tenant, `SELECT human_id FROM channel_humans
		WHERE tenant_id = $1 AND channel_id = $2 ORDER BY human_id`, []any{tenant, NormalizeChannel(channel)},
		func(rows pgx.Rows) error {
			var h string
			if err := rows.Scan(&h); err != nil {
				return err
			}
			out = append(out, h)
			return nil
		})
	return out, err
}

func (s *Postgres) HumanChannels(ctx context.Context, tenant, human string) ([]string, error) {
	var out []string
	err := s.queryTenant(ctx, tenant, `SELECT channel_id FROM channel_humans
		WHERE tenant_id = $1 AND human_id = $2 ORDER BY channel_id`, []any{tenant, human},
		func(rows pgx.Rows) error {
			var c string
			if err := rows.Scan(&c); err != nil {
				return err
			}
			out = append(out, c)
			return nil
		})
	return out, err
}

func (s *Postgres) AddChannelHumans(ctx context.Context, tenant, channel string, humans []string, by string, now time.Time) error {
	channel = NormalizeChannel(channel)
	if len(humans) == 0 {
		return nil
	}
	if by == "" {
		by = "hub"
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		// A default channel has no row until something seeds it, and the FK
		// needs one; seeding is idempotent.
		if _, err := tx.Exec(ctx, pgSeedDefaults, tenant, DefaultChannels); err != nil {
			return mapFK(err)
		}
		_, err := tx.Exec(ctx, `INSERT INTO channel_humans (tenant_id, channel_id, human_id, joined_at, added_by)
			SELECT $1, $2, h, $3, $4 FROM unnest($5::text[]) AS h
			ON CONFLICT DO NOTHING`, tenant, channel, now, by, humans)
		return mapFK(err)
	})
}

func (s *Postgres) RemoveChannelHuman(ctx context.Context, tenant, channel, human string) error {
	tag, err := s.execTenant(ctx, tenant, `DELETE FROM channel_humans
		WHERE tenant_id = $1 AND channel_id = $2 AND human_id = $3`, tenant, NormalizeChannel(channel), human)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// TopicAccess is one aggregate over the topic's messages: its first
// message's channel, and every id at either end. A task_id that is not a
// canonical uuid matches no row (027 T030, same as ViewTopic).
func (s *Postgres) TopicAccess(ctx context.Context, tenant, task string, now time.Time) (TopicAccess, error) {
	var a TopicAccess
	if !canonUUIDRe.MatchString(task) {
		return a, nil
	}
	var chans, ends []string
	var n int
	err := s.queryRowTenant(ctx, tenant, `SELECT count(*)::int,
			array_agg(DISTINCT COALESCE(channel, '')),
			COALESCE(array_agg(DISTINCT from_id) FILTER (WHERE channel IS NULL), '{}')
				|| COALESCE(array_agg(DISTINCT to_id) FILTER (WHERE channel IS NULL), '{}')
		FROM messages WHERE tenant_id = $1 AND task_id = $2::uuid AND expires_at > $3`,
		[]any{tenant, task, now}, &n, &chans, &ends)
	if err != nil || n == 0 {
		return a, err
	}
	a.Found, a.Channels = true, chans
	seen := map[string]bool{}
	for _, p := range ends {
		if p != "" && !seen[p] {
			seen[p] = true
			a.DMParties = append(a.DMParties, p)
		}
	}
	sort.Strings(a.Channels)
	sort.Strings(a.DMParties)
	return a, nil
}

// ---- the file read door (rdb 0028 + 0030, file_door.go) -------------------

// fileCarrier is the indexable "this message carries file_id" predicate.
// Containment against the 0030 gin (files jsonb_path_ops) index; sha256 is
// checked too because a stored attachment may name the blob under either key
// (wuiSend copies file_id into sha256 when the frame omits it).
const fileCarrier = `(m.files @> jsonb_build_array(jsonb_build_object('file_id', $2::text))
	OR m.files @> jsonb_build_array(jsonb_build_object('sha256', $2::text)))`

func (s *Postgres) FileAttached(ctx context.Context, tenant, fileID string, now time.Time) (bool, error) {
	var ok bool
	err := s.queryRowTenant(ctx, tenant, `SELECT EXISTS (SELECT 1 FROM messages m
		WHERE m.tenant_id = $1 AND m.expires_at > $3 AND `+fileCarrier+`)`,
		[]any{tenant, fileID, now}, &ok)
	return ok, err
}

func (s *Postgres) FileReadableByHuman(ctx context.Context, tenant, fileID, human string, channels []string, now time.Time) (bool, error) {
	var ok bool
	err := s.queryRowTenant(ctx, tenant, `SELECT EXISTS (SELECT 1 FROM messages m
		WHERE m.tenant_id = $1 AND m.expires_at > $3 AND `+fileCarrier+` AND (
			(m.channel IS NULL AND (m.from_id = $4 OR m.to_id = $4))
			OR m.channel = ANY($5::text[]) OR m.channel = ANY($6::text[])))`,
		[]any{tenant, fileID, now, human, DefaultChannels, channels}, &ok)
	return ok, err
}

func (s *Postgres) FileReadableByBox(ctx context.Context, tenant, fileID, box string, now time.Time) (bool, error) {
	var ok bool
	err := s.queryRowTenant(ctx, tenant, `SELECT EXISTS (SELECT 1 FROM messages m
		WHERE m.tenant_id = $1 AND m.expires_at > $3 AND `+fileCarrier+` AND (
			m.from_box = $4 OR m.to_box = $4
			OR EXISTS (SELECT 1 FROM deliveries d
				WHERE d.tenant_id = m.tenant_id AND d.msg_id = m.msg_id AND d.to_box = $4)))`,
		[]any{tenant, fileID, now, box}, &ok)
	return ok, err
}
