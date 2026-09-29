package hub

import (
	"encoding/json"
	"fmt"
	"io"
	"testing"
)

// benchRoster builds a representative roster response body (8 boxes, 12 members).
func benchRoster() ([]viewBox, []viewHuman) {
	boxes := make([]viewBox, 0, 8)
	for i := 0; i < 8; i++ {
		boxes = append(boxes, viewBox{BoxID: fmt.Sprintf("box-%d", i), PubKey: "AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleAA==",
			Online: i%2 == 0, Agents: []string{fmt.Sprintf("CLE-%d", i)}})
	}
	humans := make([]viewHuman, 0, 12)
	for i := 0; i < 12; i++ {
		humans = append(humans, viewHuman{HumanID: fmt.Sprintf("HUM-%d", i)})
	}
	return boxes, humans
}

func BenchmarkRosterEncodeMap(b *testing.B) {
	boxes, humans := benchRoster()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = json.NewEncoder(io.Discard).Encode(map[string]any{"boxes": boxes, "humans": humans})
	}
}

func BenchmarkRosterEncodeStruct(b *testing.B) {
	boxes, humans := benchRoster()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = json.NewEncoder(io.Discard).Encode(rosterBody{Boxes: boxes, Humans: humans})
	}
}
