package hub

import (
	"encoding/json"
	"fmt"
	"io"
	"testing"
)

// benchTopics builds a representative GET /v1/view/topics page (30 topics).
func benchTopics() []viewTopic {
	out := make([]viewTopic, 0, 30)
	for i := 0; i < 30; i++ {
		ch := "tasks"
		out = append(out, viewTopic{
			TaskID: fmt.Sprintf("00000000-0000-4000-8000-%012d", i), Channel: &ch,
			FirstTS: "2026-09-29T10:00:00Z", LastTS: "2026-09-29T10:05:00Z", Count: 3 + i%5,
			Kinds: map[string]int{"msg": 3}, Participants: []string{"CLE-1", "HUM-2"},
			Subject: fmt.Sprintf("topic %d subject line", i),
		})
	}
	return out
}

func BenchmarkTopicsEncodeMap(b *testing.B) {
	out := benchTopics()
	next := "cursor"
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = json.NewEncoder(io.Discard).Encode(map[string]any{"topics": out, "next": &next})
	}
}

func BenchmarkTopicsEncodeStruct(b *testing.B) {
	out := benchTopics()
	next := "cursor"
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = json.NewEncoder(io.Discard).Encode(topicsBody{Topics: out, Next: &next})
	}
}
