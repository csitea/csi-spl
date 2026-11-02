// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"fmt"
	"strings"
)

// The Qto part of P4 (spec 169 row T5c, F7, 5.1): a doc keeps its id, and so
// do its items, node, ACL rows and rev log, all under <DST>. Those keys are
// hub-wide, so the rows leave <SRC> first:
//
//  1. every row is stashed;
//  2. the workspace_doc rows are deleted, and the FK cascades take the items,
//     rev log, node and ACL with them. The cascade is the only way to remove
//     a rev log row: the runtime login has no DELETE on it (rdb 0157);
//  3. <SRC>'s tree closes the gap each doc node left;
//  4. the rows are inserted under <DST>, each doc node appended to a folder
//     named for the channel (the same shift as any other create).
//
// The commit checks both trees (workspace_doc_node_ns) and the root counters
// follow by their own triggers.
func init() {
	mvParts["workspace_doc"] = mvPart{copy: mvCopyDocs, del: mvNothing}
	for _, t := range []string{"workspace_doc_item", "workspace_doc_node", "workspace_doc_acl", "workspace_doc_rev_log"} {
		mvParts[t] = mvPart{copy: mvNothing, del: mvNothing}
	}
}

// mvDocNode is one doc node of <SRC>'s tree.
type mvDocNode struct {
	id, doc, createdBy string
	lft                int
}

func mvCopyDocs(m *pgMove, _ MoveTable) error {
	if len(m.b.Docs) == 0 {
		return nil
	}
	nodes, err := m.srcDocNodes()
	if err != nil {
		return err
	}
	docs := m.b.Docs
	stashes := map[string]string{}
	lists := map[string]string{}
	for _, t := range []struct{ table, pred string }{
		{"workspace_doc", `id = ANY($2::uuid[])`},
		{"workspace_doc_item", `doc_id = ANY($2::uuid[])`},
		{"workspace_doc_rev_log", `doc_id = ANY($2::uuid[])`},
		{"workspace_doc_acl", `node_id = ANY($2::uuid[])`},
	} {
		arg := docs
		if t.table == "workspace_doc_acl" {
			arg = mpNonNil(m.b.Nodes)
		}
		stashes[t.table], lists[t.table], err = m.stash(t.table, t.pred, m.req.Src, arg)
		if err != nil {
			return err
		}
	}
	if err := m.dropSrcDocs(nodes); err != nil {
		return err
	}
	for _, t := range []string{"workspace_doc", "workspace_doc_item", "workspace_doc_rev_log"} {
		if m.req.skipCopy[t] {
			continue
		}
		n, err := m.exec(`INSERT INTO `+t+` (tenant_id, `+lists[t]+`) SELECT $1, `+lists[t]+` FROM `+stashes[t], m.req.Dst)
		if err != nil {
			return fmt.Errorf("%s: %w", t, err)
		}
		m.res.Copied[t] = n
	}
	if err := m.placeDocNodes(nodes); err != nil {
		return err
	}
	n, err := m.exec(`INSERT INTO workspace_doc_acl (tenant_id, `+lists["workspace_doc_acl"]+`)
		SELECT $1, `+lists["workspace_doc_acl"]+` FROM `+stashes["workspace_doc_acl"], m.req.Dst)
	m.res.Copied["workspace_doc_acl"] = n
	return err
}

func (m *pgMove) srcDocNodes() ([]mvDocNode, error) {
	var out []mvDocNode
	rows, err := m.tx.Query(m.ctx, `SELECT id::text, doc_id::text, created_by, lft FROM workspace_doc_node
		WHERE tenant_id = $1 AND doc_id = ANY($2::uuid[]) ORDER BY lft DESC`, m.req.Src, m.b.Docs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var n mvDocNode
		if err := rows.Scan(&n.id, &n.doc, &n.createdBy, &n.lft); err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

// dropSrcDocs is steps 2 and 3. nodes come right to left, so one node's shift
// never moves the bound of the next.
func (m *pgMove) dropSrcDocs(nodes []mvDocNode) error {
	if _, err := docNodeLockRoot(m.ctx, m.tx, m.req.Src); err != nil {
		return err
	}
	n, err := m.exec(`DELETE FROM workspace_doc WHERE tenant_id = $1 AND id = ANY($2::uuid[])`, m.req.Src, m.b.Docs)
	if err != nil {
		return err
	}
	m.res.Deleted["workspace_doc"] = n
	for _, node := range nodes {
		if _, err := m.exec(`UPDATE workspace_doc_node
			SET lft = lft - CASE WHEN lft > $2 THEN 2 ELSE 0 END, rgt = rgt - 2
			WHERE tenant_id = $1 AND rgt > $2`, m.req.Src, node.lft); err != nil {
			return err
		}
	}
	return nil
}

// placeDocNodes is step 4: under the folder named for the channel, in <DST>'s
// tree, left to right as they stood, each node keeping its id.
func (m *pgMove) placeDocNodes(nodes []mvDocNode) error {
	if len(nodes) == 0 {
		return nil
	}
	root, err := docNodeLockRoot(m.ctx, m.tx, m.req.Dst)
	if err != nil {
		return err
	}
	folder, err := m.channelFolder(root)
	if err != nil {
		return err
	}
	for i := len(nodes) - 1; i >= 0; i-- {
		parent, err := docNodeParentOf(m.ctx, m.tx, m.req.Dst, root, folder)
		if err != nil {
			return err
		}
		id, err := docNodeAppend(m.ctx, m.tx, m.req.Dst, parent, docNodeNew{kind: "doc", doc: nodes[i].doc, actor: nodes[i].createdBy})
		if err != nil {
			return err
		}
		if _, err := m.exec(`UPDATE workspace_doc_node SET id = $2::uuid WHERE tenant_id = $1 AND id = $3::uuid`, m.req.Dst, nodes[i].id, id); err != nil {
			return err
		}
	}
	m.res.Copied["workspace_doc_node"] = len(nodes)
	return nil
}

// channelFolder finds or creates the folder named for the channel directly
// under <DST>'s root (the sibling name index is case-insensitive).
func (m *pgMove) channelFolder(root string) (string, error) {
	var ids []string
	rows, err := m.tx.Query(m.ctx, `SELECT id::text FROM workspace_doc_node
		WHERE tenant_id = $1 AND parent_id = $2::uuid AND kind = 'folder' AND lower(name) = lower($3)`, m.req.Dst, root, m.req.Channel)
	if err != nil {
		return "", err
	}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return "", err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return "", err
	}
	if len(ids) > 0 {
		return ids[0], nil
	}
	parent, err := docNodeParentOf(m.ctx, m.tx, m.req.Dst, root, "")
	if err != nil {
		return "", err
	}
	return docNodeAppend(m.ctx, m.tx, m.req.Dst, parent, docNodeNew{kind: "folder", name: strings.TrimSpace(m.req.Channel), actor: m.req.StartedBy})
}
