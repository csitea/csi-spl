package hub

import (
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 182 v0.4 row L2 (SPL-6032): the pure parts of a loop's fire. The
// hub-level cases (hooks, cap, policy, ticker, routes) are in
// topic_loop_fire_test.go.

// 4.2 step 8: case-free, at word edges, a phrase as a whole.
func TestTopicLoopKeywordMatch(t *testing.T) {
	for _, c := range []struct {
		kw, body string
		want     bool
	}{
		{"PDF", "send the pdf, please", true},
		{"PDF", "two pdfs attached", false},
		{"PDF", "the PDF", true},
		{"pdf", "pdf", true},
		{"pdf", "xpdf viewer", false},
		{"pdf", "a_pdf file", false},
		{"pdf", "(pdf)", true},
		{"release notes", "where are the Release Notes?", true},
		{"release notes", "release notesheet", false},
		{"pdf", "pdfs and then a pdf.", true},
		{"ääkkönen", "hei Ääkkönen!", true},
		{"", "anything", false},
		{"  ", "anything", false},
	} {
		if got := topicLoopKeyword(c.kw, c.body); got != c.want {
			t.Errorf("topicLoopKeyword(%q, %q) = %v, want %v", c.kw, c.body, got, c.want)
		}
	}
}

// Section 2: a hub note (HUB-0, also the pause notices of spec 179) and a
// loop prompt never fire a loop; a time or issue fire has no post and may.
func TestTopicLoopNeverATrigger(t *testing.T) {
	if isLoopTrigger(&msg.Message{From: PublicNoticeFrom, Body: "this topic is paused"}) {
		t.Error("a HUB-0 note fired")
	}
	if isLoopTrigger(&msg.Message{From: "HUM-1", Body: topicLoopPromptMark + "set by @HUM-1, fired by msg:x)"}) {
		t.Error("a loop prompt fired")
	}
	if !isLoopTrigger(&msg.Message{From: "HUM-1", Body: "hello"}) || !isLoopTrigger(nil) {
		t.Error("an ordinary post or a time fire did not")
	}
}

func TestTopicLoopAgentReplyLine(t *testing.T) {
	box := &wire.Envelope{FromBox: "box-a"}
	for _, c := range []struct {
		env      *wire.Envelope
		from, to string
		want     bool
	}{
		{box, "CLE-07", "ALL-0", true},
		{box, "CLE-07", "HUM-1", true},
		{box, "CLE-07", GuestPrefix + "1", true},
		{box, "CLE-07", "CLE-08", false},
		{&wire.Envelope{FromBox: WUIBox}, "CLE-07", "ALL-0", false},
		{box, "HUM-1", "ALL-0", false},
	} {
		if got := isAgentReply(c.env, &msg.Message{From: c.from, To: c.to}); got != c.want {
			t.Errorf("isAgentReply(%s, %s -> %s) = %v", c.env.FromBox, c.from, c.to, got)
		}
	}
}

// The match table: each box fits its event, a routed browser post leaves a
// before_agent_reply loop to the before hook (one fire per post).
func TestTopicLoopMatchTable(t *testing.T) {
	l := func(keys ...string) store.TopicLoop {
		return store.TopicLoop{SetBy: "HUM-1", Keyword: "pdf", Triggers: keys}
	}
	human := &msg.Message{From: "HUM-1", To: "ALL-0", Kind: "note", Body: "hi"}
	reply := &msg.Message{From: "CLE-07", To: "HUM-1", Kind: "note", Body: "the pdf"}
	other := &msg.Message{From: "CLE-07", To: "HUM-2", Kind: "note", Body: "x", Files: []msg.Attachment{{}}}
	blocker := &msg.Message{From: "CLE-07", To: "CLE-08", Kind: blockerKind, Body: "stuck"}
	for _, c := range []struct {
		name string
		ev   loopEvent
		loop store.TopicLoop
		want bool
	}{
		{"human/after_human", loopEvent{kind: loopEventPost, post: human, human: true}, l(store.LoopAfterHumanReply), true},
		{"human/after_agent", loopEvent{kind: loopEventPost, post: human, human: true}, l(store.LoopAfterAgentReply), false},
		{"routed human/before+after", loopEvent{kind: loopEventPost, post: human, human: true, routed: true}, l(store.LoopBeforeAgentReply, store.LoopAfterHumanReply), false},
		{"routed human/after only", loopEvent{kind: loopEventPost, post: human, human: true, routed: true}, l(store.LoopAfterHumanReply), true},
		{"before/before", loopEvent{kind: loopEventBefore, post: human}, l(store.LoopBeforeAgentReply), true},
		{"reply/after_agent", loopEvent{kind: loopEventPost, post: reply, reply: true}, l(store.LoopAfterAgentReply), true},
		{"reply/keyword", loopEvent{kind: loopEventPost, post: reply, reply: true}, l(store.LoopPostHasKeyword), true},
		{"reply/file", loopEvent{kind: loopEventPost, post: other, reply: true}, l(store.LoopPostHasFile), true},
		{"reply no file/file", loopEvent{kind: loopEventPost, post: reply, reply: true}, l(store.LoopPostHasFile), false},
		{"agent-to-agent blocker/blocker", loopEvent{kind: loopEventPost, post: blocker}, l(store.LoopBlockerPosted), true},
		{"agent-to-agent blocker/after_agent", loopEvent{kind: loopEventPost, post: blocker}, l(store.LoopAfterAgentReply), false},
		{"kind change/blocker", loopEvent{kind: loopEventKind, post: blocker}, l(store.LoopBlockerPosted), true},
		{"issue/issue", loopEvent{kind: loopEventIssue}, l(store.LoopIssueStatusChanged), true},
		{"issue/after_agent", loopEvent{kind: loopEventIssue}, l(store.LoopAfterAgentReply), false},
		{"time due daily/daily", loopEvent{kind: loopEventTime}, store.TopicLoop{Triggers: []string{store.LoopDailyAt}, Due: []string{store.LoopDailyAt}}, true},
		{"time nothing due", loopEvent{kind: loopEventTime}, store.TopicLoop{Triggers: []string{store.LoopDailyAt}}, false},
	} {
		if got := c.ev.matches(c.loop); got != c.want {
			t.Errorf("%s: matches = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestTopicLoopQuoteBlock(t *testing.T) {
	q := quoteBlock(strings.Repeat("é", 700))
	if n := len([]rune(q)); n != 2+topicLoopQuoteMax+1 {
		t.Fatalf("quote of 700 characters is %d runes", n)
	}
	if got := quoteBlock("a\nb"); got != "> a\n> b" {
		t.Fatalf("multi-line quote %q", got)
	}
}
