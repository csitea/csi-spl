// SPDX-License-Identifier: AGPL-3.0-only

package channelmove

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Spec 169 5.4 in plain `go test`: ReadMentions' loops on a fake Querier. The
// SQL itself is read on Postgres by TestMentionsPostgres.

// mentionsDB answers the two mention reads with fixed rows.
type mentionsDB struct {
	posts, items [][]any
	fail         string // a statement containing this fails
	args         []any
}

func (f *mentionsDB) Query(_ context.Context, sql string, args ...any) (pgx.Rows, error) {
	f.args = append(f.args, args...)
	if f.fail != "" && strings.Contains(sql, f.fail) {
		return nil, errors.New("fake: refused")
	}
	switch {
	case strings.Contains(sql, "FROM messages"):
		return &fakeRows{rows: f.posts}, nil
	case strings.Contains(sql, "FROM workspace_doc_item"):
		return &fakeRows{rows: f.items}, nil
	}
	return nil, fmt.Errorf("fake: unexpected %s", sql)
}

func TestReadMentionsCountsByClass(t *testing.T) {
	db := &mentionsDB{
		posts: [][]any{{"m1", true, true}, {"m2", false, false}},
		items: [][]any{{"d1", "i1", true}},
	}
	m, err := ReadMentions(context.Background(), db, ProofSet{Src: "s", MoveID: "mv"})
	if err != nil {
		t.Fatal(err)
	}
	if m.UUIDWithRedirect != 2 || m.NameOrChannelID != 1 || len(m.Rows) != 3 {
		t.Fatalf("counts: %+v", m)
	}
	if got := fmt.Sprint(m.Known); got != "map[scan messages.body:2 scan messages.msg:1 scan workspace_doc_item.body:1]" {
		t.Errorf("Known = %s", got)
	}
	want := []Mention{{Kind: "post", MsgID: "m1", Class: MentionUUID}, {Kind: "post", MsgID: "m2", Class: MentionName},
		{Kind: "qto item", DocID: "d1", ItemID: "i1", Class: MentionUUID}}
	if fmt.Sprint(m.Rows) != fmt.Sprint(want) {
		t.Errorf("Rows = %+v, want %+v", m.Rows, want)
	}
	a, ok := db.args[0].(pgx.NamedArgs)
	if !ok || a["move_id"] != "mv" || a["src"] != "s" {
		t.Errorf("RED CONTROL: the reads are not bound to this move: %v", db.args)
	}
	if !strings.Contains(postMentionSQL(), "r.move_id::text = @move_id::text") || !strings.Contains(itemMentionSQL(), "r.expires_at > now()") {
		t.Error("RED CONTROL: a redirect of another move, or an expired one, would cover a mention")
	}
}

func TestReadMentionsEmptyIsNoRows(t *testing.T) {
	m, err := ReadMentions(context.Background(), &mentionsDB{}, ProofSet{})
	if err != nil || m.Rows == nil || len(m.Rows) != 0 || len(m.Known) != 0 {
		t.Errorf("no mentions: %+v %v", m, err)
	}
}

func TestReadMentionsReturnsEveryReadError(t *testing.T) {
	cases := []struct {
		name string
		db   *mentionsDB
		want string
	}{
		{"posts refused", &mentionsDB{fail: "FROM messages"}, "mentions messages"},
		{"posts scan", &mentionsDB{posts: [][]any{{"m1"}}}, "mentions messages"},
		{"items refused", &mentionsDB{fail: "FROM workspace_doc_item"}, "mentions workspace_doc_item"},
		{"items scan", &mentionsDB{items: [][]any{{"d1"}}}, "mentions workspace_doc_item"},
	}
	for _, c := range cases {
		if _, err := ReadMentions(context.Background(), c.db, ProofSet{}); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v, want %q", c.name, err, c.want)
		}
	}
}

func TestIsMentionProofOnlyTheMentionColumns(t *testing.T) {
	for _, n := range []string{scanPostBody, scanPostMsg, scanItemBody} {
		if !IsMentionProof(n) {
			t.Errorf("%s is a mention column", n)
		}
	}
	for _, n := range []string{"scan messages.title", "scan workspace_doc_item.title", "scan message_revisions.body", ""} {
		if IsMentionProof(n) {
			t.Errorf("RED CONTROL: %q is not a mention column", n)
		}
	}
}

func TestMentionStayingNeedsACatalogueEntry(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("RED CONTROL: a table with no catalogue entry did not panic")
		}
	}()
	mentionStaying("no_such_table")
}
