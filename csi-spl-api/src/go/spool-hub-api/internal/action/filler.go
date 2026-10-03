package action

import (
	"fmt"
	"regexp"
	"strings"
)

// Owner rule (HUM-10, 2026-10-03, t1 topic 02800102): a post a human reads in
// a channel or a DM must add value. A body that is ONLY an acknowledgement or
// filler ("ack", "received", "routing this now", "on it") takes the reader's
// time and says nothing, so the send path refuses it. The rule itself lives in
// csi-spl-doc/doc/help/how-to-post.md section 1.
//
// The list is deliberately narrow: a body is refused only when EVERY segment
// of it is a filler phrase, so "Received, deployed 1.3.4 to dev" still goes.
// Agent-to-agent spool files (note/result/blocker to an agent id) are not
// checked: only a send to a channel, to ALL-0 (a topic every member reads) or
// to a human (HUM-*).

// fillerPhrases is one whole segment, lower case, after the trim below.
var fillerPhrases = regexp.MustCompile(`^(?:` + strings.Join([]string{
	`ack(?:ed|'d|nowledged)?`,
	`ok(?:ay)?`, `k`, `roger(?: that)?`, `noted`, `copy(?: that)?`,
	`got it`, `understood`, `sure`,
	`(?:message |msg )?(?:received|seen)`,
	`thanks?(?: you)?`, `thx`, `ty`,
	`will do`, `on it(?: now)?`, `working on it(?: now)?`,
	`looking into it(?: now)?`, `checking(?: now)?`,
	`(?:routing|forwarding|passing|handing) (?:this|it)(?: on| over)?(?: now)?`,
	`will (?:route|forward|pass) (?:this|it)(?: on)?`,
	`standing by`,
}, "|") + `)$`)

// fillerSplit cuts a body into segments: sentence punctuation, newlines and a
// spaced dash. An unspaced dash stays (agent ids such as c-115).
var fillerSplit = regexp.MustCompile(`[.,;:!?\n]+|\s[-–—]+\s`)

// fillerPrefix drops leading sender tags ("c-115:", "**c-115**", "@hum-10").
var fillerPrefix = regexp.MustCompile(`^(?:@?[a-z]{1,3}-[0-9]+(?:@[a-z0-9-]+)?\s*:?\s*)+`)

// IsFiller reports whether body is nothing but acknowledgement or filler.
func IsFiller(body string) bool {
	b := strings.ToLower(strings.NewReplacer("*", "", "_", "", "`", "", ">", "", "#", "").Replace(body))
	b = fillerPrefix.ReplaceAllString(strings.TrimSpace(b), "")
	n := 0
	for _, seg := range fillerSplit.Split(b, -1) {
		seg = strings.Join(strings.Fields(seg), " ")
		if seg == "" {
			continue
		}
		if !fillerPhrases.MatchString(seg) {
			return false
		}
		n++
	}
	return n > 0
}

// humanFacing reports whether a send lands where a human reads it: a channel
// post (normalized to ALL-0), a topic reply to ALL-0, or a DM to a HUM-*.
func humanFacing(in *SendArgs) bool {
	return in.Channel != "" || in.To == Broadcast || strings.HasPrefix(in.To, "HUM-")
}

// checkFiller refuses a human-facing send whose body is only filler.
func checkFiller(in *SendArgs) error {
	if !humanFacing(in) || !IsFiller(in.Body) {
		return nil
	}
	return fmt.Errorf("refused: %q is only an acknowledgement or filler; a post a human reads (channel, ALL-0 topic, HUM-*) must add value - send the result, or nothing (csi-spl-doc/doc/help/how-to-post.md, section 1)", strings.TrimSpace(in.Body))
}
