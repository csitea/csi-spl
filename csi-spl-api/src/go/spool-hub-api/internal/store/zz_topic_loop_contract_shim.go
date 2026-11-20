package store

// SHIM, never pushed: spec 182 v0.3 section 7.1.1 verbatim, so row L2
// builds before row L1 lands. Dropped before the rebase onto L1.

import (
	"context"
	"errors"
	"time"
)

// The twelve trigger names and the limits of spec 182 section 7.1.1.
const (
	LoopAfterAgentReply    = "after_agent_reply"
	LoopBeforeAgentReply   = "before_agent_reply"
	LoopAfterHumanReply    = "after_human_reply"
	LoopBeforeHumanReply   = "before_human_reply"
	LoopEveryHour          = "every_hour"
	LoopEveryNMinutes      = "every_n_minutes"
	LoopPostHasKeyword     = "post_has_keyword"
	LoopPostHasFile        = "post_has_file"
	LoopBlockerPosted      = "blocker_posted"
	LoopNoReplyAfterHuman  = "no_reply_after_human"
	LoopIssueStatusChanged = "issue_status_changed"
	LoopDailyAt            = "daily_at"
	TopicLoopKeywordMax    = 200
	TopicLoopIntervalMin   = 5    // minutes
	TopicLoopIntervalMax   = 1440 // minutes
	TopicLoopOn            = "on"
	TopicLoopPaused        = "paused"
	TopicLoopPromptMax     = 4000 // characters, rdb CHECK
)

// TopicLoopTriggers lists every known trigger name.
var TopicLoopTriggers = []string{LoopAfterAgentReply, LoopBeforeAgentReply,
	LoopAfterHumanReply, LoopBeforeHumanReply, LoopEveryHour, LoopEveryNMinutes,
	LoopPostHasKeyword, LoopPostHasFile, LoopBlockerPosted, LoopNoReplyAfterHuman,
	LoopIssueStatusChanged, LoopDailyAt}

// ErrBadTopicLoop rejects a loop that breaks the 7.1.1 limits.
var ErrBadTopicLoop = errors.New("store: a topic loop needs a prompt (1..4000 characters), 1..6 known triggers, an interval of 5..1440 minutes exactly with every_n_minutes, state on|paused and who (1..64)")

// TopicLoop is one loop row of a topic.
type TopicLoop struct {
	TenantID    string
	LoopID      string
	TaskID      string
	Prompt      string
	Triggers    []string
	SetBy       string
	SetAt       time.Time
	State       string
	HourStart   time.Time
	FiresInHour int
	FiresTotal  int
	LastFiredAt time.Time
	IntervalMin int
	NextDueAt   time.Time
	Awaiting    string
	AwaitUntil  time.Time
	Keyword     string
	IdleMin     int
	IdleDueAt   time.Time
	IdlePost    string
	DailyAt     string
	DailyTZ     string
	DailyDueAt  time.Time
	Due         []string
}

// TopicLoopEdit carries the fields an edit changes; nil keeps a field.
type TopicLoopEdit struct {
	Prompt   *string
	Triggers []string
	Interval *int
	State    *string
	Keyword  *string
	IdleMin  *int
	DailyAt  *string
	DailyTZ  *string
	By       string
	At       time.Time
}

// TopicLoopStore is the L1 store contract the hub calls.
type TopicLoopStore interface {
	TopicLoops(ctx context.Context, tenant, taskID string) ([]TopicLoop, error)
	TopicLoopsOn(ctx context.Context, tenant, taskID string) ([]TopicLoop, error)
	AddTopicLoop(ctx context.Context, tenant string, l TopicLoop) (TopicLoop, error)
	EditTopicLoop(ctx context.Context, tenant, taskID, loopID string, e TopicLoopEdit) (TopicLoop, error)
	DeleteTopicLoop(ctx context.Context, tenant, taskID, loopID string) (bool, error)
	DeleteTopicLoops(ctx context.Context, tenant, taskID string) (int, error)
	CountTopicLoopFire(ctx context.Context, tenant, loopID string, at time.Time, cap int) (TopicLoop, bool, error)
	ClaimDueTopicLoops(ctx context.Context, at time.Time, limit int) ([]TopicLoop, error)
	SetTopicLoopAwaiting(ctx context.Context, tenant, loopID, agent string, until time.Time) error
	TenantHasTopicLoops(ctx context.Context, tenant string) (bool, error)
	ArmTopicLoopIdle(ctx context.Context, tenant, taskID, postID string, at time.Time) (int, error)
	ClearTopicLoopIdle(ctx context.Context, tenant, taskID string) (int, error)
}
