// SPDX-License-Identifier: AGPL-3.0-only

package channelmove

// The mentions a move leaves in <SRC> (spec 169 section 5.4, Q4 = A: leave them
// and list them). A staying post or a staying Qto item that links or names the
// moved channel is a known hit of the free-text scan, listed by id and counted
// by class, never with its text. Every other hit still fails P7, and
// message_revisions is not read here: plan does not list it either.

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// The classes of a mention. A row with a set UUID and a name counts as the first.
const (
	MentionUUID = "uuid with redirect"
	MentionName = "name or channel id"
)

// Mention is one known row: a post by msg id, a Qto item by doc and item id.
type Mention struct {
	Kind   string `json:"kind"` // post, qto item
	MsgID  string `json:"msg_id,omitempty"`
	DocID  string `json:"doc_id,omitempty"`
	ItemID string `json:"item_id,omitempty"`
	Class  string `json:"class"`
}

// Mentions is P7's list. Known is what Scan may find, by proof name.
type Mentions struct {
	UUIDWithRedirect int64            `json:"uuid_with_redirect"`
	NameOrChannelID  int64            `json:"name_or_channel_id"`
	Rows             []Mention        `json:"rows"`
	Known            map[string]int64 `json:"-"`
}

const (
	scanPostBody = "scan messages.body"
	scanPostMsg  = "scan messages.msg"
	scanItemBody = "scan workspace_doc_item.body"
)

// IsMentionProof says whether a proof name is a column a mention may hit (5.4).
func IsMentionProof(name string) bool {
	return name == scanPostBody || name == scanPostMsg || name == scanItemBody
}

func (m *Mentions) add(row Mention, hasUUID bool) {
	row.Class = MentionName
	m.NameOrChannelID++
	if hasUUID {
		row.Class = MentionUUID
		m.NameOrChannelID--
		m.UUIDWithRedirect++
	}
	m.Rows = append(m.Rows, row)
}

// mentionUUIDs are the set's ids in a row's body, lower case.
const mentionUUIDs = `ARRAY(SELECT DISTINCT lower(x.a[1]) FROM regexp_matches(body, @uuid_rx::text, 'gi') AS x(a)
	WHERE lower(x.a[1]) = ANY(@uuid_texts::text[])) AS ids`

// mentionCovered: every set id in the row has a live redirect row of this move.
const mentionCovered = `NOT EXISTS (SELECT 1 FROM unnest(ids) AS u(id) WHERE NOT EXISTS (SELECT 1 FROM channel_move_redirects r
	WHERE r.src_tenant_id = @src AND r.kind IN ('task', 'msg') AND r.old_ref = u.id
	AND r.move_id::text = @move_id::text AND r.expires_at > now()))`

// mentionStaying is a row of table the catalogue's Set does not find: the same
// rows as plan's planStayingSQL for a post and its doc filter for a Qto item.
func mentionStaying(table string) string {
	e, ok := Lookup(table)
	if !ok {
		panic("channelmove: no catalogue entry for " + table)
	}
	return "tenant_id = @src AND NOT coalesce((" + Typed(e.Set) + "), false) AND " + textMatch("body")
}

// postMentionSQL also answers whether the row's msg is explained by the post:
// the hit in msg is the copy of this body, and msg holds no other.
func postMentionSQL() string {
	return `SELECT msg_id::text, cardinality(ids) > 0, msg_hit AND msg_body = body AND NOT msg_rest_hit FROM (
		SELECT msg_id, body, ` + mentionUUIDs + `, ` + textMatch("msg::text") + ` AS msg_hit, msg->>'body' AS msg_body,
			` + textMatch("(msg - 'body')::text") + ` AS msg_rest_hit
		FROM messages WHERE ` + mentionStaying("messages") + `) h WHERE ` + mentionCovered + ` ORDER BY msg_id`
}

func itemMentionSQL() string {
	return `SELECT doc_id::text, id::text, cardinality(ids) > 0 FROM (
		SELECT doc_id, id, ` + mentionUUIDs + ` FROM workspace_doc_item WHERE ` + mentionStaying("workspace_doc_item") +
		`) h WHERE ` + mentionCovered + ` ORDER BY doc_id, id`
}

// ReadMentions lists the known rows. Read it in the snapshot Scan reads: Scan's
// count is compared with these, so they must see the same rows.
func ReadMentions(ctx context.Context, q Querier, s ProofSet) (Mentions, error) {
	m := Mentions{Rows: []Mention{}, Known: map[string]int64{}}
	var msgID string
	var hasUUID, msgCopy bool
	rows, err := q.Query(ctx, postMentionSQL(), s.args())
	if err != nil {
		return m, fmt.Errorf("mentions messages: %w", err)
	}
	if _, err = pgx.ForEachRow(rows, []any{&msgID, &hasUUID, &msgCopy}, func() error {
		m.add(Mention{Kind: "post", MsgID: msgID}, hasUUID)
		m.Known[scanPostBody]++
		if msgCopy {
			m.Known[scanPostMsg]++
		}
		return nil
	}); err != nil {
		return m, fmt.Errorf("mentions messages: %w", err)
	}
	var docID, itemID string
	rows, err = q.Query(ctx, itemMentionSQL(), s.args())
	if err != nil {
		return m, fmt.Errorf("mentions workspace_doc_item: %w", err)
	}
	if _, err = pgx.ForEachRow(rows, []any{&docID, &itemID, &hasUUID}, func() error {
		m.add(Mention{Kind: "qto item", DocID: docID, ItemID: itemID}, hasUUID)
		m.Known[scanItemBody]++
		return nil
	}); err != nil {
		return m, fmt.Errorf("mentions workspace_doc_item: %w", err)
	}
	return m, nil
}
