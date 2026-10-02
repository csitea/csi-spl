package store

import (
	"context"
	"regexp"
	"sort"
	"time"
)

// Channels, box subscriptions and channel stats (specs/003
// contracts/channels-v1.md, FR-024..FR-027; rdb 0002 + 0008).

// Default channels every tenant has (channels-v1 §1). They are always known,
// even for a tenant whose rows were never seeded.
const (
	ChannelLobby  = "lobby"
	ChannelAlerts = "alerts"
	// ChannelFeedback is where any member tags the business owner(s) with
	// feedback (owner, 2026-09-25; channels-v1 §1).
	ChannelFeedback = "feedback"
	// ChannelGeneralAlias is the pre-M3 lobby name: an input alias only (C3).
	ChannelGeneralAlias = "general"
	// ChannelIssues is where every issue's discussion is stored (specs/039
	// §3.4, rdb 0050): a reserved channel id that is NOT a channel. It has no
	// channels row, is never listed, cannot be created and takes no agents;
	// every member of the tenant reads it, as they read the issue list.
	// #tasks held these discussions until the owner removed it (2026-09-26:
	// "the tasks channel should be removed - issues should be used for it").
	ChannelIssues = "issues"
	// ChannelTasks is the retired #tasks. rdb 0050 moves its messages (issue
	// discussions to ChannelIssues, the rest to #lobby) and deletes its rows;
	// the hub rolls BEFORE that migration, so until then it must still read
	// the old issue threads here. It stays hidden and public, and can never
	// be created again (a new #tasks would inherit stray old messages).
	ChannelTasks = "tasks"
)

// DefaultChannels in display order.
var DefaultChannels = []string{ChannelLobby, ChannelAlerts, ChannelFeedback}

// PublicChannels are the channel ids every member of a tenant reads without
// a membership row: the defaults and the issue discussions. The read doors
// hand this list to SQL; the channel list and the seeding use DefaultChannels.
var PublicChannels = append(append([]string{}, DefaultChannels...), ChannelIssues, ChannelTasks)

// ChannelHidden reports whether id is stored on messages but is not a
// channel anyone lists: the issue discussions and the retired #tasks.
func ChannelHidden(id string) bool { return id == ChannelIssues || id == ChannelTasks }

var channelRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)

// ValidChannelID reports whether s is a channel slug (= channels.channel_id).
func ValidChannelID(s string) bool { return channelRe.MatchString(s) }

// IsDefaultChannel reports whether id is one of DefaultChannels.
func IsDefaultChannel(id string) bool {
	for _, d := range DefaultChannels {
		if d == id {
			return true
		}
	}
	return false
}

// ChannelReserved reports whether id can never be a created channel: a
// default, the lobby alias, the issue discussions or the retired #tasks.
func ChannelReserved(id string) bool {
	return id == ChannelGeneralAlias || ChannelHidden(id) || IsDefaultChannel(id)
}

// NormalizeChannel maps the general alias to lobby; anything else unchanged.
func NormalizeChannel(id string) string {
	if id == ChannelGeneralAlias {
		return ChannelLobby
	}
	return id
}

// Channel is one channels row.
type Channel struct {
	// ArchivedAt / ArchivedBy are set only on an archived row (rdb 0092),
	// which no live read of Channels returns: they hide the channel while its
	// slug stays reserved. ArchivedChannel is the one read that returns them.
	ArchivedAt time.Time
	ArchivedBy string
	TenantID   string
	ChannelID  string
	Name       string
	// Description is what the channel is for, as the creator typed it next to
	// the title (rdb 0027). Empty when none was given; never NULL.
	Description string
	// MembersOpenInvite is the setting "everyone can invite new members"
	// (rdb 0031). Off (false, the default, and the value of a missing row)
	// means only the channel owner may add a member. On means every current
	// member may. A created_by of "hub" or "wui" is not an owner.
	MembersOpenInvite bool
	CreatedBy         string
	CreatedAt         time.Time
}

// ReadMark is a reader's last-read position in a channel: a view cursor.
type ReadMark struct {
	At    time.Time
	MsgID string
}

// OwnLine reports whether a line (its from_id, typed_by) is the reader's
// own, which is never unread for them (CLE-77889, owner t1 99905c80: "they
// should be shown as new for the receiver of those msgs, but not me"): they
// sent it, or typed it at an agent's terminal. Against a read mark both count;
// a channel with no mark skips from_id only, which keeps its count on the
// covering index (rdb 0080 INCLUDEs from_id, not typed_by).
func OwnLine(fromID, typedBy, reader string, marked bool) bool {
	if reader == "" {
		return false
	}
	return fromID == reader || (marked && typedBy == reader)
}

// ChannelStat is one row of GET /v1/view/channels (channels-v1 §5.2).
type ChannelStat struct {
	Channel
	Default   bool
	Count     int       // messages in retention
	LastAt    time.Time // zero: empty channel
	LastMsgID string
	Unread    int // messages after the reader's ReadMark (all when none)
	Agents    int // subscribed (agent, box) pairs; a default channel: invited ones only
	Boxes     int // distinct boxes of those agents
	Posters   int // distinct from ids in retention
}

// ChannelActivity is when a channel last changed: its newest message, else the
// moment it was created. A channel nobody has posted in yet is still new, so a
// channel created seconds ago outranks one that has been quiet for a week.
func ChannelActivity(st ChannelStat) time.Time {
	if st.LastAt.After(st.CreatedAt) {
		return st.LastAt
	}
	return st.CreatedAt
}

// SortChannelStats orders newest activity first (CLE-3425: the WUI sidebar, and
// any other client, renders the answer in the order it arrives). Channels
// nothing is known about - a default channel of a fresh tenant - keep a stable
// a-z tail, and a-z also breaks a tie.
func SortChannelStats(out []ChannelStat) {
	sort.Slice(out, func(i, j int) bool {
		a, b := ChannelActivity(out[i]), ChannelActivity(out[j])
		if !a.Equal(b) {
			return a.After(b)
		}
		return out[i].ChannelID < out[j].ChannelID
	})
}

// Channels is the store side of channels-v1. Memory and Postgres implement it.
type Channels interface {
	// CreateChannel inserts a channel; ErrConflict when it exists, is a
	// default or is the general alias.
	CreateChannel(ctx context.Context, c Channel) error
	// Channel returns one channels row. ErrNotFound when the tenant has no
	// such created channel. A default channel that was never seeded still
	// answers a row (CreatedBy "hub", MembersOpenInvite false), the same
	// answer ChannelKnown gives.
	Channel(ctx context.Context, tenantID, channelID string) (Channel, error)
	// SetMembersOpenInvite stores the invite setting (rdb 0031).
	// ErrConflict on a default channel. ErrNotFound when it is absent.
	SetMembersOpenInvite(ctx context.Context, tenantID, channelID string, open bool) error
	// ChannelKnown: a default channel or a created one of the tenant.
	ChannelKnown(ctx context.Context, tenantID, channelID string) (bool, error)
	// SetSubscriptions takes one box announce. It seats NO agent in any
	// channel: the default ones never took announce seats (owner
	// decision 2026-09-25, channels-v1 §7.4) and every created channel is
	// members-only, joined by invite alone, so a box cannot name its way into
	// a private channel. It clears the rows an older hub seated by announce;
	// rows a member invited (origin invite) or removed (origin removed) stay.
	SetSubscriptions(ctx context.Context, tenantID, boxID string, agents, channels []string, now time.Time) error
	// InviteChannelAgent records one agent on one box as a member of the
	// channel, a default channel included. ErrConflict on an invalid id.
	// ErrNotFound when the channel does not exist. A later announce does not
	// remove the row.
	InviteChannelAgent(ctx context.Context, tenantID, channelID, boxID, agentID string, now time.Time) error
	// RemoveChannelAgent keeps the agent out of the channel. A later
	// announce does not put the row back. ErrConflict on an invalid id.
	// ErrNotFound when the channel does not exist.
	RemoveChannelAgent(ctx context.Context, tenantID, channelID, boxID, agentID string, now time.Time) error
	// ChannelMembers returns box → sorted agent ids subscribed to channelID.
	// Invited agents are included. A default channel has only the agents a
	// member invited: none until someone adds one.
	ChannelMembers(ctx context.Context, tenantID, channelID string) (map[string][]string, error)
	// DeleteChannel HARD-deletes a created channel (HUM-10 bug, topic
	// ee21db20): its channels row, its members and agent seats (channel_humans
	// / channel_subscriptions cascade, rdb 0002 + 0028) and its messages are
	// removed in one transaction, so the slug is FREE again - a new channel of
	// the same id inherits no topic, member or message. ErrConflict on a
	// default channel; ErrNotFound when absent. Who may call it is the hub's
	// rule, not the store's.
	DeleteChannel(ctx context.Context, tenantID, channelID, by string, now time.Time) error
	// ArchiveChannel hides a created channel and reserves its name (rdb 0092,
	// SPL feature topic 32ea1b81): it stamps channels.archived_at/archived_by
	// and stamps the same archived_at/archived_by on every not-yet-archived
	// topic card of the channel (rdb 0065), so the channel and its topics move
	// to the Archive view. From then on the channel is absent to every live
	// read of this interface and of ChannelHumans - Channel and
	// SetMembersOpenInvite answer ErrNotFound, ChannelKnown false,
	// ChannelMembers / ChannelHumanMembers none, HumanChannels and
	// ViewChannelStats omit it - while its slug stays taken (CreateChannel
	// ErrConflict) so a new channel cannot collide. ErrConflict on a default
	// channel; ErrNotFound when absent or already archived.
	ArchiveChannel(ctx context.Context, tenantID, channelID, by string, now time.Time) error
	// UnarchiveChannel undoes ArchiveChannel: the channel returns and the topic
	// cards THIS archive stamped (archived_at equal to the channel's) are
	// un-archived; a card archived on its own before the channel archive keeps
	// its earlier stamp and stays archived. Members, agents and the messages
	// still in retention come back as they were. ErrNotFound when the channel
	// is not an archived one.
	UnarchiveChannel(ctx context.Context, tenantID, channelID string) error
	// ArchivedChannel returns an archived channel's row (ArchivedAt/ArchivedBy
	// set), ok=false when the tenant has no archived channel of that id. The
	// one read that sees past the archive flag - the create handler uses it to
	// tell "reserved: archived" apart from a live conflict.
	ArchivedChannel(ctx context.Context, tenantID, channelID string) (Channel, bool, error)
	// ViewChannelStats lists defaults, created and seen channels with counts,
	// unread (per reads) and member stats. Read-only (FR-019). reader is the
	// reading member (HUM-*, "" = none): their own lines are never unread
	// (CLE-77889, see OwnLine). lobby is the lobby task id ("" = none): a
	// line the channel feed hides as archived (specs/041, archivedHideSQL) is
	// never unread either (CLE-77930).
	ViewChannelStats(ctx context.Context, tenantID string, now time.Time, reads map[string]ReadMark, reader, lobby string) ([]ChannelStat, error)
}

var (
	_ Channels = (*Memory)(nil)
	_ Channels = (*Postgres)(nil)
)
