package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// fileStreamsReadMax caps what `file-streams push` reads: the follower's
// frame is at most 1 MiB (spec 160 3.7), with room to spare.
const fileStreamsReadMax = 2 << 20

// cmdFileStreams is the box follower's push (spec 160 3.3, row B2;
// csi-spl-orc file-stream-follow.py), over the authenticated hello like
// `spool fleet-tokens`:
//
//	file-streams push --json <file|->   a follower frame -> the hub's ack, one JSON line {type: ack, ...}
//
// The frame is {type, lane_op, ...}: lane_op file_streams_announce carries
// streams and, from row B10, folders and globs (spec 160 3.8.5);
// file_streams_push carries stream_key, lines, dropped and redactions;
// file_streams_globs (the pull of the box's web globs) carries nothing and
// its ack lists them; file_streams_console_demands (spec 153 3.18) carries
// nothing and its ack lists the agents watched; file_streams_console_push
// carries agent_id, screen, lines_n (the line count: "lines" is the file
// push's list) and redactions. Only the payload is sent, checked here first by the hub's own
// decoders. The hub's socket reads at most 512 KiB a frame, so a push is
// split into parts of at most wire.FileStreamPushMaxBytes and 1000 lines,
// sent in seq order; the ack is printed only when every part is acked (a
// part re-sent after a failure is not stored twice: the hub keys on seq).
func cmdFileStreams(cfg *config.Config, args []string) int {
	if len(args) != 3 || args[0] != "push" || args[1] != "--json" {
		return fail(errors.New("usage: spool file-streams push --json <file|->"))
	}
	var raw []byte
	var err error
	if args[2] == "-" {
		raw, err = io.ReadAll(io.LimitReader(os.Stdin, fileStreamsReadMax))
	} else {
		raw, err = os.ReadFile(args[2])
	}
	if err != nil {
		return fail(err)
	}
	op, parts, err := fileStreamsParts(raw)
	if err != nil {
		return fail(fmt.Errorf("file-streams push: %w", err))
	}
	if cfg.HubURL == "" {
		return fail(errors.New("file streams need hub mode ($SPOOL_HUB_URL is not set)"))
	}
	ctx, stop := interruptible()
	defer stop()
	var last wire.FileStreamsAckFrame
	inserted := 0
	for _, part := range parts {
		out, err := hubclient.New(cfg).Lane(ctx, op, "", part)
		if err != nil {
			return fail(err)
		}
		if err := json.Unmarshal(out, &last); err != nil || last.Type != "ack" {
			return fail(fmt.Errorf("file-streams push: the hub's answer is not an ack: %s", out))
		}
		inserted += last.Inserted
	}
	last.Inserted = inserted
	b, err := json.Marshal(last)
	if err != nil {
		return fail(err)
	}
	fmt.Println(string(b))
	return 0
}

// fileStreamsParts reads a follower frame into its lane op and the lane
// payloads to send: one for an announce, one or more for a push.
func fileStreamsParts(raw []byte) (string, []json.RawMessage, error) {
	var in struct {
		LaneOp     string          `json:"lane_op"`
		Streams    json.RawMessage `json:"streams"`
		StreamKey  json.RawMessage `json:"stream_key"`
		Lines      json.RawMessage `json:"lines"`
		Dropped    json.RawMessage `json:"dropped"`
		Redactions json.RawMessage `json:"redactions"`
		Folders    json.RawMessage `json:"folders"`
		Globs      json.RawMessage `json:"globs"`
		// the console push (spec 153 3.18, wire/lane_console.go)
		AgentID json.RawMessage `json:"agent_id"`
		Screen  json.RawMessage `json:"screen"`
		NLines  json.RawMessage `json:"lines_n"`
	}
	if err := json.Unmarshal(raw, &in); err != nil {
		return "", nil, fmt.Errorf("not a follower frame object: %w", err)
	}
	switch in.LaneOp {
	case wire.FileStreamsAnnounceOp:
		ann := map[string]json.RawMessage{"streams": in.Streams}
		for k, v := range map[string]json.RawMessage{"folders": in.Folders, "globs": in.Globs} {
			if len(v) > 0 && string(v) != "null" {
				ann[k] = v
			}
		}
		row, err := json.Marshal(ann)
		if err == nil {
			_, err = wire.DecodeFileStreamsAnnounce(row)
		}
		return in.LaneOp, []json.RawMessage{row}, err
	case wire.FileStreamsPushOp:
		var p wire.FileStreamsPushFrame
		row, err := json.Marshal(map[string]json.RawMessage{"stream_key": in.StreamKey, "lines": in.Lines,
			"dropped": orJSON(in.Dropped, "0"), "redactions": orJSON(in.Redactions, "{}")})
		if err == nil {
			err = json.Unmarshal(row, &p)
		}
		if err != nil {
			return "", nil, err
		}
		parts, err := fileStreamsSplit(p)
		return in.LaneOp, parts, err
	case wire.FileStreamsGlobsOp, wire.FileStreamsConsoleDemandsOp:
		row := json.RawMessage(`{}`)
		return in.LaneOp, []json.RawMessage{row}, wire.DecodeFileStreamsGlobsPull(row)
	case wire.FileStreamsConsolePushOp:
		row, err := json.Marshal(map[string]json.RawMessage{"agent_id": in.AgentID, "screen": in.Screen,
			"lines": orJSON(in.NLines, "0"), "redactions": orJSON(in.Redactions, "{}")})
		if err == nil {
			_, err = wire.DecodeLaneConsolePush(row)
		}
		return in.LaneOp, []json.RawMessage{row}, err
	}
	return "", nil, fmt.Errorf("lane_op must be %s, %s, %s, %s or %s", wire.FileStreamsAnnounceOp, wire.FileStreamsPushOp,
		wire.FileStreamsGlobsOp, wire.FileStreamsConsoleDemandsOp, wire.FileStreamsConsolePushOp)
}

func orJSON(v json.RawMessage, def string) json.RawMessage {
	if len(v) == 0 || string(v) == "null" {
		return json.RawMessage(def)
	}
	return v
}

// fileStreamsSplit cuts a push into parts the hub takes: each at most 1000
// lines and wire.FileStreamPushMaxBytes, every one checked by the hub's
// decoder. dropped and redactions ride the first part only, so they count
// once.
func fileStreamsSplit(p wire.FileStreamsPushFrame) ([]json.RawMessage, error) {
	var parts []json.RawMessage
	rest := p.Lines
	first := true
	for len(rest) > 0 || first {
		part := wire.FileStreamsPushFrame{StreamKey: p.StreamKey, Redactions: map[string]int64{}}
		if first {
			part.Dropped, part.Redactions = p.Dropped, p.Redactions
		}
		n := min(len(rest), wire.FileStreamLinesPerPush)
		for {
			part.Lines = rest[:n]
			row, err := json.Marshal(part)
			if err != nil {
				return nil, err
			}
			if len(row) <= wire.FileStreamPushMaxBytes || n <= 1 {
				if _, err := wire.DecodeFileStreamsPush(row); err != nil {
					return nil, err
				}
				parts, rest, first = append(parts, row), rest[n:], false
				break
			}
			n /= 2
		}
	}
	return parts, nil
}
