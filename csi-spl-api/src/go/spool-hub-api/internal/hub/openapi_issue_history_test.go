package hub_test

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// openapi.json names every event the History tab returns (SPL-6507, R7 N1 of
// SPL-6480): a store.IssueEvent* value that the reference does not list
// fails here.
func TestOpenAPIIssueHistoryEvents(t *testing.T) {
	var doc struct {
		Paths map[string]map[string]struct {
			Responses map[string]struct {
				Content map[string]struct {
					Schema struct {
						Properties map[string]struct {
							Items struct {
								Properties map[string]struct {
									Description string `json:"description"`
								} `json:"properties"`
							} `json:"items"`
						} `json:"properties"`
					} `json:"schema"`
				} `json:"content"`
			} `json:"responses"`
		} `json:"paths"`
	}
	if err := json.Unmarshal(openapiJSON, &doc); err != nil {
		t.Fatal(err)
	}
	ev := doc.Paths["/v1/view/issues/{ref}/history"]["get"].Responses["200"].
		Content["application/json"].Schema.Properties["events"].Items.Properties["event"]
	listed := strings.Split(ev.Description, ", ")
	for _, want := range []string{
		store.IssueEventCreated, store.IssueEventChanged, store.IssueEventCommented,
		store.IssueEventCommentEdited, store.IssueEventDeleted, store.IssueEventRestored,
		store.IssueEventArchived, store.IssueEventUnarchived,
	} {
		if !slices.Contains(listed, want) {
			t.Errorf("openapi.json history event description %q does not list %q", ev.Description, want)
		}
	}
}
