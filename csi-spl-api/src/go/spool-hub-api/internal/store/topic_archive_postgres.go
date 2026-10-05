package store

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of specs/041 (topic_archive.go, rdb 0065). Every statement
// runs in the tenant scope.

func (s *Postgres) CardState(ctx context.Context, tenant, msgID string, now time.Time) (CardState, error) {
	if !canonUUIDRe.MatchString(msgID) {
		return CardState{}, ErrNotFound
	}
	// One batch (scope + select), not BEGIN / scope / select / COMMIT.
	var c CardState
	var at *time.Time
	var by *string
	err := s.queryRowTenant(ctx, tenant, cardStateSQL, []any{tenant, msgID, optTime(now)},
		&c.MsgID, &c.TaskID, &c.IsParent, &at, &by, &c.FirstOfTask, &c.IssueTopic)
	if err = cardStateDone(err, at, by, &c); err != nil {
		return CardState{}, err
	}
	return c, nil
}

// cardStateSQL reads one CardState ($1 tenant, $2 msg id, $3 now or NULL,
// which skips the retention check: a state read right after a write).
const cardStateSQL = `SELECT m.msg_id::text, m.task_id::text, m.is_parent, m.archived_at, m.archived_by,
			NOT EXISTS (SELECT 1 FROM messages e WHERE e.tenant_id = m.tenant_id AND e.task_id = m.task_id
				AND e.is_parent = 1 AND (e.received_at, e.msg_id) < (m.received_at, m.msg_id)),
			EXISTS (SELECT 1 FROM issues i WHERE i.tenant_id = m.tenant_id AND i.task_id = m.task_id)
		FROM messages m
		WHERE m.tenant_id = $1 AND m.msg_id = $2 AND ($3::timestamptz IS NULL OR m.expires_at > $3)`

// scanCard reads msgID's CardState inside tx. A zero now skips the
// retention check (a state read right after a write).
func scanCard(ctx context.Context, tx pgx.Tx, tenant, msgID string, now time.Time, c *CardState) error {
	var at *time.Time
	var by *string
	err := tx.QueryRow(ctx, cardStateSQL, tenant, msgID, optTime(now)).
		Scan(&c.MsgID, &c.TaskID, &c.IsParent, &at, &by, &c.FirstOfTask, &c.IssueTopic)
	return cardStateDone(err, at, by, c)
}

// cardStateDone maps a CardState read's error (no row is ErrNotFound) and
// fills the nullable archive stamp.
func cardStateDone(err error, at *time.Time, by *string, c *CardState) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	c.ArchivedBy = deref(by)
	if at != nil {
		c.ArchivedAt = *at
	}
	return nil
}

func (s *Postgres) SetArchived(ctx context.Context, tenant, msgID, by string, at time.Time, archived bool) (CardState, error) {
	if !canonUUIDRe.MatchString(msgID) {
		return CardState{}, ErrNotFound
	}
	var c CardState
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var tag interface{ RowsAffected() int64 }
		var err error
		if archived { // COALESCE keeps the first stamp of an already archived card
			tag, err = tx.Exec(ctx, `UPDATE messages SET archived_at = COALESCE(archived_at, $3),
				archived_by = CASE WHEN archived_at IS NULL THEN $4 ELSE archived_by END
				WHERE tenant_id = $1 AND msg_id = $2`, tenant, msgID, at, by)
		} else {
			tag, err = tx.Exec(ctx, `UPDATE messages SET archived_at = NULL, archived_by = NULL
				WHERE tenant_id = $1 AND msg_id = $2`, tenant, msgID)
		}
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		if err := archiveMirrorsTx(ctx, tx, tenant, msgID, by, at, archived); err != nil { // spec 067 edge 3
			return err
		}
		return scanCard(ctx, tx, tenant, msgID, time.Time{}, &c)
	})
	return c, err
}

// topicTx walks the topic inside tx, the card row held FOR UPDATE (the
// delete path): one indexed statement per level (messages_task on task_id,
// messages_parent on parent_task_id).
func topicTx(ctx context.Context, tx pgx.Tx, tenant, msgID, ownTask string) (TopicSet, error) {
	var one int
	err := tx.QueryRow(ctx, `SELECT 1 FROM messages WHERE tenant_id = $1 AND msg_id = $2 FOR UPDATE`, tenant, msgID).Scan(&one)
	if errors.Is(err, pgx.ErrNoRows) {
		return TopicSet{}, ErrNotFound
	}
	if err != nil {
		return TopicSet{}, err
	}
	return walkTopic(msgID, ownTask, func(tasks []string) ([][2]string, error) {
		var out [][2]string
		err := eachRow(ctx, tx, `SELECT msg_id::text, task_id::text FROM messages
			WHERE tenant_id = $1 AND (task_id = ANY($2::uuid[]) OR parent_task_id = ANY($2::uuid[]))
			ORDER BY received_at, msg_id`, []any{tenant, tasks}, func(rows pgx.Rows) error {
			var r [2]string
			if err := rows.Scan(&r[0], &r[1]); err != nil {
				return err
			}
			out = append(out, r)
			return nil
		})
		return out, err
	})
}

// TopicOf is the topic preview, a GET: no transaction and no row lock (a
// write on the card no longer waits for it), the card check queued with the
// first level's read (perf E09).
func (s *Postgres) TopicOf(ctx context.Context, tenant, msgID, ownTask string) (TopicSet, error) {
	if !canonUUIDRe.MatchString(msgID) || (ownTask != "" && !canonUUIDRe.MatchString(ownTask)) {
		return TopicSet{}, ErrNotFound
	}
	found := false
	sets, err := s.walkTopics(ctx, tenant, []string{msgID}, []string{ownTask}, tenantRead{
		sql: `SELECT 1 FROM messages WHERE tenant_id = $1 AND msg_id = $2`, args: []any{tenant, msgID},
		each: func(pgx.Rows) error { found = true; return nil },
	})
	switch {
	case err != nil && !errors.Is(err, ErrConflict):
		return TopicSet{}, err
	case !found:
		return TopicSet{}, ErrNotFound
	case err != nil:
		return TopicSet{}, err
	}
	return sets[0], nil
}

// DeleteTopic walks and deletes in the same transaction, the card row held
// FOR UPDATE, so a reply stored while the walk runs either lands before the
// lock (and is walked) or waits and finds its topic gone. deliveries,
// message_revisions, message_reactions and message_kind_changes cascade.
func (s *Postgres) DeleteTopic(ctx context.Context, tenant, msgID, ownTask string) (TopicSet, error) {
	if !canonUUIDRe.MatchString(msgID) || (ownTask != "" && !canonUUIDRe.MatchString(ownTask)) {
		return TopicSet{}, ErrNotFound
	}
	var set TopicSet
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		if set, err = topicTx(ctx, tx, tenant, msgID, ownTask); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `DELETE FROM messages WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[])`, tenant, set.MsgIDs)
		return err
	})
	if err != nil {
		return TopicSet{}, err
	}
	return set, nil
}

func (s *Postgres) ArchivedCards(ctx context.Context, tenant string, q ArchivedQuery) ([]ArchivedCard, error) {
	door, args := "true", []any{tenant, q.Now, optTime(q.BeforeAt), q.BeforeID, pgLimit(q.Limit)}
	if q.Reader != "" {
		door = `((m.channel IS NULL AND (m.from_id = $6 OR m.to_id = $6))
			OR m.channel = ANY($7::text[]) OR m.channel = ANY($8::text[]))`
		args = append(args, q.Reader, PublicChannels, q.ReaderChannels)
	}
	var out []ArchivedCard
	err := s.queryTenant(ctx, tenant, `SELECT m.msg_id::text, m.task_id::text, COALESCE(m.channel, ''), m.from_id,
			m.received_at, m.env, m.edited_at, m.edited_by, m.is_parent, m.typed_by, m.archived_at, m.archived_by
		FROM messages m
		WHERE m.tenant_id = $1 AND m.archived_at IS NOT NULL AND m.expires_at > $2
			AND ($3::timestamptz IS NULL OR (m.archived_at, m.msg_id::text) < ($3::timestamptz, $4::text))
			AND `+door+`
		ORDER BY m.archived_at DESC, m.msg_id::text DESC
		LIMIT $5`, args, func(rows pgx.Rows) error {
		c := ArchivedCard{ViewMsg: ViewMsg{Deliveries: []ViewDelivery{}}}
		var editedAt *time.Time
		var editedBy, typedBy, archivedBy *string
		if err := rows.Scan(&c.MsgID, &c.TaskID, &c.Channel, &c.FromID, &c.ReceivedAt, &c.Env, &editedAt, &editedBy,
			&c.IsParent, &typedBy, &c.ArchivedAt, &archivedBy); err != nil {
			return err
		}
		if editedAt != nil {
			c.EditedAt = *editedAt
		}
		c.EditedBy, c.TypedBy, c.ArchivedBy = deref(editedBy), deref(typedBy), deref(archivedBy)
		c.RowChannel = c.Channel
		out = append(out, c)
		return nil
	})
	return out, err
}

func (s *Postgres) TopicReplies(ctx context.Context, tenant string, msgIDs, ownTasks []string) (map[string]int, error) {
	var cards, owns []string
	for i, id := range msgIDs {
		own := ""
		if i < len(ownTasks) {
			own = ownTasks[i]
		}
		if canonUUIDRe.MatchString(id) && (own == "" || canonUUIDRe.MatchString(own)) {
			cards, owns = append(cards, id), append(owns, own)
		}
	}
	out := map[string]int{}
	sets, err := s.walkTopics(ctx, tenant, cards, owns)
	if err != nil {
		return out, err
	}
	for i, id := range cards {
		out[id] = sets[i].Replies()
	}
	return out, nil
}

// topicRowsSQL is walkTopic's next for the tasks $2, with each row's
// parent_task_id, so one read serves every card whose frontier holds one of
// them.
const topicRowsSQL = `SELECT msg_id::text, task_id::text, COALESCE(parent_task_id::text, ''), received_at FROM messages
		WHERE tenant_id = $1 AND (task_id = ANY($2::uuid[]) OR parent_task_id = ANY($2::uuid[]))`

// topicRow is one messages row as the walk sees it.
type topicRow struct {
	msgID, taskID string
	at            time.Time
}

// topicCache holds, for every task read so far, the rows whose task_id or
// parent_task_id is that task.
type topicCache map[string][]topicRow

// errTopicMiss stops a walk at a task the cache has not read yet.
var errTopicMiss = errors.New("topic walk: task not read yet")

// next is walkTopic's next served from the cache, in topicTx's order
// (received_at, msg_id). It adds the tasks it lacks to miss and then answers
// errTopicMiss.
func (c topicCache) next(tasks []string, miss map[string]bool) ([][2]string, error) {
	var rows []topicRow
	seen, missed := map[string]bool{}, false
	for _, t := range tasks {
		got, ok := c[t]
		if !ok {
			miss[t], missed = true, true
		}
		for _, r := range got {
			if !seen[r.msgID] {
				seen[r.msgID] = true
				rows = append(rows, r)
			}
		}
	}
	if missed {
		return nil, errTopicMiss
	}
	sort.Slice(rows, func(i, j int) bool {
		if !rows[i].at.Equal(rows[j].at) {
			return rows[i].at.Before(rows[j].at)
		}
		return rows[i].msgID < rows[j].msgID
	})
	out := make([][2]string, len(rows))
	for i, r := range rows {
		out[i] = [2]string{r.msgID, r.taskID}
	}
	return out, nil
}

// walkTopics runs walkTopic for every card against one topicCache. Each pass
// replays every walk from the cache and reads all the tasks they missed in
// ONE statement, so a page of cards costs one round trip per level of its
// deepest topic, not two per card (perf E09: 3 + 2k round trips before).
// first is queued in the first read's batch. No transaction: under READ
// COMMITTED each statement took its own snapshot inside one too.
func (s *Postgres) walkTopics(ctx context.Context, tenant string, cards, owns []string, first ...tenantRead) ([]TopicSet, error) {
	cache, sets := topicCache{}, make([]TopicSet, len(cards))
	for {
		miss := map[string]bool{}
		for i, card := range cards {
			set, err := walkTopic(card, owns[i], func(tasks []string) ([][2]string, error) { return cache.next(tasks, miss) })
			if err != nil && !errors.Is(err, errTopicMiss) {
				return nil, err
			}
			sets[i] = set
		}
		if len(miss) == 0 {
			return sets, nil
		}
		tasks := make([]string, 0, len(miss))
		for t := range miss {
			tasks = append(tasks, t)
			cache[t] = nil
		}
		read := tenantRead{sql: topicRowsSQL, args: []any{tenant, tasks}, each: func(rows pgx.Rows) error {
			var r topicRow
			var parent string
			if err := rows.Scan(&r.msgID, &r.taskID, &parent, &r.at); err != nil {
				return err
			}
			if miss[r.taskID] {
				cache[r.taskID] = append(cache[r.taskID], r)
			}
			if parent != r.taskID && miss[parent] {
				cache[parent] = append(cache[parent], r)
			}
			return nil
		}}
		if err := s.queryTenantBatch(ctx, tenant, append(first, read)...); err != nil {
			return nil, err
		}
		first = nil
	}
}

// topicArchivedSQL is archivedTopicHideSQL's row for one task ($1 tenant,
// $2 task, $3 lobby or ""): the earliest archive stamp. messages_archived
// holds only archived rows, so this reads a handful.
const topicArchivedSQL = `SELECT z.archived_at, z.archived_by FROM messages z
		WHERE z.tenant_id = $1 AND z.archived_at IS NOT NULL
			AND (z.msg_id = $2::uuid OR (z.task_id = $2::uuid AND $2::text <> $3::text))
		ORDER BY z.archived_at LIMIT 1`

func (s *Postgres) TopicArchived(ctx context.Context, tenant, task, lobby string) (time.Time, string, error) {
	if !canonUUIDRe.MatchString(task) {
		return time.Time{}, "", nil
	}
	var at *time.Time
	var by *string
	err := s.queryRowTenant(ctx, tenant, topicArchivedSQL, []any{tenant, task, lobby}, &at, &by)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && at == nil) {
		return time.Time{}, "", nil
	}
	if err != nil {
		return time.Time{}, "", err
	}
	return *at, deref(by), nil
}

// archivedHideSQL is the list filter on alias a (a messages row): none of
// its own card, its task's card, its parent task's card (the lobby's
// excepted in both) or the lobby card whose thread it is in is archived. lobby is a bound $n ("" = no lobby).
// Archived rows are few and messages_archived holds only them.
func archivedHideSQL(a, tenant, lobby string) string {
	return ` AND NOT EXISTS (SELECT 1 FROM messages z WHERE z.tenant_id = ` + tenant + ` AND z.archived_at IS NOT NULL
		AND (z.msg_id = ` + a + `.msg_id OR z.msg_id = ` + a + `.task_id
			OR (z.task_id = ` + a + `.task_id AND ` + a + `.task_id::text <> ` + lobby + `)
			OR (z.task_id = ` + a + `.parent_task_id AND ` + a + `.parent_task_id::text <> ` + lobby + `)))`
}

// archivedTopicHideSQL is the topic-list filter on alias a (any row of the
// topic): the topic's card is archived, or the topic is an archived lobby
// card's thread.
func archivedTopicHideSQL(a, tenant, lobby string) string {
	return ` AND NOT EXISTS (SELECT 1 FROM messages z WHERE z.tenant_id = ` + tenant + ` AND z.archived_at IS NOT NULL
		AND (z.msg_id = ` + a + `.task_id OR (z.task_id = ` + a + `.task_id AND ` + a + `.task_id::text <> ` + lobby + `)))`
}
