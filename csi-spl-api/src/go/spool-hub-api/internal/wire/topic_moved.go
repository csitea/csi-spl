// SPDX-License-Identifier: AGPL-3.0-only

package wire

import "strings"

// TokenTopicMoved refuses a post or a read of a task that left this workspace
// (spec 169 W3, W5). With a 409 the task lives on elsewhere and the detail says
// where (MovedDetail); with a 404 its redirect has expired and the detail does
// not. It names a workspace and a link, never a channel (C13).
const TokenTopicMoved = "topic_moved"

const (
	movedPrefix  = "topic moved: tenant="
	movedLinkSep = " link="
)

// MovedDetail is the detail of a live refusal. A box client reads it back with
// ParseMovedDetail to send the post through its desk there (spec 169 T7b).
func MovedDetail(tenant, link string) string {
	return movedPrefix + tenant + movedLinkSep + link
}

// ParseMovedDetail reads MovedDetail; false for any other text, which is what an
// expired refusal carries.
func ParseMovedDetail(detail string) (tenant, link string, ok bool) {
	rest, ok := strings.CutPrefix(detail, movedPrefix)
	if !ok {
		return "", "", false
	}
	tenant, link, ok = strings.Cut(rest, movedLinkSep)
	if !ok || tenant == "" || link == "" {
		return "", "", false
	}
	return tenant, link, true
}
