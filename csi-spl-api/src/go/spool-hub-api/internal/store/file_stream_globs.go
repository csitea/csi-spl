package store

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// File globs typed in the web page (spec 160 section 3.8, row B9, rdb 0242).
// A workspace owner or admin types a glob PATTERN for one box; the hub stores
// it, audits it and hands it to that box when the box pulls (3.8.5). The hub
// never opens, lists or resolves a pattern (3.8.1). Every call names the
// tenant and runs in its scope; the one exception is the audit retention
// prune of the hub's sweeper (PruneFileStreamGlobAudit, operatorCallers).

// The audit actions (rdb file_stream_glob_audit.action, 3.8.9).
const (
	FileStreamGlobAuditAdd     = "add"
	FileStreamGlobAuditRemove  = "remove"
	FileStreamGlobAuditRefused = "refused"
)

// FileStreamGlobAuditRetention is 3.8.9's 365 days
// (SPOOL_HUB_FILE_STREAMS_GLOB_AUDIT_RETENTION).
const FileStreamGlobAuditRetention = 365 * 24 * time.Hour

// fileStreamAuditTextMax caps the glob text an audit row keeps of a refused
// add (the column takes 1024 bytes; a refused glob may be longer, or junk).
const fileStreamAuditTextMax = 600

// ErrFileStreamGlobKeyTaken: the key names a live glob of that box already
// (409 glob_key_taken).
var ErrFileStreamGlobKeyTaken = errors.New("store: file stream glob key taken")

// ErrFileStreamGlobsFull: the box holds its cap of live globs (409
// too_many_globs).
var ErrFileStreamGlobsFull = errors.New("store: file stream globs per box full")

// FileStreamGlob is one file_stream_globs row. State .. ReportedAt are the
// box's last report (State pending until the first).
type FileStreamGlob struct {
	ID         string
	Tenant     string
	Box        string
	Key        string
	Glob       string
	CreatedBy  string
	CreatedAt  time.Time
	RemovedAt  *time.Time
	State      string
	Reason     string
	Matched    int
	Followed   int
	OverCap    int
	ReportedAt *time.Time
}

// FileStreamFolder is one allowed folder as a box last announced it.
type FileStreamFolder struct {
	Box        string
	Path       string
	State      string
	Reason     string
	ReportedAt time.Time
}

// FileStreamGlobAuditRow is one file_stream_glob_audit row. GlobID is ""
// for a refused add.
type FileStreamGlobAuditRow struct {
	ID     string
	GlobID string
	Box    string
	Action string
	Key    string
	Glob   string
	Actor  string
	Reason string
	At     time.Time
}

// FileStreamGlobAdd is one add: the box, key and glob (checked by the hub),
// the actor's human id, and the box's cap of live globs.
type FileStreamGlobAdd struct {
	Box   string
	Key   string
	Glob  string
	Actor string
	Max   int
}

// FileStreamGlobStore is the hub's web glob store (rdb 0242).
type FileStreamGlobStore interface {
	// FileStreamBoxFolders says whether box announced in tenant (a
	// file_streams or file_stream_folders row of tenant names it) and the
	// folders it last announced, by path.
	FileStreamBoxFolders(ctx context.Context, tenant, box string) (bool, []FileStreamFolder, error)
	// AddFileStreamGlob stores a live glob and its add audit row in one
	// transaction: ErrFileStreamGlobKeyTaken when the key names a live glob
	// of the box, ErrFileStreamGlobsFull when the box holds in.Max live
	// globs. Adds of one box are serialized, so the cap holds under races.
	AddFileStreamGlob(ctx context.Context, tenant string, in FileStreamGlobAdd, now time.Time) (FileStreamGlob, error)
	// RemoveFileStreamGlob sets removed_at on a live glob of tenant and writes
	// its remove audit row; ErrNotFound for an id that is not a live glob of
	// tenant (another workspace's, or removed already: no audit row).
	RemoveFileStreamGlob(ctx context.Context, tenant, id, actor string, now time.Time) (FileStreamGlob, error)
	// AuditFileStreamGlobRefusal writes one refused-add audit row (3.8.9).
	AuditFileStreamGlobRefusal(ctx context.Context, tenant string, a FileStreamGlobAuditRow) error
	// ListFileStreamGlobs is tenant's live globs (by box, then key) and every
	// box's announced folders (by box, then path).
	ListFileStreamGlobs(ctx context.Context, tenant string) ([]FileStreamGlob, []FileStreamFolder, error)
	// FileStreamGlobAudit is up to limit of tenant's audit rows, newest
	// first, those before before when it is set.
	FileStreamGlobAudit(ctx context.Context, tenant string, before *time.Time, limit int) ([]FileStreamGlobAuditRow, error)
	// BoxFileStreamGlobs is box's live globs in tenant, oldest first: what
	// the box's pull answers (3.8.5, case C46).
	BoxFileStreamGlobs(ctx context.Context, tenant, box string) ([]FileStreamGlob, error)
	// ReportFileStreamGlobs stores box's announce report: each glob's state
	// on that box's live glob of that id (any other id is ignored), and,
	// when folders is not nil, the box's folders replaced by it.
	ReportFileStreamGlobs(ctx context.Context, tenant, box string, folders []wire.FileStreamFolderReport, globs []wire.FileStreamGlobReport, now time.Time) error
	// PruneFileStreamGlobAudit deletes every workspace's audit rows older
	// than before (the hub's sweeper; no route).
	PruneFileStreamGlobAudit(ctx context.Context, before time.Time) (int, error)
}

// FileStreamAuditText is s as an audit row keeps it: valid UTF-8, each
// control character a U+FFFD, at most max bytes (a refused glob may be any
// string the browser sent).
func FileStreamAuditText(s string, max int) string {
	s = strings.ToValidUTF8(s, "�")
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return '�'
		}
		return r
	}, s)
	if len(s) > max {
		s = strings.ToValidUTF8(s[:max], "") // drops a rune cut in half
	}
	return s
}

// fileStreamAuditRow is a with its text fields cut to what the table keeps.
func fileStreamAuditRow(a FileStreamGlobAuditRow) FileStreamGlobAuditRow {
	a.Box = FileStreamAuditText(a.Box, 200)
	a.Key = FileStreamAuditText(a.Key, 200)
	a.Glob = FileStreamAuditText(a.Glob, fileStreamAuditTextMax)
	a.Reason = FileStreamAuditText(a.Reason, 64)
	return a
}

// fileStreamAuditLimit is limit within 1..500, 50 by default (3.8.9: the
// page shows the newest 50).
func fileStreamAuditLimit(limit int) int {
	switch {
	case limit <= 0:
		return 50
	case limit > 500:
		return 500
	}
	return limit
}
