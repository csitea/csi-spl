package wire

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// File globs typed in the web page (spec 160 section 3.8, row B9, rdb 0242;
// owner HUM-10, t1 c168784c, poll 376e9435 answer B). A workspace owner or
// admin types a glob PATTERN for one box; the hub checks its syntax, stores
// it and hands it to that box when the box pulls:
//
//	{"type":"lane","msg_id":"<uuid>","lane_op":"file_streams_globs","lane":{}}
//	-> FileStreamsAckFrame {type: ack, lane_op: file_streams_globs, globs: [{id, key, glob}]}
//
// The box and the workspace are the session's, never the frame's: the pull's
// payload is {} and a field in it is refused (case C46). The box re-checks
// every pattern itself (3.8.6); this check is the hub's, not the gate.

// FileStreamsGlobsOp is the box's pull of its live globs (3.8.5).
const FileStreamsGlobsOp = "file_streams_globs"

// The glob states a box reports (3.8.6), and pending: stored, not yet
// reported by the box.
const (
	FileStreamGlobPending   = "pending"
	FileStreamGlobFollowing = "following"
	FileStreamGlobPartial   = "partial"
	FileStreamGlobNone      = "none"
	FileStreamGlobRefused   = "refused"
)

// The folder states a box reports (3.8.2): allowed, or refused by the box's
// own folder check.
const (
	FileStreamFolderAllowed = "allowed"
	FileStreamFolderRefused = "refused"
)

// Limits of a typed glob and of a box's report (3.8.3).
const (
	FileStreamGlobMax       = 512
	FileStreamGlobsPerBox   = 8
	fileStreamReasonMax     = 200
	fileStreamFoldersMax    = 32
	fileStreamGlobReportMax = 4 * FileStreamGlobsPerBox
)

// FileStreamGlobKeyRe is a glob's key: 24 at most, so a match key
// "<key>-<6 hex>" fits FileStreamKeyRe's 32 (3.8.6).
var FileStreamGlobKeyRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,23}$`)

// fileStreamUUIDRe is a glob id as the hub mints it.
var fileStreamUUIDRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// ErrBadGlob wraps every refusal of CheckFileStreamGlob (400 bad_glob).
var ErrBadGlob = errors.New("bad_glob")

// CheckFileStreamGlob is the syntax of 3.8.3: one line of 1..512 bytes of
// UTF-8 with no control character; absolute or $HOME/; '*' and '?' only,
// and only in the last segment; no '[', '{' or '**'; no empty, '.' or '..'
// segment.
func CheckFileStreamGlob(g string) error {
	switch {
	case g == "" || len(g) > FileStreamGlobMax:
		return fmt.Errorf("%w: a glob is 1..%d bytes", ErrBadGlob, FileStreamGlobMax)
	case !utf8.ValidString(g) || strings.ContainsFunc(g, unicode.IsControl):
		return fmt.Errorf("%w: a glob is one line of UTF-8 with no control character", ErrBadGlob)
	case strings.ContainsAny(g, "[{"):
		return fmt.Errorf("%w: '[' and '{' are not glob syntax here: '*' and '?' only", ErrBadGlob)
	case strings.Contains(g, "**"):
		return fmt.Errorf("%w: '**' is refused: one directory only", ErrBadGlob)
	}
	rest, ok := strings.CutPrefix(g, "$HOME/")
	if !ok {
		if rest, ok = strings.CutPrefix(g, "/"); !ok {
			return fmt.Errorf("%w: a glob is absolute or starts $HOME/", ErrBadGlob)
		}
	}
	segs := strings.Split(rest, "/")
	for i, s := range segs {
		switch {
		case s == "" || s == "." || s == "..":
			return fmt.Errorf("%w: no empty, '.' or '..' segment", ErrBadGlob)
		case i < len(segs)-1 && strings.ContainsAny(s, "*?"):
			return fmt.Errorf("%w: '*' and '?' only in the last segment", ErrBadGlob)
		}
	}
	return nil
}

// FileStreamGlobDir is the glob's literal directory: all of it up to the
// last '/', $HOME/ kept unexpanded ("$HOME" for a glob directly under it).
func FileStreamGlobDir(g string) string {
	i := strings.LastIndexByte(g, '/')
	if i <= 0 {
		return "/"
	}
	return g[:i]
}

// FileStreamGlobUnder: the glob's literal directory is folder or under it,
// compared as strings with $HOME/ unexpanded on both sides (3.8.3; advisory,
// the box's fd check is the gate, 3.8.1).
func FileStreamGlobUnder(g, folder string) bool {
	dir, f := FileStreamGlobDir(g), strings.TrimRight(folder, "/")
	if f == "" {
		return false
	}
	return dir == f || strings.HasPrefix(dir, f+"/")
}

// FileStreamGlobLive is one live glob as the box's pull answers it.
type FileStreamGlobLive struct {
	ID   string `json:"id"`
	Key  string `json:"key"`
	Glob string `json:"glob"`
}

// FileStreamFolderReport is one allowed folder as the box's announce names
// it (3.8.5): its path as the box's cnf has it, and the box's verdict.
type FileStreamFolderReport struct {
	Path   string `json:"path"`
	State  string `json:"state"`
	Reason string `json:"reason,omitempty"`
}

// FileStreamGlobReport is the box's state of one glob it pulled (3.8.6).
type FileStreamGlobReport struct {
	ID       string `json:"id"`
	State    string `json:"state"`
	Matched  int    `json:"matched"`
	Followed int    `json:"followed"`
	OverCap  int    `json:"over_cap"`
	Reason   string `json:"reason,omitempty"`
}

// DecodeFileStreamsGlobsPull reads the pull's payload: {} and nothing else
// (not null, not a field, not a second value).
func DecodeFileStreamsGlobsPull(raw json.RawMessage) error {
	var in struct{}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	err := dec.Decode(&in)
	if err == nil && (!bytes.HasPrefix(bytes.TrimSpace(raw), []byte("{")) || dec.More()) {
		err = errors.New("not one object")
	}
	if err != nil {
		return fmt.Errorf("%w: lane must be {}: the box and the workspace are the session's: %v", ErrBadFileStream, err)
	}
	return nil
}

// fileStreamReasonOK: a reason is one line of at most 200 bytes.
func fileStreamReasonOK(r string) bool {
	return len(r) <= fileStreamReasonMax && utf8.ValidString(r) && !hasCtl(r)
}

// checkFileStreamFolders checks the announce's folders: at most 32, each
// path once, absolute or $HOME/, a known state.
func checkFileStreamFolders(in []FileStreamFolderReport) error {
	if len(in) > fileStreamFoldersMax {
		return fmt.Errorf("%w: folders must be a list of at most %d", ErrBadFileStream, fileStreamFoldersMax)
	}
	seen := map[string]bool{}
	for i, f := range in {
		switch {
		case f.Path == "" || len(f.Path) > fileStreamPathMax || !utf8.ValidString(f.Path) || hasCtl(f.Path):
			return fmt.Errorf("%w: folder %d: path must be one line of 1..%d bytes", ErrBadFileStream, i, fileStreamPathMax)
		case !strings.HasPrefix(f.Path, "/") && !strings.HasPrefix(f.Path, "$HOME/"):
			return fmt.Errorf("%w: folder %d: path must be absolute or start $HOME/", ErrBadFileStream, i)
		case seen[f.Path]:
			return fmt.Errorf("%w: folder %d: path twice", ErrBadFileStream, i)
		case f.State != FileStreamFolderAllowed && f.State != FileStreamFolderRefused:
			return fmt.Errorf("%w: folder %d: state must be allowed or refused", ErrBadFileStream, i)
		case !fileStreamReasonOK(f.Reason):
			return fmt.Errorf("%w: folder %d: reason must be one line of at most %d bytes", ErrBadFileStream, i, fileStreamReasonMax)
		}
		seen[f.Path] = true
	}
	return nil
}

// checkFileStreamGlobReports checks the announce's globs: at most 32, each id
// once and a UUID, a known state, counts >= 0 with followed and over_cap
// within matched.
func checkFileStreamGlobReports(in []FileStreamGlobReport) error {
	if len(in) > fileStreamGlobReportMax {
		return fmt.Errorf("%w: globs must be a list of at most %d", ErrBadFileStream, fileStreamGlobReportMax)
	}
	seen := map[string]bool{}
	for i, g := range in {
		switch {
		case !fileStreamUUIDRe.MatchString(g.ID) || seen[g.ID]:
			return fmt.Errorf("%w: glob %d: id must be a glob's id, once", ErrBadFileStream, i)
		case g.State != FileStreamGlobFollowing && g.State != FileStreamGlobPartial && g.State != FileStreamGlobNone && g.State != FileStreamGlobRefused:
			return fmt.Errorf("%w: glob %d: state must be following, partial, none or refused", ErrBadFileStream, i)
		case g.Matched < 0 || g.Followed < 0 || g.OverCap < 0 || g.Followed+g.OverCap > g.Matched:
			return fmt.Errorf("%w: glob %d: counts must be >= 0, followed + over_cap <= matched", ErrBadFileStream, i)
		case !fileStreamReasonOK(g.Reason):
			return fmt.Errorf("%w: glob %d: reason must be one line of at most %d bytes", ErrBadFileStream, i, fileStreamReasonMax)
		}
		seen[g.ID] = true
	}
	return nil
}
