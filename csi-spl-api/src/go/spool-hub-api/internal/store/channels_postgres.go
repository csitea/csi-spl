package store

import (
	"context"
	"errors"
	"sort"
	"strings"
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
	if !ValidChannelID(c.ChannelID) || ChannelReserved(c.ChannelID) {
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
		FROM channels WHERE tenant_id = $1 AND channel_id = $2 AND archived_at IS NULL`,
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
		WHERE tenant_id = $1 AND channel_id = $2 AND archived_at IS NULL`, tenant, id, open)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) ChannelKnown(ctx context.Context, tenant, id string) (bool, error) {
	if IsDefaultChannel(id) || id == ChannelIssues { // the issue discussions have no row
		return true, nil
	}
	var ok bool
	err := s.queryRowTenant(ctx, tenant, `SELECT EXISTS (SELECT 1 FROM channels WHERE tenant_id = $1 AND channel_id = $2 AND archived_at IS NULL)`,
		[]any{tenant, id}, &ok)
	return ok, err
}

// DeleteChannel HARD-deletes a channel (HUM-10 bug, topic ee21db20): its
// messages, then its row - channel_humans and channel_subscriptions cascade
// (rdb 0002 + 0028) - all in one transaction, so the slug is free again. A
// default channel is refused, and only a human-created channel (created_by
// HUM-*) is deletable, matching the Memory store. An archived channel is
// deletable too (the create-conflict dialog offers "delete to free the name").
func (s *Postgres) DeleteChannel(ctx context.Context, tenant, id, by string, now time.Time) error {
	id = NormalizeChannel(id)
	if IsDefaultChannel(id) {
		return ErrConflict
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var createdBy string
		err := tx.QueryRow(ctx, `SELECT created_by FROM channels WHERE tenant_id = $1 AND channel_id = $2 FOR UPDATE`,
			tenant, id).Scan(&createdBy)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if !strings.HasPrefix(createdBy, "HUM-") {
			return ErrConflict
		}
		// its messages (deliveries, message_revisions, message_reactions and
		// message_kind_changes cascade off messages, as DeleteTopic relies on)
		if _, err := tx.Exec(ctx, `DELETE FROM messages WHERE tenant_id = $1 AND channel = $2`, tenant, id); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `DELETE FROM channels WHERE tenant_id = $1 AND channel_id = $2`, tenant, id)
		return err
	})
}

// ArchiveChannel stamps the channels row (rdb 0092) and its topic cards. A
// default channel is refused before the statement; the 0092 CHECK refuses it
// again in the database. The card stamp carries the channel's archived_at so
// UnarchiveChannel can tell it from a card archived on its own earlier.
func (s *Postgres) ArchiveChannel(ctx context.Context, tenant, id, by string, now time.Time) error {
	id = NormalizeChannel(id)
	if IsDefaultChannel(id) {
		return ErrConflict
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE channels SET archived_at = $3, archived_by = $4
			WHERE tenant_id = $1 AND channel_id = $2 AND archived_at IS NULL`, tenant, id, now, by)
		var pe interface{ SQLState() string }
		if errors.As(err, &pe) && pe.SQLState() == "23514" { // channels_archive_human_only
			return ErrConflict
		}
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		// its topic cards: the earliest is_parent=1 row of each task in the
		// channel that is not already archived (scanCard's FirstOfTask shape).
		_, err = tx.Exec(ctx, `UPDATE messages m SET archived_at = $3, archived_by = $4
			WHERE m.tenant_id = $1 AND m.channel = $2 AND m.archived_at IS NULL AND m.is_parent = 1
			AND NOT EXISTS (SELECT 1 FROM messages e WHERE e.tenant_id = m.tenant_id AND e.task_id = m.task_id
				AND e.is_parent = 1 AND (e.received_at, e.msg_id) < (m.received_at, m.msg_id))`, tenant, id, now, by)
		return err
	})
}

// UnarchiveChannel clears the channels row and only the cards THIS archive
// stamped (archived_at equal to the channel's), so a card archived on its own
// before the channel archive keeps its stamp. ErrNotFound when not archived.
func (s *Postgres) UnarchiveChannel(ctx context.Context, tenant, id string) error {
	id = NormalizeChannel(id)
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var at time.Time
		err := tx.QueryRow(ctx, `SELECT archived_at FROM channels
			WHERE tenant_id = $1 AND channel_id = $2 AND archived_at IS NOT NULL FOR UPDATE`, tenant, id).Scan(&at)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE channels SET archived_at = NULL, archived_by = NULL
			WHERE tenant_id = $1 AND channel_id = $2`, tenant, id); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE messages SET archived_at = NULL, archived_by = NULL
			WHERE tenant_id = $1 AND channel = $2 AND archived_at = $3`, tenant, id, at)
		return err
	})
}

// ArchivedChannel returns an archived channel's row, ok=false when none.
func (s *Postgres) ArchivedChannel(ctx context.Context, tenant, id string) (Channel, bool, error) {
	id = NormalizeChannel(id)
	var c Channel
	var by *string
	err := s.queryRowTenant(ctx, tenant, `SELECT channel_id, name, description, created_by, created_at, members_open_invite, archived_at, archived_by
		FROM channels WHERE tenant_id = $1 AND channel_id = $2 AND archived_at IS NOT NULL`,
		[]any{tenant, id}, &c.ChannelID, &c.Name, &c.Description, &c.CreatedBy, &c.CreatedAt, &c.MembersOpenInvite, &c.ArchivedAt, &by)
	if errors.Is(err, pgx.ErrNoRows) {
		return Channel{}, false, nil
	}
	if err != nil {
		return Channel{}, false, err
	}
	c.TenantID = tenant
	c.ArchivedBy = deref(by)
	return c, true, nil
}

// notArchived is the predicate every membership read adds (rdb 0092): the
// rows of an archived channel stay for UnarchiveChannel and grant nothing.
// $1 is the tenant; col names the channel id column of the outer row.
func notArchived(col string) string {
	return `NOT EXISTS (SELECT 1 FROM channels dc WHERE dc.tenant_id = $1 AND dc.channel_id = ` + col + ` AND dc.archived_at IS NOT NULL)`
}

// SetSubscriptions records one box announce against channel_subscriptions.
//
// an announce no longer SEATS anyone. Every created channel is
// members-only (rdb 0028) and the box names its own channel list, so seating
// by announce let any pinned box put an agent into any private channel it
// could guess the slug of - and from then on receive every post there and
// post into it. Agents join a created channel only by invite
// (InviteChannelAgent, specs/038 do_spl_channel_agent_add); the announced
// list is ignored, and only the rows an older hub seated this way are
// cleared. Measured before the change: 0 origin='announce' rows on dev and
// prd (do_spl_db_query, 2026-09-25).
func (s *Postgres) SetSubscriptions(ctx context.Context, tenant, box string, _, _ []string, _ time.Time) error {
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM channel_subscriptions
			WHERE tenant_id = $1 AND box_id = $2 AND origin = 'announce'`, tenant, box)
		return err
	})
}

// InviteChannelAgent records one agent the members asked for. A later
// announce deletes origin 'announce' only, so this row stays.
func (s *Postgres) InviteChannelAgent(ctx context.Context, tenant, channel, box, agent string, now time.Time) error {
	if !ValidChannelID(channel) {
		return ErrConflict
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if err := seedDefault(ctx, tx, tenant, channel); err != nil {
			return err
		}
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
	if !ValidChannelID(channel) {
		return ErrConflict
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if err := seedDefault(ctx, tx, tenant, channel); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO channel_subscriptions
			(tenant_id, channel_id, agent_id, box_id, subscribed_at, origin)
			VALUES ($1, $2, $3, $4, $5, 'removed')
			ON CONFLICT (tenant_id, channel_id, agent_id, box_id)
			DO UPDATE SET origin = 'removed'`, tenant, channel, agent, box, now)
		return mapFK(err)
	})
}

// seedDefault gives a default channel its channels row, which the
// channel_subscriptions FK needs. Idempotent; a created channel is untouched.
func seedDefault(ctx context.Context, tx pgx.Tx, tenant, channel string) error {
	if !IsDefaultChannel(channel) {
		return nil
	}
	_, err := tx.Exec(ctx, pgSeedDefaults, tenant, DefaultChannels)
	return mapFK(err)
}

func (s *Postgres) ChannelMembers(ctx context.Context, tenant, channel string) (map[string][]string, error) {
	out := map[string][]string{}
	// An announce row on a default channel predates rdb 0036 (which deletes
	// them) and grants nothing: a default channel's agents are invited ones.
	err := s.queryTenant(ctx, tenant, `SELECT box_id, agent_id FROM channel_subscriptions
		WHERE tenant_id = $1 AND channel_id = $2 AND origin <> 'removed'
		AND NOT (origin = 'announce' AND channel_id = ANY($3::text[]))
		AND `+notArchived("channel_subscriptions.channel_id")+`
		ORDER BY box_id, agent_id`, []any{tenant, channel, DefaultChannels},
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

func (s *Postgres) ViewChannelStats(ctx context.Context, tenant string, now time.Time, reads map[string]ReadMark, reader, lobby string) ([]ChannelStat, error) {
	cs := newChannelStats(tenant)
	// One batch, one round trip (it was a BEGIN .. COMMIT
	// transaction of 5 + len(reads) round trips). Results come back in queue
	// order, so the unread counts see the counts the stats read stored, and
	// the archived-hidden read subtracts from what the unread reads set.
	reqs := append([]tenantRead{cs.channelsRead(), cs.countsRead(now, reader)}, cs.unreadReads(reads, now, reader)...)
	reqs = append(reqs, cs.hiddenUnreadRead(reads, now, reader, lobby), cs.membersRead())
	if err := s.queryTenantBatch(ctx, tenant, reqs...); err != nil {
		return nil, err
	}
	return cs.result(), nil
}

// channelStats collects one tenant's channel list across the batch's reads:
// every default channel, then what each read adds.
type channelStats struct {
	tenant   string
	by       map[string]*ChannelStat
	archived map[string]bool // rdb 0092: dropped once every read is in
}

func newChannelStats(tenant string) *channelStats {
	cs := &channelStats{tenant: tenant, by: map[string]*ChannelStat{}, archived: map[string]bool{}}
	for _, d := range DefaultChannels {
		cs.get(d)
	}
	return cs
}

// get is the row of channel id, created on first sight.
func (cs *channelStats) get(id string) *ChannelStat {
	st := cs.by[id]
	if st == nil {
		st = &ChannelStat{Channel: Channel{TenantID: cs.tenant, ChannelID: id, Name: id}, Default: IsDefaultChannel(id)}
		if st.Default {
			st.CreatedBy = "hub"
		}
		cs.by[id] = st
	}
	return st
}

// channelsRead is the created channels; an archived one is remembered and left
// out.
func (cs *channelStats) channelsRead() tenantRead {
	return tenantRead{`SELECT channel_id, name, description, created_by, created_at, members_open_invite, archived_at IS NOT NULL FROM channels WHERE tenant_id = $1`,
		[]any{cs.tenant}, func(r pgx.Rows) error {
			var c Channel
			var gone bool
			if err := r.Scan(&c.ChannelID, &c.Name, &c.Description, &c.CreatedBy, &c.CreatedAt, &c.MembersOpenInvite, &gone); err != nil {
				return err
			}
			if gone {
				cs.archived[c.ChannelID] = true
				return nil
			}
			st := cs.get(c.ChannelID)
			st.Name, st.Description, st.CreatedBy, st.CreatedAt, st.MembersOpenInvite = c.Name, c.Description, c.CreatedBy, c.CreatedAt, c.MembersOpenInvite
			return nil
		}}
}

// countsRead is each channel's live message count, newest message and
// posters; unread starts at the count less the reader's own lines (OwnLine:
// from_id, on the same covering index).
func (cs *channelStats) countsRead(now time.Time, reader string) tenantRead {
	// e908f41b lane B: one GROUP BY over the covering index messages_channel_stats
	// (rdb 0080, (tenant_id, channel) INCLUDE received_at, from_id, expires_at) —
	// count, max(received_at) and count(DISTINCT from_id) posters come from ONE
	// Index Only Scan, and the newest message by one index probe per channel at
	// its max(received_at), ties by msg_id text DESC. It was SPL-1127's
	// MATERIALIZED CTE scanned twice with a separate global DISTINCT that spilled
	// to temp; the index makes the DISTINCT a per-channel in-memory sort. Same
	// rows out. Measured pg 16.14, owner under the tenant scope, t1 180k channel
	// messages: 147 ms + Seq Scan 14059 buffers + temp 748 -> 96 ms + Index Only
	// Scan 1340 buffers + no temp.
	return tenantRead{`WITH c AS (
			SELECT channel, count(*)::int AS n, max(received_at) AS last_at, count(DISTINCT from_id)::int AS posters,
				count(*) FILTER (WHERE $3::text IS NULL OR from_id IS DISTINCT FROM $3)::int AS others
			FROM messages WHERE tenant_id = $1 AND channel IS NOT NULL AND expires_at > $2
			GROUP BY channel)
		SELECT c.channel, c.n, c.last_at, l.msg_id, c.posters, c.others FROM c
		CROSS JOIN LATERAL (SELECT x.msg_id::text AS msg_id FROM messages x
			WHERE x.tenant_id = $1 AND x.channel = c.channel AND x.expires_at > $2 AND x.received_at = c.last_at
			ORDER BY x.msg_id::text DESC LIMIT 1) l`,
		[]any{cs.tenant, now, nullIfEmpty(reader)}, func(r pgx.Rows) error {
			var id string
			var n, posters, others int
			var last time.Time
			var lastID string
			if err := r.Scan(&id, &n, &last, &lastID, &posters, &others); err != nil {
				return err
			}
			st := cs.get(id)
			st.Count, st.LastAt, st.LastMsgID, st.Posters, st.Unread = n, last, lastID, posters, others
			return nil
		}}
}

// unreadReads counts, per read mark, the messages after it - less the lines
// the reader already read inside their thread (rdb 0098 t: marks, CLE-77930:
// a thread read from Flow or on another device is not new in its channel).
// A mark only
// matters for a channel with messages, which is known only once the counts
// read is scanned: every mark is queued, and one for a channel without
// messages is scanned and dropped.
func (cs *channelStats) unreadReads(reads map[string]ReadMark, now time.Time, reader string) []tenantRead {
	ids := make([]string, 0, len(reads))
	for id := range reads {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	out := make([]tenantRead, 0, len(ids))
	for _, id := range ids {
		mark := reads[id]
		out = append(out, tenantRead{`SELECT count(*)::int FROM messages
				WHERE tenant_id = $1 AND channel = $2 AND expires_at > $3 AND (received_at, msg_id::text) > ($4::timestamptz, $5::text)
				AND ($6::text IS NULL OR (from_id IS DISTINCT FROM $6 AND typed_by IS DISTINCT FROM $6))` + threadReadSQL("messages", "$1", "$6"),
			[]any{cs.tenant, id, now, mark.At, mark.MsgID, nullIfEmpty(reader)}, func(r pgx.Rows) error {
				var unread int
				if err := r.Scan(&unread); err != nil {
					return err
				}
				if st, ok := cs.by[id]; ok && st.Count > 0 {
					st.Unread = unread
				}
				return nil
			}})
	}
	return out
}

// hiddenUnreadRead takes out of each channel's unread the lines its feed
// hides as archived (specs/041: archivedHideSQL - the line's own card, its
// task's card, its parent task's card, the lobby's excepted). CLE-77930
// (owner, t1 bf737f3f): "2 new messages, then I go there and there is
// nothing new for me" - on prd t1, 20 of 305 others' channel lines in 24 h
// landed in a topic already archived, and every line of a topic archived
// before it was read stayed counted. Driven from the archived cards (222 in
// t1), so the counts read keeps its index-only scan. Same unread test as
// countsRead / unreadReads: after the channel's mark when it has one (and
// then not read inside its thread), and not the reader's own line (OwnLine).
func (cs *channelStats) hiddenUnreadRead(reads map[string]ReadMark, now time.Time, reader, lobby string) tenantRead {
	ids := make([]string, 0, len(reads))
	ats := make([]time.Time, 0, len(reads))
	msgs := make([]string, 0, len(reads))
	for id, m := range reads {
		ids, ats, msgs = append(ids, id), append(ats, m.At), append(msgs, m.MsgID)
	}
	return tenantRead{`WITH z AS (SELECT msg_id, task_id FROM messages WHERE tenant_id = $1 AND archived_at IS NOT NULL),
		h AS (
			SELECT m.msg_id FROM z JOIN messages m ON m.tenant_id = $1 AND m.msg_id = z.msg_id
			UNION SELECT m.msg_id FROM z JOIN messages m ON m.tenant_id = $1 AND m.task_id = z.msg_id
			UNION SELECT m.msg_id FROM z JOIN messages m ON m.tenant_id = $1 AND m.task_id = z.task_id AND z.task_id::text <> $4
			UNION SELECT m.msg_id FROM z JOIN messages m ON m.tenant_id = $1 AND m.parent_task_id = z.task_id AND z.task_id::text <> $4)
		SELECT m.channel, count(*)::int FROM h JOIN messages m ON m.tenant_id = $1 AND m.msg_id = h.msg_id
		LEFT JOIN unnest($5::text[], $6::timestamptz[], $7::text[]) AS mk(ch, at, id) ON mk.ch = m.channel
		WHERE m.channel IS NOT NULL AND m.expires_at > $2
			AND (mk.ch IS NULL OR (m.received_at, m.msg_id::text) > (mk.at, mk.id))
			AND ($3::text IS NULL OR (m.from_id IS DISTINCT FROM $3 AND (mk.ch IS NULL OR m.typed_by IS DISTINCT FROM $3)))
			AND (mk.ch IS NULL OR (TRUE` + threadReadSQL("m", "$1", "$3") + `))
		GROUP BY m.channel`,
		[]any{cs.tenant, now, nullIfEmpty(reader), lobby, ids, ats, msgs}, func(r pgx.Rows) error {
			var id string
			var hidden int
			if err := r.Scan(&id, &hidden); err != nil {
				return err
			}
			if st, ok := cs.by[id]; ok {
				st.Unread = max(0, st.Unread-hidden)
			}
			return nil
		}}
}

// membersRead is each channel's agent and box members (announced default
// channel seats do not count).
func (cs *channelStats) membersRead() tenantRead {
	return tenantRead{`SELECT channel_id, count(*)::int, count(DISTINCT box_id)::int FROM channel_subscriptions
			WHERE tenant_id = $1 AND origin <> 'removed' AND NOT (origin = 'announce' AND channel_id = ANY($2::text[]))
			GROUP BY channel_id`, []any{cs.tenant, DefaultChannels}, func(r pgx.Rows) error {
		var id string
		var agents, boxes int
		if err := r.Scan(&id, &agents, &boxes); err != nil {
			return err
		}
		if st, ok := cs.by[id]; ok {
			st.Agents, st.Boxes = agents, boxes
		}
		return nil
	}}
}

// result is the list, newest activity first, without issue discussions
// (not a channel) and archived channels (rdb 0092).
func (cs *channelStats) result() []ChannelStat {
	out := make([]ChannelStat, 0, len(cs.by))
	for id, st := range cs.by {
		if !ChannelHidden(id) && !cs.archived[id] {
			out = append(out, *st)
		}
	}
	SortChannelStats(out)
	return out
}

// ---- human channel membership (rdb 0028, channel_humans.go) ---------------

func (s *Postgres) ChannelHumanMembers(ctx context.Context, tenant, channel string) ([]string, error) {
	var out []string
	err := s.queryTenant(ctx, tenant, `SELECT human_id FROM channel_humans
		WHERE tenant_id = $1 AND channel_id = $2 AND `+notArchived("channel_humans.channel_id")+` ORDER BY human_id`, []any{tenant, NormalizeChannel(channel)},
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
	if chans, ok := memoChannels(ctx, human, tenant); ok { // SPL-1115: read with the membership
		return chans, nil
	}
	var out []string
	r := humanChannelsRead(tenant, human, &out)
	err := s.queryTenant(ctx, tenant, r.sql, r.args, r.each)
	return out, err
}

// humanChannelsRead is HumanChannels' statement, shared with MemberRole's
// memo batch.
func humanChannelsRead(tenant, human string, out *[]string) tenantRead {
	return tenantRead{sql: `SELECT channel_id FROM channel_humans
		WHERE tenant_id = $1 AND human_id = $2 AND ` + notArchived("channel_humans.channel_id") + ` ORDER BY channel_id`,
		args: []any{tenant, human}, each: func(rows pgx.Rows) error {
			var c string
			if err := rows.Scan(&c); err != nil {
				return err
			}
			*out = append(*out, c)
			return nil
		}}
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

// fileCarrier is the "this message carries file_id" predicate; sha256 is
// checked too because a stored attachment may name the blob under either key
// (wuiSend copies file_id into sha256 when the frame omits it). The 0030 gin
// index never serves it (FORCE RLS: jsonb @> is not LEAKPROOF), so the leading
// m.has_files (rdb 0075, true for every carrier) is what lets the planner walk
// messages_with_files - the few rows with files - not the tenant (SPL-1124).
const fileCarrier = `m.has_files AND (m.files @> jsonb_build_array(jsonb_build_object('file_id', $2::text))
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
		[]any{tenant, fileID, now, human, PublicChannels, channels}, &ok)
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
