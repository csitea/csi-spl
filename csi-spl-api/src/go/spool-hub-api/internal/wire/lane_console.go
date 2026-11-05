package wire

import (
	"fmt"
	"regexp"
	"strings"
	"unicode/utf8"
)

// A lane's live console (spec 153 section 3.20, SPL-4810). Two more lane
// ops of the box follower (file-stream-follow.py), over the same `spool
// file-streams push --json -` and the same session as the file streams:
//
//	{"lane_op":"file_streams_console_demands","lane":{}}
//	    -> FileStreamsAckFrame{type: ack, agents: ["<agent id>", ...]}
//	       the agents of THIS box whose console a reader watches now
//	{"lane_op":"file_streams_console_push",
//	 "lane":{"agent_id":"<id>","screen":"<masked text>","lines":N,"redactions":{"<kind>":n}}}
//	    -> FileStreamsAckFrame{type: ack, inserted: 1}
//
// The box masks the screen before it is sent (spool_redact plus the PEM
// state); the hub stores what it gets and never unmasks. The box and the
// workspace are the session's, never the frame's.

const (
	// FileStreamsConsoleDemandsOp asks which of this box's agents a reader watches.
	FileStreamsConsoleDemandsOp = "file_streams_console_demands"
	// FileStreamsConsolePushOp sends one agent's masked screen.
	FileStreamsConsolePushOp = "file_streams_console_push"
	// LaneConsoleScreenMax is the screen's byte cap (rdb 0262).
	LaneConsoleScreenMax = 128 << 10
	// LaneConsoleLinesMax caps the line count a box reports.
	LaneConsoleLinesMax = 5000
)

// LaneConsoleAgentRe is an agent id the console names: the fleet's ids
// (c-128, BOX-0, legacy CLE-12), never a path or a tmux target.
var LaneConsoleAgentRe = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9-]{0,31}$`)

// LaneConsolePushFrame is the lane payload of a console push.
type LaneConsolePushFrame struct {
	AgentID    string           `json:"agent_id"`
	Screen     string           `json:"screen"`
	Lines      int              `json:"lines"`
	Redactions map[string]int64 `json:"redactions"`
}

// DecodeLaneConsolePush reads and checks a console push.
func DecodeLaneConsolePush(raw []byte) (LaneConsolePushFrame, error) {
	var in LaneConsolePushFrame
	if err := strictDecode(raw, &in); err != nil {
		return in, fmt.Errorf("%w: lane must be {agent_id, screen, lines, redactions}: %v", ErrBadFileStream, err)
	}
	switch {
	case !LaneConsoleAgentRe.MatchString(in.AgentID):
		return in, fmt.Errorf("%w: agent_id must match %s", ErrBadFileStream, LaneConsoleAgentRe)
	case len(in.Screen) > LaneConsoleScreenMax:
		return in, fmt.Errorf("%w: screen is over %d bytes", ErrFileStreamTooLarge, LaneConsoleScreenMax)
	case !utf8.ValidString(in.Screen) || strings.ContainsRune(in.Screen, 0):
		return in, fmt.Errorf("%w: screen must be UTF-8 text without NUL", ErrBadFileStream)
	case in.Lines < 0 || in.Lines > LaneConsoleLinesMax:
		return in, fmt.Errorf("%w: lines must be 0..%d", ErrBadFileStream, LaneConsoleLinesMax)
	}
	for k, n := range in.Redactions {
		if k == "" || len(k) > fileStreamKindMax || hasCtl(k) || n < 0 {
			return in, fmt.Errorf("%w: redactions must map a kind of 1..%d bytes to a count >= 0", ErrBadFileStream, fileStreamKindMax)
		}
	}
	return in, nil
}
