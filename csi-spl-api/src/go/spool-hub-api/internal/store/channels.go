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
	TenantID  string
	ChannelID string
	Name      string
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
	// channel (CLE-34986): the default ones never took announce seats (owner
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
	// ViewChannelStats lists defaults, created and seen channels with counts,
	// unread (per reads) and member stats. Read-only (FR-019).
	ViewChannelStats(ctx context.Context, tenantID string, now time.Time, reads map[string]ReadMark) ([]ChannelStat, error)
}

var (
	_ Channels = (*Memory)(nil)
	_ Channels = (*Postgres)(nil)
)
