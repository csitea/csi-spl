package wire

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

// File streams (spec 160 section 3.3, row B2). A box's follower
// (csi-spl-orc file-stream-follow.py) follows its allow-listed files and
// sends two lane frames over the box's authenticated session, through
// `spool file-streams push --json -`:
//
//	{"type":"lane","msg_id":"<uuid>","lane_op":"file_streams_announce",
//	 "lane":{"streams":[FileStreamAnnounced, ...]}}
//	{"type":"lane","msg_id":"<uuid>","lane_op":"file_streams_push",
//	 "lane":{"stream_key":"<id>","lines":[FileStreamLine, ...],
//	         "dropped":N,"redactions":{"<kind>":n}}}
//
// The hub answers each on the same msg_id with a lane frame whose lane is a
// FileStreamsAckFrame (type "ack"; the follower drops the frame's lines from
// its queue only on it). The box and the workspace are the session's, never
// the frame's: a frame naming either is refused as an unknown field.

// The lane ops.
const (
	FileStreamsAnnounceOp = "file_streams_announce"
	FileStreamsPushOp     = "file_streams_push"
)

// The stream states (rdb file_streams.state). A box announces following,
// missing or refused; the hub sets refused over a limit (3.7) and gone for a
// key the box no longer announces.
const (
	FileStreamFollowing = "following"
	FileStreamMissing   = "missing"
	FileStreamRefused   = "refused"
	FileStreamGone      = "gone"
)

// Limits of one frame (spec 160 3.7). The hub's socket reads at most
// 512 KiB a frame (hub maxFrameBytes), so the CLI splits a follower frame
// (up to 1 MiB) into pushes of at most FileStreamPushMaxBytes of lane.
const (
	FileStreamsPerBox      = 8
	FileStreamLinesPerPush = 1000
	FileStreamPushMaxBytes = 448 << 10
	// FileStreamLineMax is the box's 2048-byte line limit plus the
	// " [cut N bytes]" note it appends to a cut line.
	FileStreamLineMax = 2048 + 32
	fileStreamPathMax = 1024
	fileStreamKindMax = 64
)

// FileStreamKeyRe is a stream key (spec 160 3.2 `id`).
var FileStreamKeyRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)

// FileStreamAnnounced is one entry of the box's allow-list as it stands.
type FileStreamAnnounced struct {
	StreamKey string `json:"stream_key"`
	Path      string `json:"path"`
	State     string `json:"state"`
}

// FileStreamsAnnounceFrame is the lane payload of an announce.
type FileStreamsAnnounceFrame struct {
	Streams []FileStreamAnnounced `json:"streams"`
}

// FileStreamLine is one masked line. Seq is per stream, strictly
// increasing; Marker says the text is the follower's own (rotated,
// truncated, missing, dropped N, refused), not a line of the file.
type FileStreamLine struct {
	Seq    int64     `json:"seq"`
	At     time.Time `json:"at"`
	Text   string    `json:"text"`
	Marker bool      `json:"marker"`
}

// FileStreamsPushFrame is the lane payload of a push: lines of one stream.
type FileStreamsPushFrame struct {
	StreamKey  string           `json:"stream_key"`
	Lines      []FileStreamLine `json:"lines"`
	Dropped    int64            `json:"dropped"`
	Redactions map[string]int64 `json:"redactions"`
}

// FileStreamAckState is the hub's verdict on one announced key.
type FileStreamAckState struct {
	StreamKey string `json:"stream_key"`
	State     string `json:"state"`
	Reason    string `json:"reason,omitempty"`
}

// FileStreamsAckFrame is the hub's answer to either op. An announce's ack
// lists every key with the state the hub keeps (refused over a limit); a
// push's ack names the stream, the lines written (a re-sent seq is acked
// and not written twice) and the highest seq it acked.
type FileStreamsAckFrame struct {
	Type      string               `json:"type"`
	LaneOp    string               `json:"lane_op"`
	Streams   []FileStreamAckState `json:"streams,omitempty"`
	StreamKey string               `json:"stream_key,omitempty"`
	Inserted  int                  `json:"inserted"`
	AckedSeq  int64                `json:"acked_seq,omitempty"`
	Pruned    int                  `json:"pruned,omitempty"`
	At        string               `json:"at"`
}

// ErrBadFileStream wraps every refusal of the two decoders.
var ErrBadFileStream = errors.New("bad_file_stream")

// ErrFileStreamTooLarge: a push over FileStreamLinesPerPush lines or
// FileStreamPushMaxBytes (spec 160 3.7: 413 too_large, the box splits).
var ErrFileStreamTooLarge = errors.New("too_large")

func strictDecode(raw json.RawMessage, v any) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

// DecodeFileStreamsAnnounce reads and checks an announce: at most
// FileStreamsPerBox*4 entries (the hub refuses the keys past
// FileStreamsPerBox, it does not refuse the frame), each key once, a known
// state, one-line path.
func DecodeFileStreamsAnnounce(raw json.RawMessage) (FileStreamsAnnounceFrame, error) {
	var in FileStreamsAnnounceFrame
	if err := strictDecode(raw, &in); err != nil {
		return in, fmt.Errorf("%w: lane must be {streams: [...]}: %v", ErrBadFileStream, err)
	}
	if in.Streams == nil || len(in.Streams) > 4*FileStreamsPerBox {
		return in, fmt.Errorf("%w: streams must be a list of at most %d", ErrBadFileStream, 4*FileStreamsPerBox)
	}
	seen := map[string]bool{}
	for i, s := range in.Streams {
		switch {
		case !FileStreamKeyRe.MatchString(s.StreamKey):
			return in, fmt.Errorf("%w: stream %d: stream_key must match %s", ErrBadFileStream, i, FileStreamKeyRe)
		case seen[s.StreamKey]:
			return in, fmt.Errorf("%w: stream %d: stream_key %s twice", ErrBadFileStream, i, s.StreamKey)
		case s.State != FileStreamFollowing && s.State != FileStreamMissing && s.State != FileStreamRefused:
			return in, fmt.Errorf("%w: stream %d: state must be following, missing or refused", ErrBadFileStream, i)
		case s.Path == "" || len(s.Path) > fileStreamPathMax || !utf8.ValidString(s.Path) || hasCtl(s.Path):
			return in, fmt.Errorf("%w: stream %d: path must be one line of 1..%d bytes", ErrBadFileStream, i, fileStreamPathMax)
		}
		seen[s.StreamKey] = true
	}
	return in, nil
}

// DecodeFileStreamsPush reads and checks a push: a stream key, 1..1000
// lines in strictly increasing seq > 0, each a valid UTF-8 text of at most
// FileStreamLineMax bytes with no newline, counts >= 0. A push over the
// line or byte limit wraps ErrFileStreamTooLarge, every other refusal
// ErrBadFileStream; nothing of a refused push is stored (case C23).
func DecodeFileStreamsPush(raw json.RawMessage) (FileStreamsPushFrame, error) {
	var in FileStreamsPushFrame
	if len(raw) > FileStreamPushMaxBytes {
		return in, fmt.Errorf("%w: a push is at most %d bytes", ErrFileStreamTooLarge, FileStreamPushMaxBytes)
	}
	if err := strictDecode(raw, &in); err != nil {
		return in, fmt.Errorf("%w: lane must be {stream_key, lines, dropped, redactions}: %v", ErrBadFileStream, err)
	}
	switch {
	case !FileStreamKeyRe.MatchString(in.StreamKey):
		return in, fmt.Errorf("%w: stream_key must match %s", ErrBadFileStream, FileStreamKeyRe)
	case len(in.Lines) > FileStreamLinesPerPush:
		return in, fmt.Errorf("%w: at most %d lines per push", ErrFileStreamTooLarge, FileStreamLinesPerPush)
	case len(in.Lines) == 0:
		return in, fmt.Errorf("%w: lines is empty", ErrBadFileStream)
	case in.Dropped < 0:
		return in, fmt.Errorf("%w: dropped must be >= 0", ErrBadFileStream)
	}
	for k, n := range in.Redactions {
		if k == "" || len(k) > fileStreamKindMax || hasCtl(k) || n < 0 {
			return in, fmt.Errorf("%w: redactions must map a kind of 1..%d bytes to a count >= 0", ErrBadFileStream, fileStreamKindMax)
		}
	}
	var prev int64
	for i, l := range in.Lines {
		switch {
		case l.Seq <= prev:
			return in, fmt.Errorf("%w: line %d: seq must be > 0 and strictly increasing", ErrBadFileStream, i)
		case l.At.IsZero():
			return in, fmt.Errorf("%w: line %d: at is required (RFC 3339)", ErrBadFileStream, i)
		case len(l.Text) > FileStreamLineMax:
			return in, fmt.Errorf("%w: line %d: text is at most %d bytes", ErrBadFileStream, i, FileStreamLineMax)
		case !utf8.ValidString(l.Text) || strings.ContainsAny(l.Text, "\n\x00"):
			return in, fmt.Errorf("%w: line %d: text must be one line of valid UTF-8", ErrBadFileStream, i)
		}
		prev = l.Seq
		in.Lines[i].At = l.At.UTC()
	}
	return in, nil
}
