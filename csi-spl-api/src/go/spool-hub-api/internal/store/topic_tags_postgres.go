// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Postgres side of topic_tags.go (rdb 0328, spec 196 row T1). Every write runs
// in the workspace's own scope, in one transaction, and takes its locks in
// one order (spec 196 2.3): the topic's topic_tag_stamps row first (an upsert
// holds it until the commit, so two writes on one topic queue and the cap of
// 10 holds), then the tag row. A write that links a tag holds the tag FOR KEY
// SHARE; a prune holds it FOR UPDATE and deletes it only while no link is
// left, so a prune never removes a tag another topic is linking.

// topicTagLock upserts the topic's stamp row: the per-topic lock.
const topicTagLock = `INSERT INTO topic_tag_stamps (tenant_id, task_id, updated_at) VALUES ($1, $2::uuid, $3)
	ON CONFLICT (tenant_id, task_id) DO UPDATE SET updated_at = EXCLUDED.updated_at`

// topicTagSlugs reads a topic's slugs, sorted.
const topicTagSlugs = `SELECT t.slug FROM topic_tag_links l
	JOIN topic_tags t ON t.tenant_id = l.tenant_id AND t.tag_id = l.tag_id
	WHERE l.tenant_id = $1 AND l.task_id = $2::uuid ORDER BY t.slug`

// AddTopicTag implements TopicTagStore.
func (s *Postgres) AddTopicTag(ctx context.Context, tenant, taskID, raw, by string, at time.Time) (TopicTagChange, error) {
	task, slug, err := checkTopicTag(tenant, taskID, raw)
	if err != nil {
		return TopicTagChange{}, err
	}
	ch := TopicTagChange{TaskID: task, Slug: slug}
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, topicTagLock, tenant, task, at.UTC()); err != nil {
			return err
		}
		tagID, err := topicTagHoldTx(ctx, tx, tenant, slug, by, at)
		if err != nil {
			return err
		}
		if ch.Changed, err = topicTagLinkTx(ctx, tx, tenant, task, tagID, by, at); err != nil {
			return err
		}
		ch.Tags, err = topicTagSlugsTx(ctx, tx, tenant, task)
		return err
	})
	if err != nil {
		return TopicTagChange{}, mapFK(err)
	}
	return ch, nil
}

// topicTagHoldTx makes the workspace tag on first use and holds it FOR KEY
// SHARE until the commit. A prune that deleted it between the two
// statements leaves no row to hold: then it is made again.
func topicTagHoldTx(ctx context.Context, tx pgx.Tx, tenant, slug, by string, at time.Time) (string, error) {
	for range 3 {
		if _, err := tx.Exec(ctx, `INSERT INTO topic_tags (tenant_id, tag_id, slug, created_by, created_at)
			VALUES ($1, $2::uuid, $3, $4, $5) ON CONFLICT (tenant_id, slug) DO NOTHING`,
			tenant, uuid.New(), slug, by, at.UTC()); err != nil {
			return "", err
		}
		var tagID string
		err := tx.QueryRow(ctx, `SELECT tag_id::text FROM topic_tags WHERE tenant_id = $1 AND slug = $2 FOR KEY SHARE`,
			tenant, slug).Scan(&tagID)
		if !errors.Is(err, pgx.ErrNoRows) {
			return tagID, err
		}
	}
	return "", ErrConflict
}

// topicTagLinkTx links the held tag to the topic under the cap; false: it
// was linked already.
func topicTagLinkTx(ctx context.Context, tx pgx.Tx, tenant, task, tagID, by string, at time.Time) (bool, error) {
	var linked bool
	var n int
	err := tx.QueryRow(ctx, `SELECT coalesce(bool_or(tag_id = $3::uuid), false), count(*) FROM topic_tag_links
		WHERE tenant_id = $1 AND task_id = $2::uuid`, tenant, task, tagID).Scan(&linked, &n)
	switch {
	case err != nil:
		return false, err
	case linked:
		return false, nil
	case n >= TopicTagsMax:
		return false, ErrTooManyTopicTags
	}
	_, err = tx.Exec(ctx, `INSERT INTO topic_tag_links (tenant_id, task_id, tag_id, added_by, added_at)
		VALUES ($1, $2::uuid, $3::uuid, $4, $5)`, tenant, task, tagID, by, at.UTC())
	return err == nil, err
}

func topicTagSlugsTx(ctx context.Context, tx pgx.Tx, tenant, task string) ([]string, error) {
	rows, err := tx.Query(ctx, topicTagSlugs, tenant, task)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// RemoveTopicTag implements TopicTagStore.
func (s *Postgres) RemoveTopicTag(ctx context.Context, tenant, taskID, raw, _ string, at time.Time) (TopicTagChange, error) {
	task, slug, err := checkTopicTag(tenant, taskID, raw)
	if err != nil {
		return TopicTagChange{}, err
	}
	ch := TopicTagChange{TaskID: task, Slug: slug}
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, topicTagLock, tenant, task, at.UTC()); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `DELETE FROM topic_tag_links l USING topic_tags t
			WHERE l.tenant_id = $1 AND l.task_id = $2::uuid AND t.tenant_id = l.tenant_id AND t.tag_id = l.tag_id AND t.slug = $3
			RETURNING l.tag_id::text`, tenant, task, slug)
		if err != nil {
			return err
		}
		gone, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			return err
		}
		if ch.Changed = len(gone) > 0; ch.Changed {
			if err = pruneTopicTagsTx(ctx, tx, tenant, gone); err != nil {
				return err
			}
		}
		ch.Tags, err = topicTagSlugsTx(ctx, tx, tenant, task)
		return err
	})
	if err != nil {
		return TopicTagChange{}, err
	}
	return ch, nil
}

// pruneTopicTagsTx deletes each of the workspace tags no topic links any
// more, holding them FOR UPDATE first (spec 196 2.3 rule 2): a write that
// holds one FOR KEY SHARE makes the prune wait, and its link then keeps the
// tag.
func pruneTopicTagsTx(ctx context.Context, tx pgx.Tx, tenant string, tagIDs []string) error {
	if len(tagIDs) == 0 {
		return nil
	}
	if _, err := tx.Exec(ctx, `SELECT 1 FROM topic_tags WHERE tenant_id = $1 AND tag_id = ANY($2::uuid[])
		ORDER BY tag_id FOR UPDATE`, tenant, tagIDs); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `DELETE FROM topic_tags t WHERE t.tenant_id = $1 AND t.tag_id = ANY($2::uuid[])
		AND NOT EXISTS (SELECT 1 FROM topic_tag_links l WHERE l.tenant_id = t.tenant_id AND l.tag_id = t.tag_id)`,
		tenant, tagIDs)
	return err
}

// TopicTagLinks implements TopicTagStore: one read, none with no uuid.
func (s *Postgres) TopicTagLinks(ctx context.Context, tenant string, taskIDs []string) (map[string][]TopicTagLink, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	out := map[string][]TopicTagLink{}
	keys := topicTagKeys(taskIDs)
	if len(keys) == 0 {
		return out, nil
	}
	err := s.queryTenant(ctx, tenant, `SELECT l.task_id::text, t.slug, l.added_by, l.added_at FROM topic_tag_links l
		JOIN topic_tags t ON t.tenant_id = l.tenant_id AND t.tag_id = l.tag_id
		WHERE l.tenant_id = $1 AND l.task_id = ANY($2::uuid[]) ORDER BY l.task_id, t.slug`, []any{tenant, keys},
		func(r pgx.Rows) error {
			var task string
			var l TopicTagLink
			err := r.Scan(&task, &l.Slug, &l.AddedBy, &l.AddedAt)
			l.AddedAt = l.AddedAt.UTC()
			out[task] = append(out[task], l)
			return err
		})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// dropTopicTagsTx is DeleteTopic's part (spec 196 2.2): the topics' stamps
// (their locks) and links go, then the tags no topic uses.
func dropTopicTagsTx(ctx context.Context, tx pgx.Tx, tenant string, tasks []string) error {
	if _, err := tx.Exec(ctx, `DELETE FROM topic_tag_stamps WHERE tenant_id = $1 AND task_id = ANY($2::uuid[])`,
		tenant, tasks); err != nil {
		return err
	}
	rows, err := tx.Query(ctx, `DELETE FROM topic_tag_links WHERE tenant_id = $1 AND task_id = ANY($2::uuid[])
		RETURNING tag_id::text`, tenant, tasks)
	if err != nil {
		return err
	}
	gone, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	return pruneTopicTagsTx(ctx, tx, tenant, gone)
}

// queueMergeTopicTags queues MergeTopic's part (spec 196 2.2) into its batch,
// so a merge costs no extra round trip (write_batch_rt_test.go): target B
// keeps all its tags, the free places (10 minus B's) take source A's other
// tags in (added_at, slug) order, the rest are dropped. Each statement runs
// on its own snapshot, in queue order:
//
//  1. B's stamp row, the lock, only when A has a tag
//  2. B takes A's tags into its free places
//  3. A's tags held FOR UPDATE (spec 196 2.3 rule 2)
//  4. A's stamp goes
//  5. A's tags no other topic links are pruned (their A links cascade); its
//     snapshot is taken after 3, so a link an add committed meanwhile counts
//  6. A's remaining links go
func queueMergeTopicTags(b *pgx.Batch, tenant, src, target string, at time.Time) {
	b.Queue(`INSERT INTO topic_tag_stamps (tenant_id, task_id, updated_at)
		SELECT $1, $3::uuid, $4 WHERE EXISTS (SELECT 1 FROM topic_tag_links WHERE tenant_id = $1 AND task_id = $2::uuid)
		ON CONFLICT (tenant_id, task_id) DO UPDATE SET updated_at = EXCLUDED.updated_at`, tenant, src, target, at.UTC())
	b.Queue(`INSERT INTO topic_tag_links (tenant_id, task_id, tag_id, added_by, added_at)
		SELECT a.tenant_id, $3::uuid, a.tag_id, a.added_by, a.added_at FROM topic_tag_links a
		JOIN topic_tags t ON t.tenant_id = a.tenant_id AND t.tag_id = a.tag_id
		WHERE a.tenant_id = $1 AND a.task_id = $2::uuid AND NOT EXISTS (SELECT 1 FROM topic_tag_links b
			WHERE b.tenant_id = a.tenant_id AND b.task_id = $3::uuid AND b.tag_id = a.tag_id)
		ORDER BY a.added_at, t.slug
		LIMIT greatest(0, $4 - (SELECT count(*) FROM topic_tag_links WHERE tenant_id = $1 AND task_id = $3::uuid))`,
		tenant, src, target, TopicTagsMax)
	b.Queue(`SELECT 1 FROM topic_tags WHERE tenant_id = $1
		AND tag_id IN (SELECT tag_id FROM topic_tag_links WHERE tenant_id = $1 AND task_id = $2::uuid)
		ORDER BY tag_id FOR UPDATE`, tenant, src)
	b.Queue(`DELETE FROM topic_tag_stamps WHERE tenant_id = $1 AND task_id = $2::uuid`, tenant, src)
	b.Queue(`DELETE FROM topic_tags t WHERE t.tenant_id = $1
		AND t.tag_id IN (SELECT tag_id FROM topic_tag_links WHERE tenant_id = $1 AND task_id = $2::uuid)
		AND NOT EXISTS (SELECT 1 FROM topic_tag_links l WHERE l.tenant_id = t.tenant_id AND l.tag_id = t.tag_id AND l.task_id <> $2::uuid)`,
		tenant, src)
	b.Queue(`DELETE FROM topic_tag_links WHERE tenant_id = $1 AND task_id = $2::uuid`, tenant, src)
}

// ---- spec 169 channel move and copy -------------------------------------------

// topic_tag_links is Rewritten (channelmove/catalogue.go): a link names a
// <SRC> tag_id that <DST> may not have, or has under another slug, so no
// link is carried as it is. The topic_tag_stamps part (a Moved table) does
// the slug remap: each linked slug of the set is made in <DST> (its own
// tag_id kept when it has the slug), the links are written there with it,
// and on a move the <SRC> links go and the tags no topic uses are pruned.
func init() {
	mvParts["topic_tag_stamps"] = mvPart{copy: mvCopyTopicTags, del: mvDeleteTopicTags}
}

func mvCopyTopicTags(m *pgMove, t MoveTable) error {
	if err := m.copyDefault(t); err != nil {
		return err
	}
	tasks := mpNonNil(m.b.Tasks)
	n, err := remapTopicTagsTx(m.ctx, m.tx, m.req.Src, m.req.Dst, tasks, tasks)
	m.res.Copied["topic_tag_links"] = n
	return err
}

func mvDeleteTopicTags(m *pgMove, t MoveTable) error {
	if err := m.deleteDefault(t); err != nil {
		return err
	}
	rows, err := m.tx.Query(m.ctx, `DELETE FROM topic_tag_links WHERE tenant_id = $1 AND task_id = ANY($2::uuid[])
		RETURNING tag_id::text`, m.req.Src, mpNonNil(m.b.Tasks))
	if err != nil {
		return err
	}
	gone, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	m.res.Deleted["topic_tag_links"] = len(gone)
	return pruneTopicTagsTx(m.ctx, m.tx, m.req.Src, gone)
}

// remapTopicTagsTx writes the links of the <SRC> topics olds under <DST> as
// the topics news (parallel; a move passes the same ids), by slug. Each slug
// <DST> lacks gets a new tag_id (internal/uid, spec 196 2.1). It answers the
// links written. Runs asOperator (both workspaces).
func remapTopicTagsTx(ctx context.Context, tx pgx.Tx, src, dst string, olds, news []string) (int, error) {
	rows, err := tx.Query(ctx, `SELECT DISTINCT t.slug, t.created_by FROM topic_tag_links l
		JOIN topic_tags t ON t.tenant_id = l.tenant_id AND t.tag_id = l.tag_id
		WHERE l.tenant_id = $1 AND l.task_id = ANY($2::uuid[]) ORDER BY t.slug`, src, olds)
	if err != nil {
		return 0, err
	}
	type made struct{ slug, by string }
	tags, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (made, error) {
		var x made
		return x, r.Scan(&x.slug, &x.by)
	})
	if err != nil || len(tags) == 0 {
		return 0, err
	}
	slugs, bys, ids := make([]string, len(tags)), make([]string, len(tags)), make([]string, len(tags))
	for i, x := range tags {
		slugs[i], bys[i], ids[i] = x.slug, x.by, uuid.New()
	}
	if _, err = tx.Exec(ctx, `INSERT INTO topic_tags (tenant_id, tag_id, slug, created_by)
		SELECT $1, id, slug, by FROM unnest($2::uuid[], $3::text[], $4::text[]) AS x (id, slug, by)
		ON CONFLICT (tenant_id, slug) DO NOTHING`, dst, ids, slugs, bys); err != nil {
		return 0, err
	}
	tag, err := tx.Exec(ctx, `INSERT INTO topic_tag_links (tenant_id, task_id, tag_id, added_by, added_at)
		SELECT $2, mp.new, d.tag_id, l.added_by, l.added_at FROM topic_tag_links l
		JOIN unnest($3::uuid[], $4::uuid[]) AS mp (old, new) ON mp.old = l.task_id
		JOIN topic_tags s ON s.tenant_id = l.tenant_id AND s.tag_id = l.tag_id
		JOIN topic_tags d ON d.tenant_id = $2 AND d.slug = s.slug
		WHERE l.tenant_id = $1
		ON CONFLICT DO NOTHING`, src, dst, olds, news)
	return int(tag.RowsAffected()), err
}
