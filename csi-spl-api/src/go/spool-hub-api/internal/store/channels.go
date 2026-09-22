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
	ChannelTasks  = "tasks"
	ChannelAlerts = "alerts"
	// ChannelGeneralAlias is the pre-M3 lobby name: an input alias only (C3).
	ChannelGeneralAlias = "general"
)

// DefaultChannels in display order.
var DefaultChannels = []string{ChannelLobby, ChannelTasks, ChannelAlerts}

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
	CreatedBy   string
	CreatedAt   time.Time
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
	Agents    int // subscribed (agent, box) pairs; lobby: every announced agent
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
	// ChannelKnown: a default channel or a created one of the tenant.
	ChannelKnown(ctx context.Context, tenantID, channelID string) (bool, error)
	// SetSubscriptions replaces box's subscriptions: every agent × every known
	// channel in channels (unknown ids and lobby are skipped; lobby is implicit).
	SetSubscriptions(ctx context.Context, tenantID, boxID string, agents, channels []string, now time.Time) error
	// ChannelMembers returns box → sorted agent ids subscribed to channelID
	// (lobby: the whole announced roster).
	ChannelMembers(ctx context.Context, tenantID, channelID string) (map[string][]string, error)
	// ViewChannelStats lists defaults, created and seen channels with counts,
	// unread (per reads) and member stats. Read-only (FR-019).
	ViewChannelStats(ctx context.Context, tenantID string, now time.Time, reads map[string]ReadMark) ([]ChannelStat, error)
}

var (
	_ Channels = (*Memory)(nil)
	_ Channels = (*Postgres)(nil)
)
