package store

import (
	"regexp"
	"strings"
)

// The Go port of the WUI's mention grammar (spec 062 FR-014): MENTION_RE in
// csi-spl-wui/src/utils/notify.mjs, built from csi-spl-wui/src/utils/agent-id.mjs:
//
//	@(PARTICIPANT_ID_SRC)(?:@BOX_ID_SRC)?\b        (global, no lookbehind)
//	PARTICIPANT_ID_SRC = (?:[acgmq]-[0-9]{3}(?![0-9])|[A-Z]{2,4}-[0-9]+)
//	BOX_ID_SRC         = [a-z0-9][a-z0-9-]{0,31}
//
// RE2 has no lookahead, so it is a hand scan that takes the same matches the
// JS engine takes, backtracking included: flow_mentions_test.go pins the JS
// sources it was written against and the matches on a shared fixture.

// MentionedIDs is mentionedIds(body): every id the body names, in order,
// repeats kept.
func MentionedIDs(body string) []string {
	var out []string
	for i := 0; i < len(body); {
		if body[i] != '@' {
			i++
			continue
		}
		id, end, ok := mentionAt(body, i)
		if !ok {
			i++
			continue
		}
		out = append(out, id)
		i = end
	}
	return out
}

// mentionAt matches MENTION_RE at s[i] == '@': the id, and where the match
// (the optional @box included) ends.
func mentionAt(s string, i int) (string, int, bool) {
	p := i + 1
	end, ok := agentIDAt(s, p)
	if !ok {
		end, ok = legacyIDAt(s, p)
	}
	// Both forms end where the next character is not a word character: the
	// agent form's (?![0-9]) plus \b, and the legacy form's greedy digits
	// (shrinking them never yields a boundary between two digits).
	if !ok || end < len(s) && isWordByte(s[end]) {
		return "", 0, false
	}
	return s[p:end], boxEnd(s, end), true
}

// agentIDAt: [acgmq]-[0-9]{3} at p, not followed by a digit.
func agentIDAt(s string, p int) (int, bool) {
	if p+5 > len(s) || !strings.ContainsRune("acgmq", rune(s[p])) || s[p+1] != '-' {
		return 0, false
	}
	for k := p + 2; k < p+5; k++ {
		if !isDigit(s[k]) {
			return 0, false
		}
	}
	if p+5 < len(s) && isDigit(s[p+5]) {
		return 0, false
	}
	return p + 5, true
}

// legacyIDAt: [A-Z]{2,4}-[0-9]+ at p, digits greedy.
func legacyIDAt(s string, p int) (int, bool) {
	k := p
	for k < len(s) && k-p < 4 && s[k] >= 'A' && s[k] <= 'Z' {
		k++
	}
	if k-p < 2 || k >= len(s) || s[k] != '-' {
		return 0, false
	}
	k++
	d := k
	for k < len(s) && isDigit(s[k]) {
		k++
	}
	if k == d {
		return 0, false
	}
	return k, true
}

// boxEnd consumes the optional @<box> after an id at end: the longest box of
// 1..32 characters followed by a word boundary, else nothing.
func boxEnd(s string, end int) int {
	if end+1 >= len(s) || s[end] != '@' || !isBoxFirst(s[end+1]) {
		return end
	}
	k := end + 2
	for k < len(s) && k-(end+1) < 32 && (isBoxFirst(s[k]) || s[k] == '-') {
		k++
	}
	for ; k > end+1; k-- {
		if isWordByte(s[k-1]) != (k < len(s) && isWordByte(s[k])) {
			return k
		}
	}
	return end
}

func isDigit(b byte) bool    { return b >= '0' && b <= '9' }
func isBoxFirst(b byte) bool { return b >= 'a' && b <= 'z' || isDigit(b) }
func isWordByte(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || isDigit(b) || b == '_'
}

// flowMemberRe: a member with a human seat (spec 062 Q5: only they get events).
var flowMemberRe = regexp.MustCompile(`^(HUM|GST)-[0-9]+$`)

// IsFlowMember: id is a HUM-/GST- seat, the only ids that get flow events.
func IsFlowMember(id string) bool { return flowMemberRe.MatchString(id) }

// pokeRe is the WUI poke DM (spec 042 K1, utils/mention-poke.mjs pokeBody +
// cardLink): `<ID> needs you in <origin>/t/<task_id>: "<excerpt>"`.
var pokeRe = regexp.MustCompile(`^[A-Za-z0-9-]+ needs you in \S*/t/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}): "`)

// PokeTask is the task a poke DM body links to, "" when body is not one.
func PokeTask(body string) string {
	if m := pokeRe.FindStringSubmatch(body); m != nil {
		return strings.ToLower(m[1])
	}
	return ""
}

// flowMentions is the human seats body mentions, each once, never author.
func flowMentions(body, author string) []string {
	out := []string{}
	seen := map[string]bool{author: true}
	for _, id := range MentionedIDs(body) {
		if !seen[id] && IsFlowMember(id) {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}
