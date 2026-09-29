package hub

import (
	"encoding/json"
	"sort"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// topicViewOldDedup is the pre-perf topicView (party dedup via a throwaway map
// per topic), identical to the new one except the dedup, so BenchmarkTopicView
// isolates the allocation this change removes.
func topicViewOldDedup(row store.TopicRow) viewTopic {
	v := viewTopic{TaskID: row.TaskID, FirstTS: rfc(row.FirstAt), LastTS: rfc(row.LastAt),
		Count: row.Count, Kinds: map[string]int{}}
	if row.Channel != "" {
		c := row.Channel
		v.Channel = &c
	}
	if row.Parent != "" {
		p := row.Parent
		v.ParentTaskID = &p
	}
	for _, k := range row.Kinds {
		v.Kinds[k]++
	}
	seen := map[string]bool{}
	for _, p := range row.Parties {
		if !seen[p] {
			seen[p] = true
			v.Participants = append(v.Participants, p)
		}
	}
	sort.Strings(v.Participants)
	var first struct {
		Body string `json:"body"`
	}
	if json.Unmarshal(row.FirstMsg, &first) == nil {
		v.Subject = subject(first.Body)
	}
	return v
}

func benchTopicRow() store.TopicRow {
	return store.TopicRow{
		TaskID: "00000000-0000-4000-8000-000000000001", Channel: "tasks",
		FirstAt: time.Unix(1_800_000_000, 0), LastAt: time.Unix(1_800_000_300, 0), Count: 6,
		Kinds:    []string{"msg", "msg", "note", "msg", "note", "msg"},
		Parties:  []string{"CLE-1@box-a", "HUM-2@box-wui", "CLE-1@box-a", "CLE-3@box-b", "HUM-2@box-wui", "CLE-1@box-a"},
		FirstMsg: []byte(`{"body":"first line of the topic subject"}`),
	}
}

func BenchmarkTopicViewMapDedup(b *testing.B) {
	row := benchTopicRow()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = topicViewOldDedup(row)
	}
}

func BenchmarkTopicViewSliceDedup(b *testing.B) {
	row := benchTopicRow()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = topicView(row)
	}
}
