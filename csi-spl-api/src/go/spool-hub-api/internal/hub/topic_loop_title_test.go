package hub

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 182 v0.11 (SPL-6581): the fire line's title is the WUI's English
// title. Every trigger has its label, and each label is en.json's
// feed.topic_loops word for word, so the hub and the dialog name a loop
// alike (utils/topic-loops.mjs loopTitle).
func TestTopicLoopTitleParity(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "..", "csi-spl-wui", "i18n", "locales", "en.json"))
	if err != nil {
		t.Skipf("no WUI tree next to the hub (%v): the parity is checked in the monorepo", err)
	}
	var en struct {
		Feed struct {
			TopicLoops map[string]json.RawMessage `json:"topic_loops"`
		} `json:"feed"`
	}
	if err := json.Unmarshal(raw, &en); err != nil {
		t.Fatal(err)
	}
	var triggers map[string]string
	if err := json.Unmarshal(en.Feed.TopicLoops["trigger"], &triggers); err != nil {
		t.Fatal(err)
	}
	for _, k := range store.TopicLoopTriggers {
		if loopTriggerLabel[k] == "" || loopTriggerLabel[k] != triggers[k] {
			t.Errorf("trigger %s: hub %q, en.json %q", k, loopTriggerLabel[k], triggers[k])
		}
	}
	if len(loopTriggerLabel) != len(store.TopicLoopTriggers) {
		t.Errorf("%d hub labels for %d triggers", len(loopTriggerLabel), len(store.TopicLoopTriggers))
	}
	for key, hub := range loopParamLabel {
		var word string
		if err := json.Unmarshal(en.Feed.TopicLoops[key], &word); err != nil || word != hub {
			t.Errorf("%s: hub %q, en.json %q (%v)", key, hub, word, err)
		}
	}
}

// Each trigger gives its title, with its field; several name them all.
func TestTopicLoopTitle(t *testing.T) {
	want := map[string]string{
		store.LoopAfterAgentReply:    "After each agent reply",
		store.LoopBeforeAgentReply:   "Before each agent reply",
		store.LoopAfterHumanReply:    "After each human reply",
		store.LoopEveryHour:          "Every hour",
		store.LoopEveryNMinutes:      "Every 30 minutes",
		store.LoopPostHasKeyword:     "A post that contains “deploy”",
		store.LoopPostHasFile:        "A post with a file attached",
		store.LoopBlockerPosted:      "A blocker posted in the topic",
		store.LoopNoReplyAfterHuman:  "No reply for 15 minutes after a human post",
		store.LoopIssueStatusChanged: "An issue linked to the topic changes status",
		store.LoopDailyAt:            "Every day at 09:00 (Europe/Amsterdam)",
	}
	base := store.TopicLoop{IntervalMin: 30, Keyword: "deploy", IdleMin: 15, DailyAt: "09:00", DailyTZ: "Europe/Amsterdam"}
	for _, k := range store.TopicLoopTriggers {
		l := base
		l.Triggers = []string{k}
		if got := loopTitle(l); got != want[k] {
			t.Errorf("%s: %q, want %q", k, got, want[k])
		}
	}
	if len(want) != len(store.TopicLoopTriggers) {
		t.Errorf("a trigger has no title case")
	}
	several := store.TopicLoop{Triggers: slices.Sorted(slices.Values([]string{store.LoopEveryNMinutes, store.LoopBlockerPosted})), IntervalMin: 10}
	if got := loopTitle(several); got != "Every 10 minutes, A blocker posted in the topic" { // as the WUI's loopTitle
		t.Errorf("several: %q", got)
	}
	if got := loopTitle(store.TopicLoop{}); got != "" {
		t.Errorf("none: %q", got)
	}
}
