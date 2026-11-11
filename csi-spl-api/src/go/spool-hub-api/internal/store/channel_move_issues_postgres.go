// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"fmt"
	"strings"
)

// The issues part of P4 (spec 169 row T5b, F6, 5.1): issue numbers are per
// workspace, so each moved issue gets the next number of <DST>'s counter and
// <DST>'s prefix. Its events, opens and discussions follow under the new
// number, and the first event keeps the old key (W4, C12). A spec_sync_map
// row a staying issue or doc also needs stopped the move in plan (5.5).
func init() {
	mvParts["issues"] = mvPart{copy: mvCopyIssues}
	mvParts["issue_events"] = mvPart{copy: mvNothing}
	mvParts["issue_opens"] = mvPart{copy: mvNothing}
	mvParts["issue_discussions"] = mvPart{copy: mvNothing}
	mvParts["issue_discussion_closes"] = mvPart{copy: mvNothing}
	mvParts["spec_sync_map"] = mvPart{copy: mvCopySpecSync, del: mvDeleteSpecSync}
	mvPrepare = append(mvPrepare, mvStashSpecSync)
}

// mvIssueMap is the old number -> new number join, as SQL over $3 and $4.
const mvIssueMap = `unnest($3::int[], $4::int[]) AS mp (old, new)`

func mvCopyIssues(m *pgMove, _ MoveTable) error {
	if len(m.b.Numbers) == 0 {
		return nil
	}
	if err := m.mvRenumber(); err != nil {
		return err
	}
	steps := []func() error{m.copyIssueLabels, m.insertIssues, m.copyIssueEvents, m.copyIssueChildren, m.rewriteIssueRefs}
	for _, step := range steps {
		if err := step(); err != nil {
			return err
		}
	}
	olds, news := m.oldNewKeys()
	for i, o := range olds {
		m.res.NewKeys[o] = news[i]
	}
	return m.markFirstEvents()
}

// mvRenumber takes len(numbers) numbers from <DST>'s counter, in the order of
// the old numbers, and keeps <DST>'s prefix.
func (m *pgMove) mvRenumber() error {
	var last int
	n := len(m.b.Numbers)
	err := m.tx.QueryRow(m.ctx, `INSERT INTO issue_counters (tenant_id, last_number) VALUES ($1, $2)
		ON CONFLICT (tenant_id) DO UPDATE SET last_number = issue_counters.last_number + EXCLUDED.last_number
		RETURNING prefix, last_number`, m.req.Dst, n).Scan(&m.dstPrefix, &last)
	if err != nil {
		return err
	}
	m.oldNums, m.newNums = m.b.Numbers, make([]int, n)
	for i := range m.newNums {
		m.newNums[i] = last - n + i + 1
	}
	return nil
}

// copyIssueLabels: a moved issue's labels are label_ids, so each missing one
// is created in <DST> with its name and colour. <SRC>'s catalogue is kept.
func (m *pgMove) copyIssueLabels() error {
	_, err := m.exec(`INSERT INTO issue_labels (tenant_id, label_id, name, color, created_by, created_at)
		SELECT $2, label_id, name, color, created_by, created_at FROM issue_labels
		WHERE tenant_id = $1 AND label_id IN (SELECT unnest(labels) FROM issues WHERE tenant_id = $1 AND number = ANY($3::int[]))
		ON CONFLICT DO NOTHING`, m.req.Src, m.req.Dst, m.oldNums)
	return err
}

// issueCols are the issues columns that travel as they are: the two numbers
// are rewritten.
func (m *pgMove) issueCols() (string, error) {
	cols, err := m.columns("issues")
	if err != nil {
		return "", err
	}
	var out []string
	for _, c := range cols {
		if c != `"number"` && c != `"parent_number"` {
			out = append(out, c)
		}
	}
	return strings.Join(out, ", "), nil
}

// insertIssues: parent_number follows its epic through the map (plan refuses
// an epic link that crosses the set's edge).
func (m *pgMove) insertIssues() error {
	list, err := m.issueCols()
	if err != nil {
		return err
	}
	qualified := "i." + strings.ReplaceAll(list, ", ", ", i.")
	n, err := m.exec(`INSERT INTO issues (tenant_id, number, parent_number, `+list+`)
		SELECT $2, mp.new, pp.new, `+qualified+`
		FROM issues i JOIN `+mvIssueMap+` ON mp.old = i.number
		LEFT JOIN unnest($3::int[], $4::int[]) AS pp (old, new) ON pp.old = i.parent_number
		WHERE i.tenant_id = $1`, m.req.Src, m.req.Dst, m.oldNums, m.newNums)
	m.res.Copied["issues"] = n
	return err
}

// copyIssueEvents replaces the 'created' row issue_events_record just wrote
// with the issue's own history, in its order; an issue with none keeps it.
func (m *pgMove) copyIssueEvents() error {
	if !m.req.skipCopy["issue_events"] {
		if _, err := m.exec(`DELETE FROM issue_events d USING `+mvIssueMap+`
			WHERE d.tenant_id = $2 AND d.number = mp.new
				AND EXISTS (SELECT 1 FROM issue_events s WHERE s.tenant_id = $1 AND s.number = mp.old)`,
			m.req.Src, m.req.Dst, m.oldNums, m.newNums); err != nil {
			return err
		}
		n, err := m.exec(`INSERT INTO issue_events (tenant_id, number, at, actor, event, field, old_value, new_value)
			SELECT $2, mp.new, e.at, e.actor, e.event, e.field, e.old_value, e.new_value
			FROM issue_events e JOIN `+mvIssueMap+` ON mp.old = e.number WHERE e.tenant_id = $1 ORDER BY e.id`,
			m.req.Src, m.req.Dst, m.oldNums, m.newNums)
		m.res.Copied["issue_events"] = n
		return err
	}
	return nil
}

func (m *pgMove) copyIssueChildren() error {
	for _, c := range []struct{ table, cols string }{
		{"issue_opens", "member_id, opened_at"},
		{"issue_discussions", "task_id, linked_by, linked_at, origin_tenant"},
		{"issue_discussion_closes", "task_id, op, prev_status, closed_at, closed_by"},
	} {
		if m.req.skipCopy[c.table] {
			continue
		}
		n, err := m.exec(`INSERT INTO `+c.table+` (tenant_id, number, `+c.cols+`)
			SELECT $2, mp.new, `+c.cols+` FROM `+c.table+` x JOIN `+mvIssueMap+` ON mp.old = x.number WHERE x.tenant_id = $1`,
			m.req.Src, m.req.Dst, m.oldNums, m.newNums)
		if err != nil {
			return fmt.Errorf("%s: %w", c.table, err)
		}
		m.res.Copied[c.table] = n
	}
	return nil
}

// oldNewKeys are the two key lists of the renumbering, parallel.
func (m *pgMove) oldNewKeys() ([]string, []string) {
	olds, news := make([]string, len(m.oldNums)), make([]string, len(m.oldNums))
	for i, o := range m.oldNums {
		olds[i], news[i] = planIssueKey(m.plan.prefix, o), planIssueKey(m.dstPrefix, m.newNums[i])
	}
	return olds, news
}

// rewriteIssueRefs: the rows that name a moved issue by key. M11: fleet_lanes
// (its issue_key and, SPL-4620, the origin_issue a lane was placed from) and
// fleet_asks in <SRC> (W4). A moved event's issue_keys go with it.
func (m *pgMove) rewriteIssueRefs() error {
	olds, news := m.oldNewKeys()
	for _, c := range [][2]string{{"fleet_lanes", "issue_key"}, {"fleet_lanes", "origin_issue"}, {"fleet_asks", "issue_key"}} {
		if _, err := m.exec(`UPDATE `+c[0]+` x SET `+c[1]+` = k.n FROM unnest($2::text[], $3::text[]) AS k (o, n)
			WHERE x.tenant_id = $1 AND x.`+c[1]+` = k.o`, m.req.Src, olds, news); err != nil {
			return fmt.Errorf("%s.%s: %w", c[0], c[1], err)
		}
	}
	_, err := m.exec(`UPDATE calendar_events e SET issue_keys = (
			SELECT array_agg(coalesce(k.n, x.key) ORDER BY x.ord)
			FROM unnest(e.issue_keys) WITH ORDINALITY AS x (key, ord)
			LEFT JOIN unnest($2::text[], $3::text[]) AS k (o, n) ON k.o = x.key)
		WHERE e.tenant_id = $1 AND e.event_id = ANY($4::uuid[]) AND e.issue_keys && $2::text[]`,
		m.req.Dst, olds, news, mpNonNil(m.b.Events))
	return err
}

// markFirstEvents writes the old key into each new issue's first event (5.1,
// C12): its new_value, which a 'created' event never uses.
func (m *pgMove) markFirstEvents() error {
	olds, _ := m.oldNewKeys()
	_, err := m.exec(`UPDATE issue_events e SET new_value = 'moved from ' || k.old_key
		FROM unnest($2::int[], $3::text[]) AS k (num, old_key)
		WHERE e.tenant_id = $1 AND e.number = k.num
			AND e.id = (SELECT min(f.id) FROM issue_events f WHERE f.tenant_id = $1 AND f.number = k.num)`,
		m.req.Dst, m.newNums, olds)
	return err
}

// mvStashSpecSync: spec_sync_map's FK to workspace_doc is ON DELETE SET NULL
// (rdb 0208), and the docs part deletes the doc before this table's turn. The
// Set would then miss a row found only by its doc, which would stay in <SRC>
// with its link gone. So the set's rows are read before anything moves.
func mvStashSpecSync(m *pgMove) error {
	for _, t := range m.req.Tables {
		if t.Table != "spec_sync_map" || t.Class != MoveClassMoved {
			continue
		}
		args, at := []any{m.req.Src}, map[string]int{}
		pred := m.plan.mpBound(t.Set, &args, at)
		var err error
		m.syncStash, _, err = m.stash(t.Table, pred, args...)
		return err
	}
	return nil
}

// mvCopySpecSync runs after the docs part (catalogue order): both its FKs need
// their <DST> parents, an issue through the renumbering, a doc under its id.
func mvCopySpecSync(m *pgMove, _ MoveTable) error {
	n, err := m.exec(`INSERT INTO spec_sync_map (tenant_id, spec_path, spec_task_id, issue_number, qto_doc_id, qto_item_id, last_git_sha, last_sync_at, sync_status)
		SELECT $1, x.spec_path, x.spec_task_id, mp.new, x.qto_doc_id, x.qto_item_id, x.last_git_sha, x.last_sync_at, x.sync_status
		FROM `+m.syncStash+` x LEFT JOIN unnest($2::int[], $3::int[]) AS mp (old, new) ON mp.old = x.issue_number`,
		m.req.Dst, mpNonNilInts(m.oldNums), mpNonNilInts(m.newNums))
	m.res.Copied["spec_sync_map"] = n
	return err
}

// mvDeleteSpecSync deletes by the stashed keys: see mvStashSpecSync.
func mvDeleteSpecSync(m *pgMove, _ MoveTable) error {
	n, err := m.exec(`DELETE FROM spec_sync_map s USING `+m.syncStash+` x
		WHERE s.tenant_id = $1 AND s.spec_path = x.spec_path AND s.spec_task_id = x.spec_task_id`, m.req.Src)
	m.res.Deleted["spec_sync_map"] = n
	return err
}
