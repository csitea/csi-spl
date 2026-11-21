package store

import (
	"context"
	"slices"
	"testing"
	"time"
)

// spec 033 K.2 (T022): is:bug finds the bug message and not the note beside
// it, on memory and Postgres (search_postgres.go m.kind = $n, rdb 0300).
func TestSearchIsBug(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			ta := newTenant(t, s)
			word := zqWord()
			put := func(kind string) Message {
				m := msgFor(ta, uuid4(), "box-b", now.Add(-time.Minute), now.Add(-time.Minute), "env-"+uuid4())
				m.Kind, m.Body = kind, "kinds "+word
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			bug := put("bug")
			put("note")
			rs, err := s.(Searcher).SearchMessages(ctx, ta, sq(t, "is:bug "+word, now))
			if err != nil {
				t.Fatal(err)
			}
			if got := msgIDs(rs); !slices.Equal(got, []string{bug.MsgID}) {
				t.Fatalf("is:bug: %v, want [%s]", got, bug.MsgID)
			}
		})
	}
}
