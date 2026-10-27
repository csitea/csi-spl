// Package keyexec starts a seat's CLI on its workspace's own vendor key
// (spec 127 v1.4 X2, section 5.2 step 5) and tells a refused key apart from
// a plain failure (spec 159 T5, section 9).
//
// The key reaches the CLI only through the wrapper's own environment (or,
// for claude, through an apiKeyHelper that asks the desk socket): never an
// argv, a command string, tmux or a plan file (L6, L15). The wrapper unsets
// every other vendor's variable (L10) and sets a hard RLIMIT_CORE of 0 that
// the CLI inherits and cannot raise (L7).
//
// Unlike 127's first sketch the wrapper does not execve: it forks the CLI,
// waits, and classifies the CLI's exit code and the tail of its stderr. A
// refusal for credit, quota or a revoked key is reported to the desk as
// `exhausted <kind>` with no vendor text (it can echo key fragments); the
// hub then refuses the next lease with 409 key_exhausted, so a supervisor
// that restarts the seat stops at the lease instead of looping on a dead
// key.
package keyexec

import (
	"regexp"
)

// Verdict is what the classifier makes of a CLI's end.
type Verdict int

const (
	// Other is any end that is not a key refusal: a crash, a clean exit,
	// a network error, a plain rate limit.
	Other Verdict = iota
	// Exhausted is the vendor refusing the key for credit, quota or
	// revocation (spec 159 section 9: an HTTP 401, 402 or a 429 with a
	// quota reason).
	Exhausted
)

// String names the verdict as the desk report does.
func (v Verdict) String() string {
	if v == Exhausted {
		return "key_exhausted"
	}
	return "other"
}

// exhaustedRx matches the refusal lines the five CLIs print for a key that
// is out of credit, over its quota or revoked. A plain rate limit (a 429
// that clears by itself: "rate limit", "overloaded") matches none of them.
var exhaustedRx = []*regexp.Regexp{
	// HTTP status codes, only next to a word that marks them as one.
	regexp.MustCompile(`(?i)\b(status|http|error|code)\b[^0-9\n]{0,16}\b40[12]\b`),
	regexp.MustCompile(`(?i)\b402\b[^\n]{0,24}payment required`),
	regexp.MustCompile(`(?i)\b401\b[^\n]{0,24}unauthori[sz]ed`),
	// Credit and billing.
	regexp.MustCompile(`(?i)credit balance is too low`),
	regexp.MustCompile(`(?i)\b(insufficient|out of|no remaining)[ _-]?(credits?|balance|quota)\b`),
	regexp.MustCompile(`(?i)\bbilling[_ ](error|hard[_ ]limit|limit)\b`),
	regexp.MustCompile(`(?i)\bspend(ing)?[_ ]limit\b`),
	// Quota: the 429 that does not clear by itself.
	regexp.MustCompile(`(?i)exceeded your (current )?quota`),
	regexp.MustCompile(`(?i)\bquota[_ ](exceeded|exhausted)\b`),
	regexp.MustCompile(`(?i)\binsufficient_quota\b`),
	// A revoked or wrong key.
	regexp.MustCompile(`(?i)\b(invalid|incorrect|revoked|expired)[ _-]?(x-)?api[ _-]?key\b`),
	regexp.MustCompile(`(?i)\bapi[ _-]?key\b[^\n]{0,24}\b(invalid|revoked|expired|disabled)\b`),
	regexp.MustCompile(`(?i)\bauthentication_error\b`),
}

// Classify reads a CLI's end: its exit code and the tail of what it wrote
// to stderr. A clean exit is never a refusal, whatever it printed.
func Classify(exit int, tail []byte) Verdict {
	if exit == 0 {
		return Other
	}
	for _, rx := range exhaustedRx {
		if rx.Match(tail) {
			return Exhausted
		}
	}
	return Other
}
