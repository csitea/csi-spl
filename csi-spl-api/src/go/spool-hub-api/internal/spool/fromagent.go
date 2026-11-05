package spool

import (
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// FromAgentPrefix opens the first body line of a message one box relays to
// another (HOWTO-satellite-work §4 gaps 1-3): "from_agent: <ID>@<box>".
//
// The box is the trust unit, not the seat. A lane agent is never seated on
// its box's desk, so scripts/spool-fleet-relay.sh sends its line under a
// seated id of that box and names the real sender here; a seated sender
// names itself too, so every relayed line says which machine it came from.
// The v:1 object has no field for it (msg.Parse refuses unknown keys, and the
// hub validates the same schema), so it rides in the signed body.
const FromAgentPrefix = "from_agent: "

// WithFromAgent is m as the receiving box writes it: when the body opens
// with a from_agent line naming an agent of fromBox - the box whose pin
// signed the envelope, so a box can speak only for its own agents - the copy
// carries that "<ID>@<box>" as from and the line is dropped from the body.
// Anything else, a claim for another box included, returns m unchanged.
func WithFromAgent(m *msg.Message, fromBox string) *msg.Message {
	id, box, rest, ok := FromAgentOf(m.From, fromBox, m.Body)
	if !ok {
		return m
	}
	c := *m
	c.From = id + "@" + box
	c.Body = rest
	return &c
}

// FromAgentOf is WithFromAgent's rule on a stored row (RCA 8c64225e A1.1):
// the real sender id and box a from_agent first line names, and the body
// without that line. ok false, body unchanged, when the line is absent, the
// row's from is not an agent, or the line claims an agent of a box other
// than fromBox. The hub stores a relayed body verbatim, so its readers that
// take the row as someone's word (the blocker sweep) split it here.
func FromAgentOf(from, fromBox, body string) (id, box, rest string, ok bool) {
	claim, rest, ok := strings.Cut(body, "\n")
	if !ok || !strings.HasPrefix(claim, FromAgentPrefix) || !agentSender(from) {
		return "", "", body, false
	}
	id, box, ok = strings.Cut(strings.TrimSpace(strings.TrimPrefix(claim, FromAgentPrefix)), "@")
	if !ok || box != fromBox || !msg.ValidBoxID(box) || !agentSender(id) {
		return "", "", body, false
	}
	return id, box, rest, true
}

// validStored is Validate for a message file in a local inbox: from may be
// "<ID>@<box>", the form WithFromAgent writes for a relayed line.
func validStored(m *msg.Message) error {
	if id, box, ok := strings.Cut(m.From, "@"); ok && msg.ValidID(id) && msg.ValidBoxID(box) {
		c := *m
		c.From = id
		return c.Validate()
	}
	return m.Validate()
}
