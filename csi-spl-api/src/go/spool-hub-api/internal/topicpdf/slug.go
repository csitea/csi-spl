// SPDX-License-Identifier: AGPL-3.0-only

package topicpdf

import (
	"strings"
	"time"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

// SlugMax is the longest slug a file name carries, in characters: the WUI's
// PRINT_SLUG_MAX (csi-spl-wui/src/utils/msg-print.ts).
const SlugMax = 60

// Slug is the Go port of the WUI's printSlug (msg-print.ts, spec 183 7.1.4):
// the title NFKC-normalised and lower-cased, letters and digits of any script
// kept, every other run of characters one dash, no dash at either end, at
// most SlugMax characters and never ending on a dash. An empty result is
// "topic".
func Slug(title string) string {
	flat := strings.ToLower(norm.NFKC.String(title))
	var b strings.Builder
	gap := false
	for _, r := range flat {
		if !unicode.IsLetter(r) && !unicode.IsNumber(r) {
			gap = true
			continue
		}
		if gap && b.Len() > 0 {
			b.WriteByte('-')
		}
		gap = false
		b.WriteRune(r)
	}
	cut := []rune(b.String())
	if len(cut) > SlugMax {
		cut = cut[:SlugMax]
	}
	if s := strings.TrimRight(string(cut), "-"); s != "" {
		return s
	}
	return "topic"
}

// FileName is the export's file name (spec 183 7.1.4):
// <slug>-<task8>-<UTC yyyymmddThhmmssZ>.pdf, where task8 is the first 8 hex
// digits of the task id, lower case.
func FileName(title, taskID string, at time.Time) string {
	var hex strings.Builder
	for _, r := range strings.ToLower(taskID) {
		if hex.Len() == 8 {
			break
		}
		if (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') {
			hex.WriteRune(r)
		}
	}
	return Slug(title) + "-" + hex.String() + "-" + at.UTC().Format("20060102T150405Z") + ".pdf"
}
