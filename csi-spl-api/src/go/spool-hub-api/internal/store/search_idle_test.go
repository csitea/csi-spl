package store

import (
	"context"
	"slices"
	"testing"
	"time"
)

// Grammar 1.8 (spec 187 row S2): idle: and changed: on topics, in the
// Postgres compile (topicLeaf) and in memory (MatchTopic), the same answer.
// CONTROLS: the topic whose last message is 29 days old is not idle:30d, the
// one silent 31 days is; changed:7d is the inverse; another tenant's silent
// topic never appears. RED (spec 187 S2): compile idle: as after: and the
// 31-day topic is not matched.
func TestSearchTopicsIdleChanged(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			se := s.(Searcher)
			ta, tb := newTenant(t, s), newTenant(t, s)
			old, recent, fresh, otherOld := uuid4(), uuid4(), uuid4(), uuid4()
			mk := func(tenant, task string, ago time.Duration) {
				t.Helper()
				m := msgFor(tenant, task, "box-b", now.Add(-ago), now.Add(-ago), "env-"+uuid4())
				m.Body, m.Channel, m.ExpiresAt = "status of the work", ChannelTasks, now.Add(time.Hour)
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			day := 24 * time.Hour
			mk(ta, old, 40*day)
			mk(ta, old, 31*day) // its last message: 31 days ago
			mk(ta, recent, 35*day)
			mk(ta, recent, 29*day) // a message 29 days ago: not idle for 30
			mk(ta, fresh, 2*day)
			mk(tb, otherOld, 31*day) // CONTROL: other tenant
			ids := func(q string) []string {
				t.Helper()
				th, err := se.SearchTopics(ctx, ta, sq(t, q, now))
				if err != nil {
					t.Fatalf("%q: %v", q, err)
				}
				var out []string
				for _, r := range th {
					out = append(out, r.TaskID)
				}
				return out
			}
			for q, want := range map[string][]string{
				"idle:30d":             {old},
				"type:topic idle:30d":  {old},
				"changed:30d":          {fresh, recent},
				"changed:7d":           {fresh},
				"idle:7d":              {recent, old},
				"-changed:7d":          {recent, old},
				"status idle:30d":      {old},
				"idle:30d OR idle:20d": {recent, old},
			} {
				if got := ids(q); !slices.Equal(got, want) {
					t.Errorf("%q: %v, want %v (old %s, 29d %s, 2d %s)", q, got, want, old, recent, fresh)
				}
			}
		})
	}
}
