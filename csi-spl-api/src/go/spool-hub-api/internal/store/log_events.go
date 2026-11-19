package store

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"time"
	"unicode/utf8"
)

// The Workspace and System logs of the event log (spec 162 v1.0 section 3.1,
// row B3; rdb 0240_workspace_system_events.sql). workspace_events is a tenant
// table under RLS, read and deleted by the workspace's owner and admins;
// system_events is hub-wide like human_events, read and deleted by the admins
// of the operator workspace. Both share one row shape, LogEvent. The hub's
// own log (Mine) stays human_events.go.

// WorkspaceEventsKeep / SystemEventsKeep are how many rows each log keeps;
// older ones are deleted on insert (spec 162 D6).
const (
	WorkspaceEventsKeep = 5000
	SystemEventsKeep    = 10000
)

// LogEventsDeleteMax is the most ids one delete may name (spec 162 3.2).
const LogEventsDeleteMax = 200

// The kinds the hub writes, one const each (spec 162 3.1: the column checks
// a pattern, this list is the hub's; TestLogEventKinds pins it). Each is a
// translation key on the WUI, events.kind.<kind>.
const (
	// LogKindDeleted is the trace a delete leaves in its own log (3.1).
	LogKindDeleted = "log.deleted"
	// System log (3.3): a lease handover, by the reason the loop names, and
	// the hub's start.
	LogKindLeaseClaim    = "lease.claim"
	LogKindLeaseRotation = "lease.rotation"
	LogKindLeaseSeatMove = "lease.seat_move"
	LogKindLeaseFailover = "lease.failover"
	LogKindLeaseHandback = "lease.handback"
	LogKindLeaseVendor   = "lease.vendor"
	LogKindLeaseLimit    = "lease.limit"
	LogKindHubStarted    = "hub.started"
	// Workspace log (3.4): the first set of producers.
	LogKindMemberInvited       = "member.invited"
	LogKindMemberInviteRevoked = "member.invite_revoked"
	LogKindMemberRoleChanged   = "member.role_changed"
	LogKindMemberRemoved       = "member.removed"
	LogKindChannelDeleted      = "channel.deleted"
	LogKindJoinMinted          = "box.join_token_minted"
	LogKindJoinRevoked         = "box.join_token_revoked"
	LogKindPinRevoked          = "box.pin_revoked"
	// System log, backend errors (spec 162 10.3): each is an error group,
	// one row for life (UpsertSystemErrorGroup). Source (a), the hub itself:
	LogKindErrHTTPServer = "error.http_server"
	LogKindErrPanic      = "error.panic"
	LogKindErrLoopPanic  = "error.loop_panic"
	LogKindErrLog        = "error.log"
	// Source (b), the box reader from Cloud Logging:
	LogKindErrGoFatal       = "error.go_fatal"
	LogKindErrCloudRunOOM   = "error.cloudrun_oom"
	LogKindErrCloudRunCrash = "error.cloudrun_crash"
	LogKindErrCloudRunStart = "error.cloudrun_start"
	LogKindErrCloudRunReq   = "error.cloudrun_request"
	LogKindErrCloudLogOther = "error.cloudlog_other"
	LogKindEvlogOverflow    = "evlog.overflow"
)

// LogEventKinds is every kind above, in that order.
var LogEventKinds = []string{
	LogKindDeleted,
	LogKindLeaseClaim, LogKindLeaseRotation, LogKindLeaseSeatMove, LogKindLeaseFailover,
	LogKindLeaseHandback, LogKindLeaseVendor, LogKindLeaseLimit, LogKindHubStarted,
	LogKindMemberInvited, LogKindMemberInviteRevoked, LogKindMemberRoleChanged, LogKindMemberRemoved,
	LogKindChannelDeleted, LogKindJoinMinted, LogKindJoinRevoked, LogKindPinRevoked,
	LogKindErrHTTPServer, LogKindErrPanic, LogKindErrLoopPanic, LogKindErrLog,
	LogKindErrGoFatal, LogKindErrCloudRunOOM, LogKindErrCloudRunCrash, LogKindErrCloudRunStart,
	LogKindErrCloudRunReq, LogKindErrCloudLogOther, LogKindEvlogOverflow,
}

// The levels (rdb 0240's level CHECK).
const (
	LogLevelInfo  = "info"
	LogLevelWarn  = "warn"
	LogLevelError = "error"
)

// The origin kinds (rdb 0240's origin_kind CHECK; spec 162 E6).
const (
	LogOriginMsg       = "msg"
	LogOriginTopic     = "topic"
	LogOriginIssue     = "issue"
	LogOriginComponent = "component"
)

// LogEvent is one row of either log. Tenant is "" for a system row.
//
// The fields after OriginRef are the System log's error group (rdb 0298,
// spec 162 10.5) and are zero on a Workspace row. A plain System row has
// Fingerprint "", a zero FirstAt and N 1; an error group has its
// fingerprint, its first sighting in FirstAt and its last in At, and N
// counts the sightings.
type LogEvent struct {
	ID         int64
	Tenant     string
	At         time.Time
	Kind       string
	Level      string // "" = info
	Actor      string // HUM-*, <agent id>@<box>, or "hub"
	Message    string
	OriginKind string
	OriginRef  string

	Fingerprint string    // 16 hex of evlog.Fingerprint; "" = not a group
	FirstAt     time.Time // the group's first sighting
	N           int       // the sightings counted
	IssueKey    string    // the issue filed for the group, "" = none (10.7)
	IssueN      int       // N when the issue was linked
	HumanID     string    // the person of the last sighting that had one (Q4 B)
}

// EvlogCursor is how far the box reader of one env has read Cloud Logging
// (rdb 0298 system_events_cursor, spec 162 10.4.4). No row reads as a zero
// ReadUntil and Gen 0.
type EvlogCursor struct {
	Env       string // "dev" or "prd"
	ReadUntil time.Time
	Gen       int64
	ByActor   string // the box that moved it last
}

// EvlogPut is one put of the box reader: the error groups of the window
// [From, To) of Env, read at cursor generation Gen, by Actor.
type EvlogPut struct {
	Env      string
	Gen      int64
	From, To time.Time
	Actor    string
	Groups   []LogEvent // error groups, as UpsertSystemErrorGroup takes them
}

// EvlogPutMaxGroups is the most groups one put carries (evlog.CapReader,
// spec 162 10.4.5).
const EvlogPutMaxGroups = 500

// LogEvents is the store side of the two logs. Memory and Postgres implement it.
type LogEvents interface {
	// AddWorkspaceEvent stores e in tenant's log (At = now) and trims that
	// log to the newest WorkspaceEventsKeep rows, in one transaction. It
	// answers the stored row.
	AddWorkspaceEvent(ctx context.Context, tenant string, e LogEvent, now time.Time) (LogEvent, error)
	// WorkspaceEventsPage lists tenant's rows newest first: at most limit,
	// only ids below before when before > 0.
	WorkspaceEventsPage(ctx context.Context, tenant string, before int64, limit int) ([]LogEvent, error)
	// DeleteWorkspaceEvents deletes tenant's rows named in ids (another
	// tenant's id counts 0) and, when any went, writes one LogKindDeleted
	// row by actor, in one transaction. It answers how many rows went.
	DeleteWorkspaceEvents(ctx context.Context, tenant string, ids []int64, actor string, now time.Time) (int, error)
	// AddSystemEvent, SystemEventsPage and DeleteSystemEvents are the same
	// for the hub-wide log (SystemEventsKeep).
	AddSystemEvent(ctx context.Context, e LogEvent, now time.Time) (LogEvent, error)
	SystemEventsPage(ctx context.Context, before int64, limit int) ([]LogEvent, error)
	DeleteSystemEvents(ctx context.Context, ids []int64, actor string, now time.Time) (int, error)

	// UpsertSystemErrorGroup stores the error group e (spec 162 10.5): a
	// new fingerprint opens a row; a known one keeps its one row, adds e.N
	// to its count, keeps the earlier FirstAt, moves At to the later
	// sighting, takes e.Message, takes e.HumanID unless it is "", keeps
	// its issue, and gets a new id higher than every other, so the
	// newest-first page shows it on top and the keep-by-id trim keeps it.
	// The log is then trimmed as on AddSystemEvent. It answers the row.
	UpsertSystemErrorGroup(ctx context.Context, e LogEvent) (LogEvent, error)
	// SystemEventsCursor answers env's reader cursor.
	SystemEventsCursor(ctx context.Context, env string) (EvlogCursor, error)
	// PutSystemErrorGroups is the reader's compare-and-set (10.4.4): in one
	// transaction it checks p.Gen against the stored gen and p.From against
	// the stored read_until (no row: p.Gen must be 0), moves the cursor to
	// p.To with gen + 1, and upserts p.Groups. A stale cursor answers
	// ErrEvlogCursorMoved and changes nothing. It answers the new cursor.
	PutSystemErrorGroups(ctx context.Context, p EvlogPut) (EvlogCursor, error)
	// LinkSystemErrorGroup sets the issue of the group fingerprint and
	// records its count then (issue_n = n, 10.7); the id stays. An unknown
	// fingerprint is ErrNotFound.
	LinkSystemErrorGroup(ctx context.Context, fingerprint, issueKey string) (LogEvent, error)
}

// logKindRe is rdb 0240's kind CHECK.
var logKindRe = regexp.MustCompile(`^[a-z]+(\.[a-z_]+)+$`)

// ErrLogEventIDs: a delete named no id or more than LogEventsDeleteMax.
var ErrLogEventIDs = fmt.Errorf("log events: name 1..%d ids", LogEventsDeleteMax)

// normLogEvent fills the default level and applies rdb 0240's row checks, so
// a bad row is refused before the database sees it (and the memory store
// matches Postgres).
func normLogEvent(e LogEvent) (LogEvent, error) {
	if e.Level == "" {
		e.Level = LogLevelInfo
	}
	switch {
	case !logKindRe.MatchString(e.Kind) || len(e.Kind) > 48:
		return e, errors.New("log event: kind must be a dotted lowercase name of at most 48 characters")
	case e.Level != LogLevelInfo && e.Level != LogLevelWarn && e.Level != LogLevelError:
		return e, errors.New("log event: level must be info, warn or error")
	case e.OriginKind != "" && e.OriginKind != LogOriginMsg && e.OriginKind != LogOriginTopic &&
		e.OriginKind != LogOriginIssue && e.OriginKind != LogOriginComponent:
		return e, errors.New("log event: origin_kind must be msg, topic, issue or component")
	case (e.OriginKind == "") != (e.OriginRef == ""):
		return e, errors.New("log event: origin_kind and origin_ref are both set or both empty")
	}
	for _, c := range []struct {
		name, v string
		max     int
	}{{"actor", e.Actor, 64}, {"message", e.Message, 800}, {"origin_ref", e.OriginRef, 120}} {
		if !utf8.ValidString(c.v) || utf8.RuneCountInString(c.v) > c.max {
			return e, errors.New("log event: " + c.name + " is not valid UTF-8 or longer than its cap")
		}
	}
	return e, nil
}

// ErrEvlogCursorMoved: a reader's put named a gen or a from that is not
// the stored cursor's; another box read that window first (10.4.4).
var ErrEvlogCursorMoved = errors.New("log events: the reader cursor moved")

// rdb 0298's checks on the group columns.
var (
	groupFPRe    = regexp.MustCompile(`^[0-9a-f]{16}$`)
	issueKeyRe   = regexp.MustCompile(`^[A-Z][A-Z0-9]*-[0-9]+$`)
	groupHumanRe = regexp.MustCompile(`^(HUM-[0-9]+)?$`)
)

// plainSystemEvent is e as a plain System row: no group fields, N 1.
func plainSystemEvent(e LogEvent) LogEvent {
	e.Tenant, e.Fingerprint, e.FirstAt, e.N = "", "", time.Time{}, 1
	e.IssueKey, e.IssueN, e.HumanID = "", 0, ""
	return e
}

// normErrorGroup is normLogEvent plus rdb 0298's group checks: a
// fingerprint, both sightings with FirstAt <= At, N >= 1, a HUM-* or no
// person. The issue fields are the link's, never the upsert's: cleared.
func normErrorGroup(e LogEvent) (LogEvent, error) {
	e, err := normLogEvent(e)
	if err != nil {
		return e, err
	}
	e.Tenant, e.IssueKey, e.IssueN = "", "", 0
	e.At, e.FirstAt = e.At.UTC().Truncate(time.Microsecond), e.FirstAt.UTC().Truncate(time.Microsecond)
	switch {
	case !groupFPRe.MatchString(e.Fingerprint):
		return e, errors.New("error group: fingerprint must be 16 lowercase hex")
	case e.At.IsZero() || e.FirstAt.IsZero() || e.FirstAt.After(e.At):
		return e, errors.New("error group: first_at and at are both set, first_at not after at")
	case e.N < 1:
		return e, errors.New("error group: n must be at least 1")
	case !groupHumanRe.MatchString(e.HumanID) || len(e.HumanID) > 32:
		return e, errors.New("error group: human_id must be HUM-<n> or empty")
	}
	return e, nil
}

// checkEvlogPut applies the put's own rules before any group: a known env,
// a window that moves forward, at most EvlogPutMaxGroups groups, each one
// valid. It answers the groups normalised.
func checkEvlogPut(p EvlogPut) ([]LogEvent, error) {
	switch {
	case p.Env != "dev" && p.Env != "prd":
		return nil, errors.New("evlog put: env must be dev or prd")
	case p.Gen < 0 || p.To.IsZero() || !p.To.After(p.From):
		return nil, errors.New("evlog put: gen must be >= 0 and to after from")
	case len(p.Groups) > EvlogPutMaxGroups:
		return nil, fmt.Errorf("evlog put: at most %d groups", EvlogPutMaxGroups)
	case utf8.RuneCountInString(p.Actor) > 64:
		return nil, errors.New("evlog put: actor longer than 64")
	}
	out := make([]LogEvent, 0, len(p.Groups))
	for _, g := range p.Groups {
		g, err := normErrorGroup(g)
		if err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, nil
}

// checkEvlogLink is the link's rule: a fingerprint and an issue key.
func checkEvlogLink(fingerprint, issueKey string) error {
	if !groupFPRe.MatchString(fingerprint) || !issueKeyRe.MatchString(issueKey) || len(issueKey) > 40 {
		return errors.New("error group link: a 16-hex fingerprint and an issue key like SPL-1")
	}
	return nil
}

// checkLogEventIDs is the delete's id-count rule.
func checkLogEventIDs(ids []int64) error {
	if len(ids) == 0 || len(ids) > LogEventsDeleteMax {
		return ErrLogEventIDs
	}
	return nil
}

// logDeletedEvent is the trace row of a delete of n rows by actor (3.1).
func logDeletedEvent(n int, actor string) LogEvent {
	msg := fmt.Sprintf("%d rows deleted", n)
	if n == 1 {
		msg = "1 row deleted"
	}
	return LogEvent{Kind: LogKindDeleted, Level: LogLevelInfo, Actor: actor, Message: msg}
}

var (
	_ LogEvents = (*Memory)(nil)
	_ LogEvents = (*Postgres)(nil)
)
