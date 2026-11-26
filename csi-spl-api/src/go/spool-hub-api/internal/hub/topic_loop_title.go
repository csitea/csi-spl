package hub

import (
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The loop's title (spec 182 v0.11, HUM-10 t1 6e8c1cdb msgs 543a5bde,
// 7f3ebb17, 9e3161d9, a04bba37; SPL-6581): its one trigger's label with
// its parameter, first letter upper case ("Before each agent reply",
// "Every 30 minutes"). The WUI shows it on the loop's row (utils
// topic-loops.mjs loopTitle, from the locale files); the fire line names
// it in English, the words of en.json feed.topic_loops, which
// TestTopicLoopTitleParity holds equal. A loop stored with several
// triggers before v0.11 names them all, comma separated.

// loopTriggerLabel is en.json feed.topic_loops.trigger.<key>.
var loopTriggerLabel = map[string]string{
	store.LoopAfterAgentReply:    "After each agent reply",
	store.LoopBeforeAgentReply:   "Before each agent reply",
	store.LoopAfterHumanReply:    "After each human reply",
	store.LoopEveryHour:          "Every hour",
	store.LoopEveryNMinutes:      "Every n minutes",
	store.LoopPostHasKeyword:     "A post that contains",
	store.LoopPostHasFile:        "A post with a file attached",
	store.LoopBlockerPosted:      "A blocker posted in the topic",
	store.LoopNoReplyAfterHuman:  "No reply for n minutes after a human post",
	store.LoopIssueStatusChanged: "An issue linked to the topic changes status",
	store.LoopDailyAt:            "Every day at",
}

// loopParamLabel is en.json feed.topic_loops.<key> of a trigger with a
// field: every_n, keyword_row, idle_row, daily_row.
var loopParamLabel = map[string]string{
	"every_n":     "every {n} minutes",
	"keyword_row": "a post that contains “{keyword}”",
	"idle_row":    "no reply for {n} minutes after a human post",
	"daily_row":   "every day at {time} ({tz})",
}

// loopTitle is l's title, "" when it has no known trigger.
func loopTitle(l store.TopicLoop) string {
	parts := make([]string, 0, len(l.Triggers))
	for _, k := range store.TopicLoopTriggers {
		if l.Has(k) {
			parts = append(parts, loopTriggerTitle(l, k))
		}
	}
	if len(parts) == 0 {
		return ""
	}
	r, n := utf8.DecodeRuneInString(parts[0])
	parts[0] = string(unicode.ToUpper(r)) + parts[0][n:]
	return strings.Join(parts, ", ")
}

// loopTriggerTitle is one trigger's label, its field filled in.
func loopTriggerTitle(l store.TopicLoop, k string) string {
	fill := func(key string, kv ...string) string {
		return strings.NewReplacer(kv...).Replace(loopParamLabel[key])
	}
	switch k {
	case store.LoopEveryNMinutes:
		return fill("every_n", "{n}", strconv.Itoa(l.IntervalMin))
	case store.LoopPostHasKeyword:
		return fill("keyword_row", "{keyword}", l.Keyword)
	case store.LoopNoReplyAfterHuman:
		return fill("idle_row", "{n}", strconv.Itoa(l.IdleMin))
	case store.LoopDailyAt:
		tz := l.DailyTZ
		if tz == "" {
			tz = "UTC"
		}
		return fill("daily_row", "{time}", l.DailyAt, "{tz}", tz)
	}
	return loopTriggerLabel[k]
}
