package store

import (
	"context"
	"errors"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// File streams (spec 160 sections 3.3 and 3.7, row B2, rdb 0236). A box
// announces the files it follows and pushes their masked lines; the
// workspace is always the box session's (owner Q2 A: the workspace the box
// is pinned in), so every call names the tenant and the box and runs in that
// tenant's scope. The only cross-workspace read is the count of workspaces
// that stream (FileStreamLimits.MaxWorkspaces), a number, never a row of
// another workspace; nothing here prunes another workspace's lines (spec 160
// 3.7, review N2).

// Defaults of spec 160 3.7; B7 measures them and the cnf may set others.
const (
	FileStreamsMaxLinesPerWorkspace = 500_000
	FileStreamsMaxBytesPerWorkspace = 256 << 20
	FileStreamsMaxWorkspaces        = 4
	FileStreamsRatePerMin           = 600
	// FileStreamsRetention is owner Q3 A: 7 days (the sweep is row B6).
	FileStreamsRetention = 7 * 24 * time.Hour
	// fileStreamFuture is how far ahead of the hub's clock a line's time may
	// be (box clock skew); a later one is stored at the hub's now.
	fileStreamFuture = 2 * time.Minute
)

// The refusal reasons the hub sets on a stream (file_streams.reason). A
// stream the box itself refused carries no hub reason.
const (
	FileStreamReasonPerBox     = "streams_per_box"
	FileStreamReasonWorkspaces = "max_workspaces"
)

// ErrFileStreamUnknown: a push for a stream key the box never announced
// (409 not_announced; the follower announces at start and on a change).
var ErrFileStreamUnknown = errors.New("store: file stream not announced")

// ErrFileStreamRefused: a push for a stream the hub refused at announce, over
// a limit of 3.7 (403 refused).
var ErrFileStreamRefused = errors.New("store: file stream refused by a hub limit")

// ErrFileStreamRate: a push that takes one minute of the stream over twice
// the line rate (spec 160 3.7; 429 rate_limited). Nothing of it is stored.
var ErrFileStreamRate = errors.New("store: file stream over twice its line rate")

// FileStreamLimits are the hub's caps (spec 160 3.7). A zero field reads as
// its default (Norm).
type FileStreamLimits struct {
	PerBox        int
	MaxWorkspaces int
	MaxLines      int64
	MaxBytes      int64
	RatePerMin    int
}

// Norm fills every zero field with its default.
func (l FileStreamLimits) Norm() FileStreamLimits {
	if l.PerBox <= 0 {
		l.PerBox = wire.FileStreamsPerBox
	}
	if l.MaxWorkspaces <= 0 {
		l.MaxWorkspaces = FileStreamsMaxWorkspaces
	}
	if l.MaxLines <= 0 {
		l.MaxLines = FileStreamsMaxLinesPerWorkspace
	}
	if l.MaxBytes <= 0 {
		l.MaxBytes = FileStreamsMaxBytesPerWorkspace
	}
	if l.RatePerMin <= 0 {
		l.RatePerMin = FileStreamsRatePerMin
	}
	return l
}

// FileStream is one file_streams row.
type FileStream struct {
	ID           string
	Tenant       string
	Box          string
	StreamKey    string
	Path         string
	State        string
	Reason       string
	FirstSeenAt  time.Time
	AnnouncedAt  time.Time
	LastLineAt   *time.Time
	LastSeq      int64
	LinesTotal   int64
	LinesDropped int64
	LinesKept    int64
	BytesKept    int64
	Redactions   map[string]int64
}

// FileStreamLine is one stored line.
type FileStreamLine struct {
	StreamID string
	Seq      int64
	At       time.Time
	Text     string
	Marker   bool
}

// FileStreamPushResult is what one push did: the lines it wrote (a re-sent
// seq is not written again), the lines it skipped as older than the
// retention, the workspace's oldest lines it pruned to fit the caps, and the
// highest seq of the push (acked whether written or not).
type FileStreamPushResult struct {
	StreamID string
	Inserted int
	Expired  int
	Pruned   int
	AckedSeq int64
}

// FileStreamStore is the hub's file streams store (rdb 0236).
type FileStreamStore interface {
	// AnnounceFileStreams stores box's current list in tenant: an upsert per
	// key, the keys past lim.PerBox refused, every key refused when tenant
	// would be a workspace past lim.MaxWorkspaces, and the box's stored keys
	// not in the list set gone. It answers each listed key's kept state;
	// ErrNotFound when box never said hello in tenant (no boxes row).
	AnnounceFileStreams(ctx context.Context, tenant, box string, in []wire.FileStreamAnnounced, lim FileStreamLimits, now time.Time) ([]wire.FileStreamAckState, error)
	// RecordFileStreamLines stores one push (checked by
	// wire.DecodeFileStreamsPush) of box's stream in tenant, in one
	// transaction: the insert, the rate check (over it, nothing is kept),
	// the counts, then tenant's own oldest lines pruned until the workspace
	// is within lim.
	RecordFileStreamLines(ctx context.Context, tenant, box string, p wire.FileStreamsPushFrame, lim FileStreamLimits, now time.Time) (FileStreamPushResult, error)
	// ListFileStreams is tenant's streams, by box then key.
	ListFileStreams(ctx context.Context, tenant string) ([]FileStream, error)
	// FileStreamLinesAfter is up to limit lines of stream id in tenant with
	// seq > after, oldest first (row B3 reads it for the tab); ErrNotFound
	// for a stream that is not tenant's.
	FileStreamLinesAfter(ctx context.Context, tenant, id string, after int64, limit int) ([]FileStreamLine, error)
}

// fileStreamAnnouncePlan is the kept state of each announced key: the box's
// own state, refused past lim.PerBox (in the box's order), and every key
// refused when the workspace may not stream.
func fileStreamAnnouncePlan(in []wire.FileStreamAnnounced, lim FileStreamLimits, workspaceOK bool) []wire.FileStreamAckState {
	out := make([]wire.FileStreamAckState, len(in))
	for i, s := range in {
		out[i] = wire.FileStreamAckState{StreamKey: s.StreamKey, State: s.State}
		switch {
		case !workspaceOK:
			out[i].State, out[i].Reason = wire.FileStreamRefused, FileStreamReasonWorkspaces
		case i >= lim.PerBox:
			out[i].State, out[i].Reason = wire.FileStreamRefused, FileStreamReasonPerBox
		}
	}
	return out
}

// fileStreamAnnounceStreams says whether an announce makes tenant a
// streaming workspace: a key following or missing (a refused-only list does
// not count against MaxWorkspaces).
func fileStreamAnnounceStreams(in []wire.FileStreamAnnounced) bool {
	for _, s := range in {
		if s.State == wire.FileStreamFollowing || s.State == wire.FileStreamMissing {
			return true
		}
	}
	return false
}

// fileStreamPrepare is the push's lines as stored: a time ahead of the hub's
// clock by more than fileStreamFuture becomes now, a line older than the
// retention is skipped (counted, and still acked). acked is the push's
// highest seq.
func fileStreamPrepare(lines []wire.FileStreamLine, now time.Time) (keep []wire.FileStreamLine, expired int, acked int64) {
	keep = make([]wire.FileStreamLine, 0, len(lines))
	for _, l := range lines {
		acked = max(acked, l.Seq)
		switch {
		case l.At.Before(now.Add(-FileStreamsRetention)):
			expired++
			continue
		case l.At.After(now.Add(fileStreamFuture)):
			l.At = now
		}
		keep = append(keep, l)
	}
	return keep, expired, acked
}

// fileStreamWindow is the UTC minutes [from, to) that hold the lines.
func fileStreamWindow(lines []wire.FileStreamLine) (from, to time.Time) {
	for i, l := range lines {
		m := l.At.UTC().Truncate(time.Minute)
		if i == 0 || m.Before(from) {
			from = m
		}
		if i == 0 || !m.Before(to) {
			to = m.Add(time.Minute)
		}
	}
	return from, to
}

// fileStreamOverRate: a minute of the stream holds more than twice the rate
// once the push is in (spec 160 3.7: the box drops past the rate, the hub
// refuses past twice it). Counted after the insert, so a re-sent seq, which
// is not written again, never counts twice.
func fileStreamOverRate(perMinute map[time.Time]int, lim FileStreamLimits) bool {
	for _, n := range perMinute {
		if n > 2*lim.RatePerMin {
			return true
		}
	}
	return false
}
