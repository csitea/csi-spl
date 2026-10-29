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
)

// LogEventKinds is every kind above, in that order.
var LogEventKinds = []string{
	LogKindDeleted,
	LogKindLeaseClaim, LogKindLeaseRotation, LogKindLeaseSeatMove, LogKindLeaseFailover,
	LogKindLeaseHandback, LogKindLeaseVendor, LogKindLeaseLimit, LogKindHubStarted,
	LogKindMemberInvited, LogKindMemberInviteRevoked, LogKindMemberRoleChanged, LogKindMemberRemoved,
	LogKindChannelDeleted, LogKindJoinMinted, LogKindJoinRevoked, LogKindPinRevoked,
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
}

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
