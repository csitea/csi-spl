package main

import (
	"strings"
	"testing"
)

// spec 102 T020: the index a seed carries lists titles and one line, never a
// body. Control: a lesson with no line still prints its title.
func TestFormatMemoryIndex(t *testing.T) {
	got := formatMemoryIndex([]memoryLesson{
		{Title: "Disk full", Line: "report df -h", Body: "report df -h\n\nnever prune caches"},
		{Title: "Push race", Body: "secret body"},
	})
	if got != "- Disk full: report df -h\n- Push race\n" {
		t.Fatalf("index:\n%s", got)
	}
	if strings.Contains(got, "never prune") || strings.Contains(got, "secret body") {
		t.Fatalf("the index carries a body:\n%s", got)
	}
	if formatMemoryIndex(nil) != "" {
		t.Fatal("an empty memory prints lines")
	}
}
