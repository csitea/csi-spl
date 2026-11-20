// SPDX-License-Identifier: AGPL-3.0-only

package topicpdf

import (
	"strings"
	"unicode"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// TitleChars is how many characters of the opening a title keeps: the WUI's
// TOPIC_TITLE_CHARS (csi-spl-wui/src/utils/view-api.mjs).
const TitleChars = 100

// jsSpace is JavaScript's \s, so Opening collapses exactly what topicOpening
// does: Go's unicode.IsSpace without U+0085, plus U+FEFF.
func jsSpace(r rune) bool {
	return (unicode.IsSpace(r) && r != '\u0085') || r == '\uFEFF'
}

// Opening is the Go port of the WUI's topicOpening (view-api.mjs): the text
// with every whitespace run one space and trimmed; a text longer than
// TitleChars characters keeps that many and ends with "...".
func Opening(text string) string {
	flat := strings.Join(strings.FieldsFunc(text, jsSpace), " ")
	chars := []rune(flat)
	if len(chars) <= TitleChars {
		return flat
	}
	return string(chars[:TitleChars]) + "..."
}

// Title is the PDF's title (spec 183 7.1.3): the Go port of the WUI's
// topicTitleFromRows without a pinned root, the Opening of the oldest row's
// body (the first of equal times wins, as there); "" when there is no text,
// as there (the PDF's heading then prints "topic", and Slug("") is "topic").
func Title(rows []store.EditableMessage) string {
	var root *store.EditableMessage
	for i := range rows {
		if root == nil || rows[i].TS.Before(root.TS) {
			root = &rows[i]
		}
	}
	if root == nil {
		return ""
	}
	return Opening(root.Body)
}
