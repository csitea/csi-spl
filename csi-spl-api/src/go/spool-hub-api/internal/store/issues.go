package store

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// A tenant's issues, the way Linear keeps them (rdb 0047, specs/039,
// CLE-34993). Numbers come from a per-tenant counter and are never reused;
// the key is <prefix>-<number> (SPL-12). The discussion is an ordinary topic
// on the issue's task_id. The hub never deletes an issue: Canceled is a status.

// Issue statuses, the owner's set (rdb 0055, topic f2c32da2), in the order
// of their numbered labels: 01-eval, 02-todo, 03-wip, 03-diss, 07-qas,
// 09-done. The older Go names stay as aliases so callers keep compiling.
const (
	IssueEval = "eval" // 01-eval: evaluation
	IssueTodo = "todo" // 02-todo
	IssueWIP  = "wip"  // 03-wip: work in progress
	IssueDiss = "diss" // 03-diss: discard (stamps canceled_at)
	// rdb 0061 (SPL-966, owner 2026-09-26): 05-blocked waits on something or
	// someone; 06-onhold is paused on purpose.
	IssueBlocked = "blocked" // 05-blocked
	IssueOnHold  = "onhold"  // 06-onhold
	IssueQAS     = "qas"     // 07-qas: quality assurance
	IssueDone    = "done"    // 09-done (stamps completed_at)

	IssueBacklog    = IssueEval
	IssueInProgress = IssueWIP
	IssueInReview   = IssueQAS
	IssueCanceled   = IssueDiss
)

// IssueStatuses is the workflow, in order.
var IssueStatuses = []string{IssueEval, IssueTodo, IssueWIP, IssueDiss, IssueBlocked, IssueOnHold, IssueQAS, IssueDone}

// legacyStatus maps a status of the first set (rdb 0047) to its successor:
// an agent or an older hub may still send one; rdb 0055 moved the rows.
var legacyStatus = map[string]string{"backlog": IssueEval, "in_progress": IssueWIP, "in_review": IssueQAS, "canceled": IssueDiss}

// NormalizeIssueStatus is s, or its successor when s is a first-set status.
func NormalizeIssueStatus(s string) string {
	if n, ok := legacyStatus[s]; ok {
		return n
	}
	return s
}

const (
	// "prio" (rdb 0054 + 0055, owner 2026-09-26): a plain number, 1 the highest,
	// 5 the lowest; a new issue starts at IssuePriorityDefault. The column
	// still admits 0 for the roll window; the store reads a 0 as 5.
	IssuePriorityMin     = 1
	IssuePriorityMax     = 5
	IssuePriorityDefault = 5
	// Level is the row's place in the tree (rdb 0056, owner 2026-09-26, SPL-949):
	// 1 epic / feature, 2 an issue, 3 a subtask. The store derives it; an input
	// level is only checked against the derived one.
	IssueLevelMin       = 1
	IssueLevelMax       = 3
	IssueTitleMax       = 255
	IssueDescriptionMax = 20000
	IssueLabelsMax      = 20
	IssueLabelNameMax   = 40
	// IssuePrefixDefault is the key prefix of a tenant that never set one.
	IssuePrefixDefault = "SPL"
)

// ErrInvalidIssue wraps every refused field; the message names the field.
var ErrInvalidIssue = errors.New("invalid issue")

// ErrUnknownLabel: a label id not in the tenant's catalogue.
var ErrUnknownLabel = errors.New("unknown issue label")

// ErrUnknownParent: the parent number is not an issue of the tenant.
var ErrUnknownParent = errors.New("unknown parent issue")

// Issue kinds (rdb 0053, SPL-18). Level 1 is an epic or a feature (no
// parent); every other issue is kind issue: level 2 under a level-1 row,
// level 3 (a subtask) under a level-2 issue. Three levels at most.
const (
	IssueKindEpic    = "epic"
	IssueKindFeature = "feature"
	IssueKindIssue   = "issue"
)

// IssueEpicLabel is the label that made an issue an epic (SPL-18,
// rdb 0049): an epic has no parent; every other issue has exactly one parent,
// and it is an epic.
const IssueEpicLabel = "epic"

// ErrEpicRequired: a non-epic issue without a parent epic. No longer
// returned since W16 (spec 047, SPL-1175): an issue may stand alone at
// level 2. Kept so older callers that map it still compile.
var ErrEpicRequired = errors.New("issue needs a parent epic")

// ErrBadEpic: the parent is neither a level-1 row nor a level-2 issue (or
// the move would make a fourth level), or a level-1 row was given a parent.
var ErrBadEpic = errors.New("parent must be an epic / feature or a level-2 issue; an epic has no parent")

// ErrEpicHasIssues: the epic label was dropped from an epic that still has issues.
var ErrEpicHasIssues = errors.New("epic still has issues")

// ErrIssueHasChildren: a delete of an issue that still has live children
// (SPL-1027): delete or move them first.
var ErrIssueHasChildren = errors.New("issue still has children")

var (
	issueAssigneeRe = regexp.MustCompile(`^[A-Z]{2,4}-[0-9]+$`)
	issueLabelIDRe  = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,39}$`)
	issueColorRe    = regexp.MustCompile(`^#[0-9a-f]{6}$`)
	issuePrefixRe   = regexp.MustCompile(`^[A-Z][A-Z0-9]{0,9}$`)
	labelSlugRe     = regexp.MustCompile(`[^a-z0-9]+`)
)

// Issue is one row of issues. Parent 0 = none. Deadline, CompletedAt and
// CanceledAt nil = unset.
type Issue struct {
	Kind        string // epic | feature | issue; "" on a create = epic when labelled epic, else issue
	TenantID    string
	Number      int
	Prefix      string // the tenant's key prefix at read time
	Title       string
	Description string
	Status      string
	Priority    int
	Level       int
	Assignee    string
	Labels      []string
	Deadline    *time.Time
	Parent      int
	TaskID      string
	CreatedBy   string
	CreatedAt   time.Time
	UpdatedBy   string
	UpdatedAt   time.Time
	CompletedAt *time.Time
	CanceledAt  *time.Time
}

// Key is <prefix>-<number>, e.g. SPL-12.
func (i Issue) Key() string { return IssueKey(i.Prefix, i.Number) }

// IsEpic reports a level-1 row: kind epic or feature (rdb 0053).
func (i Issue) IsEpic() bool { return i.Kind == IssueKindEpic || i.Kind == IssueKindFeature }

// treeRefs is what the tree rule needs to know about an issue's neighbours.
type treeRefs struct {
	parent       Issue
	parentOK     bool // the parent row exists
	parentLevel2 bool // the parent is a level-2 issue: under a level-1 row, or under none (W16)
	hasChildren  bool // some issue names this one as its parent
	wasEpic      bool // the row was level 1 before this update
}

// treeLevel is the level the tree gives i (rdb 0056), shared by both drivers.
// A non-epic row with no parent is 2 (W16: an issue needs no epic).
func treeLevel(i Issue, r treeRefs) int {
	switch {
	case i.IsEpic():
		return 1
	case !r.parentOK || r.parent.IsEpic():
		return 2
	}
	return 3
}

// setLevel derives i.Level from the tree. want is the caller's level, 0 when
// none was given: it must be the derived one.
func setLevel(i *Issue, r treeRefs, want int) error {
	i.Level = treeLevel(*i, r)
	if want != 0 && want != i.Level {
		return invalidIssue("level follows the tree (1 epic or feature, 2 issue, 3 subtask): this one is level %d", i.Level)
	}
	return nil
}

// patchLevel is the level a PATCH asks for, 0 when it names none. An explicit
// level outside 1..3 (the old 0 "none" too) is refused.
func patchLevel(p IssuePatch) (int, error) {
	if p.Level == nil {
		return 0, nil
	}
	if *p.Level < IssueLevelMin || *p.Level > IssueLevelMax {
		return 0, invalidIssue("level must be %d..%d", IssueLevelMin, IssueLevelMax)
	}
	return *p.Level, nil
}

// treeRule is the three-level rule (SPL-18), shared by both drivers.
func treeRule(i Issue, r treeRefs) error {
	if i.IsEpic() {
		if i.Parent != 0 {
			return ErrBadEpic
		}
		return nil
	}
	if r.wasEpic && r.hasChildren {
		return ErrEpicHasIssues
	}
	switch {
	case i.Parent == 0:
		return nil // level 2 without an epic (W16, spec 047)
	case !r.parentOK:
		return ErrUnknownParent
	case r.parent.IsEpic():
		return nil // level 2
	case r.parentLevel2 && !r.hasChildren:
		return nil // level 3: a subtask has no children
	}
	return ErrBadEpic
}

// IssueKey formats a key.
func IssueKey(prefix string, number int) string {
	if prefix == "" {
		prefix = IssuePrefixDefault
	}
	return prefix + "-" + strconv.Itoa(number)
}

// ParseIssueRef reads "SPL-12", "spl-12" or "12" into the number. The prefix
// is not checked against the tenant's: a tenant has one team for now.
func ParseIssueRef(ref string) (int, bool) {
	ref = strings.TrimSpace(ref)
	if i := strings.LastIndexByte(ref, '-'); i >= 0 {
		if !issuePrefixRe.MatchString(strings.ToUpper(ref[:i])) {
			return 0, false
		}
		ref = ref[i+1:]
	}
	n, err := strconv.Atoi(ref)
	if err != nil || n <= 0 || strconv.Itoa(n) != ref {
		return 0, false
	}
	return n, true
}

// IssuePatch is a partial update: nil leaves a field as it is. DeadlineSet
// with a nil Deadline clears it; Parent 0 clears the parent.
type IssuePatch struct {
	Kind        *string
	Title       *string
	Description *string
	Status      *string
	Priority    *int
	Level       *int
	Assignee    *string
	Labels      *[]string
	DeadlineSet bool
	Deadline    *time.Time
	Parent      *int
}

// Empty reports a patch that changes nothing.
func (p IssuePatch) Empty() bool {
	return p.Title == nil && p.Description == nil && p.Status == nil && p.Priority == nil && p.Level == nil &&
		p.Assignee == nil && p.Labels == nil && !p.DeadlineSet && p.Parent == nil && p.Kind == nil
}

// IssueLabel is one row of issue_labels.
type IssueLabel struct {
	TenantID  string
	LabelID   string
	Name      string
	Color     string
	CreatedBy string
	CreatedAt time.Time
}

// Issues is the issue half of the store contract (rdb 0047). Every call is
// scoped to one tenant; a tenant with no row reads as empty.
type Issues interface {
	// CreateIssue hands out the next number and stores in (its Number,
	// Prefix, timestamps and UpdatedBy are the store's). ErrInvalidIssue,
	// ErrUnknownLabel, ErrUnknownParent, the epic rule (ErrEpicRequired,
	// ErrBadEpic, ErrEpicHasIssues); ErrNotFound for an unknown tenant.
	CreateIssue(ctx context.Context, in Issue, now time.Time) (Issue, error)
	// UpdateIssue applies p. ErrNotFound for no such issue. A status change
	// into done / canceled stamps completed_at / canceled_at, out of it
	// clears them.
	UpdateIssue(ctx context.Context, tenantID string, number int, p IssuePatch, by string, now time.Time) (Issue, error)
	GetIssue(ctx context.Context, tenantID string, number int) (Issue, error)
	// ListIssues is every issue of the tenant, newest number first.
	ListIssues(ctx context.Context, tenantID string) ([]Issue, error)
	// IssuePrefix is the tenant's key prefix (IssuePrefixDefault when unset).
	IssuePrefix(ctx context.Context, tenantID string) (string, error)
	// SetIssuePrefix changes the prefix every key of the tenant renders with
	// (W16, spec 047); numbers stay. Upper-cased first; ErrInvalidIssue when
	// it is not 1..10 of A-Z0-9 starting with a letter, ErrNotFound for an
	// unknown tenant. Answers the stored prefix.
	SetIssuePrefix(ctx context.Context, tenantID, prefix string) (string, error)
	// ListIssueLabels is the catalogue sorted by name.
	ListIssueLabels(ctx context.Context, tenantID string) ([]IssueLabel, error)
	// CreateIssueLabel adds one; ErrConflict when the id exists.
	CreateIssueLabel(ctx context.Context, l IssueLabel, now time.Time) (IssueLabel, error)
	// DeleteIssue soft-deletes one (rdb 0071, SPL-1027) and answers the row
	// as it was. From then on every read, patch and parent lookup treats it
	// as absent. ErrNotFound for no such (live) issue, ErrIssueHasChildren
	// while a live issue names it as parent.
	DeleteIssue(ctx context.Context, tenantID string, number int, by string, now time.Time) (Issue, error)
	// DeleteIssueCascade soft-deletes an issue AND every live descendant
	// (its features, issues and subtasks) in one transaction (rdb 0084,
	// SPL-1226). Answers the target row as it was and the numbers of the
	// descendants also deleted (target excluded). ErrNotFound for no such
	// live issue.
	DeleteIssueCascade(ctx context.Context, tenantID string, number int, by string, now time.Time) (Issue, []int, error)
	// ArchiveIssue soft-archives one (rdb 0084): archived_at / archived_by
	// are stamped and, like a delete, every read, patch and parent lookup
	// then treats it as absent; unarchive clears both. cascade also archives
	// every live descendant in the same transaction. Answers the target as it
	// was and the numbers of the descendants also archived (target excluded).
	// ErrNotFound for no such live, unarchived issue; ErrIssueHasChildren when
	// cascade is false and a live issue names it as parent.
	ArchiveIssue(ctx context.Context, tenantID string, number int, by string, now time.Time, cascade bool) (Issue, []int, error)
	// UnarchiveIssue clears archived_at / archived_by, restoring an archived
	// issue (rdb 0084). cascade also restores every archived descendant.
	// Answers the target as it was (archived) and the descendant numbers also
	// restored. ErrNotFound for no such archived issue.
	UnarchiveIssue(ctx context.Context, tenantID string, number int, by string, now time.Time, cascade bool) (Issue, []int, error)
}

func invalidIssue(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalidIssue, fmt.Sprintf(format, a...))
}

// ValidIssueStatus reports a workflow status.
func ValidIssueStatus(s string) bool {
	for _, v := range IssueStatuses {
		if v == s {
			return true
		}
	}
	return false
}

// LabelSlug is the label id a name gets: lower case, runs of anything else
// as one dash, at most 40.
func LabelSlug(name string) string {
	s := strings.Trim(labelSlugRe.ReplaceAllString(strings.ToLower(name), "-"), "-")
	if len(s) > 40 {
		s = strings.TrimRight(s[:40], "-")
	}
	return s
}

// checkIssue validates the stored fields both drivers write (rdb 0047's
// checks, answered before the database has to).
func checkIssue(i *Issue) error {
	i.Status = NormalizeIssueStatus(i.Status)
	if i.Priority == 0 { // unset, or a row written before rdb 0055
		i.Priority = IssuePriorityDefault
	}
	i.Title = strings.TrimSpace(i.Title)
	switch {
	case i.Title == "" || utf8.RuneCountInString(i.Title) > IssueTitleMax:
		return invalidIssue("title must be 1..%d characters", IssueTitleMax)
	case !utf8.ValidString(i.Title) || !utf8.ValidString(i.Description):
		return invalidIssue("title and description must be UTF-8")
	case utf8.RuneCountInString(i.Description) > IssueDescriptionMax:
		return invalidIssue("description must be at most %d characters", IssueDescriptionMax)
	case !ValidIssueStatus(i.Status):
		return invalidIssue("status must be one of %s", strings.Join(IssueStatuses, ", "))
	case i.Priority < IssuePriorityMin || i.Priority > IssuePriorityMax:
		return invalidIssue("prio must be %d..%d", IssuePriorityMin, IssuePriorityMax)
	case i.Level != 0 && (i.Level < IssueLevelMin || i.Level > IssueLevelMax):
		return invalidIssue("level must be %d..%d", IssueLevelMin, IssueLevelMax)
	case i.Assignee != "" && !issueAssigneeRe.MatchString(i.Assignee):
		return invalidIssue("assignee must be a member or agent id")
	case i.Parent < 0 || (i.Parent != 0 && i.Parent == i.Number):
		return invalidIssue("parent must be another issue")
	case !canonUUIDRe.MatchString(i.TaskID):
		return invalidIssue("task_id must be a UUID")
	case len(i.CreatedBy) > 64 || len(i.UpdatedBy) > 64:
		return invalidIssue("actor id too long")
	}
	labels, err := normLabels(i.Labels)
	if err != nil {
		return err
	}
	i.Labels = labels
	if i.Kind == "" {
		i.Kind = IssueKindIssue
		for _, l := range labels {
			if l == IssueEpicLabel { // the label form of rdb 0049 still makes an epic
				i.Kind = IssueKindEpic
			}
		}
	}
	if i.Kind != IssueKindEpic && i.Kind != IssueKindFeature && i.Kind != IssueKindIssue {
		return invalidIssue("kind must be epic, feature or issue")
	}
	if i.Deadline != nil {
		d := i.Deadline.UTC().Truncate(time.Microsecond)
		i.Deadline = &d
	}
	return nil
}

// normLabels dedupes and sorts label ids and checks their shape.
func normLabels(in []string) ([]string, error) {
	seen := map[string]bool{}
	out := []string{}
	for _, l := range in {
		if !issueLabelIDRe.MatchString(l) {
			return nil, invalidIssue("label %q is not a label id", l)
		}
		if !seen[l] {
			seen[l] = true
			out = append(out, l)
		}
	}
	if len(out) > IssueLabelsMax {
		return nil, invalidIssue("at most %d labels", IssueLabelsMax)
	}
	sort.Strings(out)
	return out, nil
}

// ApplyIssuePatch writes p's fields onto i and nothing else (no clocks, no
// actor): the hub builds a create from the same request shape as a PATCH.
func ApplyIssuePatch(i *Issue, p IssuePatch) {
	if p.Kind != nil {
		i.Kind = *p.Kind
	}
	if p.Title != nil {
		i.Title = *p.Title
	}
	if p.Description != nil {
		i.Description = *p.Description
	}
	if p.Status != nil {
		i.Status = *p.Status
	}
	if p.Priority != nil {
		i.Priority = *p.Priority
	}
	if p.Level != nil {
		i.Level = *p.Level
	}
	if p.Assignee != nil {
		i.Assignee = *p.Assignee
	}
	if p.Labels != nil {
		i.Labels = append([]string(nil), (*p.Labels)...)
	}
	if p.DeadlineSet {
		i.Deadline = p.Deadline
	}
	if p.Parent != nil {
		i.Parent = *p.Parent
	}
}

// applyPatch writes p onto i and restamps the status clocks.
func applyPatch(i *Issue, p IssuePatch, by string, now time.Time) {
	if p.Status != nil {
		st := NormalizeIssueStatus(*p.Status)
		p.Status = &st
	}
	changed := p.Status != nil && *p.Status != i.Status
	ApplyIssuePatch(i, p)
	if changed {
		stampStatus(i, now)
	}
	i.UpdatedBy, i.UpdatedAt = by, now
}

// epicTouched: an update checks the epic rule only when it changes the parent
// or the labels, so a row written before the rule (an issue created by an
// older hub between rdb 0049 and the roll) stays editable until someone
// gives it an epic.
func epicTouched(p IssuePatch) bool { return p.Parent != nil || p.Labels != nil || p.Kind != nil }

// stampStatus sets completed_at / canceled_at for the status i now has.
func stampStatus(i *Issue, now time.Time) {
	i.CompletedAt, i.CanceledAt = nil, nil
	switch i.Status {
	case IssueDone:
		t := now
		i.CompletedAt = &t
	case IssueCanceled:
		t := now
		i.CanceledAt = &t
	}
}

// checkLabel validates a new catalogue row and derives its id.
func checkLabel(l *IssueLabel) error {
	l.Name = strings.TrimSpace(l.Name)
	if l.Name == "" || utf8.RuneCountInString(l.Name) > IssueLabelNameMax {
		return invalidIssue("label name must be 1..%d characters", IssueLabelNameMax)
	}
	if l.LabelID == "" {
		l.LabelID = LabelSlug(l.Name)
	}
	if !issueLabelIDRe.MatchString(l.LabelID) {
		return invalidIssue("label name needs a letter or digit")
	}
	l.Color = strings.ToLower(strings.TrimSpace(l.Color))
	if l.Color == "" {
		l.Color = "#6b7280"
	}
	if !issueColorRe.MatchString(l.Color) {
		return invalidIssue("label color must be #rrggbb")
	}
	if len(l.CreatedBy) > 64 {
		return invalidIssue("actor id too long")
	}
	return nil
}

// ---- memory driver -------------------------------------------------------------

// memIssues is Memory's copy of rdb 0047, guarded by Memory.mu.
type memIssues struct {
	gone     map[string]map[int]Issue // soft-deleted rows (rdb 0071)
	archived map[string]map[int]Issue // soft-archived rows (rdb 0084)
	last     map[string]int
	prefix   map[string]string
	rows     map[string]map[int]Issue
	labels   map[string]map[string]IssueLabel
}

func (m *memIssues) init() {
	if m.rows == nil {
		m.last, m.prefix = map[string]int{}, map[string]string{}
		m.rows, m.labels = map[string]map[int]Issue{}, map[string]map[string]IssueLabel{}
		m.gone = map[string]map[int]Issue{}
		m.archived = map[string]map[int]Issue{}
	}
}

func (m *memIssues) prefixOf(tenant string) string {
	if p := m.prefix[tenant]; p != "" {
		return p
	}
	return IssuePrefixDefault
}

// isTask reports an issue's discussion task_id. Caller holds Memory.mu.
func (m *memIssues) isTask(tenant, taskID string) bool {
	for _, r := range m.rows[tenant] {
		if r.TaskID == taskID {
			return true
		}
	}
	for _, r := range m.gone[tenant] { // a deleted issue's topic stays out of lists
		if r.TaskID == taskID {
			return true
		}
	}
	for _, r := range m.archived[tenant] { // an archived issue's topic stays out too
		if r.TaskID == taskID {
			return true
		}
	}
	return false
}

func copyIssue(i Issue) Issue {
	i.Labels = append([]string{}, i.Labels...)
	return i
}

// refsOK checks labels and, with rule, the tree rule (SPL-18), and derives
// i.Level (want: the caller's level, 0 none). wasEpic: the row was level 1
// before this update.
func (m *memIssues) refsOK(i *Issue, rule, wasEpic bool, want int) error {
	for _, l := range i.Labels {
		if _, ok := m.labels[i.TenantID][l]; !ok {
			return fmt.Errorf("%w: %s", ErrUnknownLabel, l)
		}
	}
	r := treeRefs{wasEpic: wasEpic}
	r.parent, r.parentOK = m.rows[i.TenantID][i.Parent]
	r.parentOK = r.parentOK && i.Parent != 0
	if r.parentOK && !r.parent.IsEpic() {
		g, ok := m.rows[i.TenantID][r.parent.Parent]
		r.parentLevel2 = r.parent.Parent == 0 || (ok && g.IsEpic())
	}
	if !rule {
		return setLevel(i, r, want)
	}
	if i.Number != 0 {
		for _, c := range m.rows[i.TenantID] {
			if c.Parent == i.Number {
				r.hasChildren = true
				break
			}
		}
	}
	if err := treeRule(*i, r); err != nil {
		return err
	}
	return setLevel(i, r, want)
}

func (s *Memory) CreateIssue(_ context.Context, in Issue, now time.Time) (Issue, error) {
	in.UpdatedBy = in.CreatedBy
	if in.Status == "" {
		in.Status = IssueBacklog
	}
	if err := checkIssue(&in); err != nil {
		return Issue{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[in.TenantID]; !ok {
		return Issue{}, ErrNotFound
	}
	s.iss.init()
	if err := s.iss.refsOK(&in, true, false, in.Level); err != nil {
		return Issue{}, err
	}
	for _, r := range s.iss.rows[in.TenantID] {
		if r.TaskID == in.TaskID {
			return Issue{}, ErrConflict
		}
	}
	s.iss.last[in.TenantID]++
	in.Number = s.iss.last[in.TenantID]
	in.Prefix = s.iss.prefixOf(in.TenantID)
	in.CreatedAt, in.UpdatedAt = now, now
	stampStatus(&in, now)
	if s.iss.rows[in.TenantID] == nil {
		s.iss.rows[in.TenantID] = map[int]Issue{}
	}
	s.iss.rows[in.TenantID][in.Number] = copyIssue(in)
	return copyIssue(in), nil
}

func (s *Memory) UpdateIssue(_ context.Context, tenant string, number int, p IssuePatch, by string, now time.Time) (Issue, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	row, ok := s.iss.rows[tenant][number]
	if !ok {
		return Issue{}, ErrNotFound
	}
	want, err := patchLevel(p)
	if err != nil {
		return Issue{}, err
	}
	row = copyIssue(row)
	wasEpic, was := row.IsEpic(), row.Level
	applyPatch(&row, p, by, now)
	if err := checkIssue(&row); err != nil {
		return Issue{}, err
	}
	if err := s.iss.refsOK(&row, epicTouched(p), wasEpic, want); err != nil {
		return Issue{}, err
	}
	row.Prefix = s.iss.prefixOf(tenant)
	s.iss.rows[tenant][number] = copyIssue(row)
	if row.Level != was { // an issue made an epic: its subtasks are issues now
		for n, c := range s.iss.rows[tenant] {
			if c.Parent == number {
				c.Level = row.Level + 1
				s.iss.rows[tenant][n] = c
			}
		}
	}
	return row, nil
}

func (s *Memory) GetIssue(_ context.Context, tenant string, number int) (Issue, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	row, ok := s.iss.rows[tenant][number]
	if !ok {
		return Issue{}, ErrNotFound
	}
	row.Prefix = s.iss.prefixOf(tenant)
	return copyIssue(row), nil
}

func (s *Memory) ListIssues(_ context.Context, tenant string) ([]Issue, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	out := make([]Issue, 0, len(s.iss.rows[tenant]))
	for _, r := range s.iss.rows[tenant] {
		r.Prefix = s.iss.prefixOf(tenant)
		out = append(out, copyIssue(r))
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Number > out[b].Number })
	return out, nil
}

func (s *Memory) DeleteIssue(_ context.Context, tenant string, number int, _ string, _ time.Time) (Issue, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	row, ok := s.iss.rows[tenant][number]
	if !ok {
		return Issue{}, ErrNotFound
	}
	for _, c := range s.iss.rows[tenant] {
		if c.Parent == number {
			return Issue{}, ErrIssueHasChildren
		}
	}
	delete(s.iss.rows[tenant], number)
	if s.iss.gone[tenant] == nil {
		s.iss.gone[tenant] = map[int]Issue{}
	}
	s.iss.gone[tenant][number] = row
	row.Prefix = s.iss.prefixOf(tenant)
	return copyIssue(row), nil
}

// memSubtree returns the numbers of every descendant of number in src (its
// children, then theirs), target excluded, breadth first.
func memSubtree(src map[int]Issue, number int) []int {
	var out []int
	queue := []int{number}
	for len(queue) > 0 {
		p := queue[0]
		queue = queue[1:]
		for n, c := range src {
			if c.Parent == p {
				out = append(out, n)
				queue = append(queue, n)
			}
		}
	}
	sort.Ints(out)
	return out
}

func (s *Memory) DeleteIssueCascade(_ context.Context, tenant string, number int, _ string, _ time.Time) (Issue, []int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	row, ok := s.iss.rows[tenant][number]
	if !ok {
		return Issue{}, nil, ErrNotFound
	}
	kids := memSubtree(s.iss.rows[tenant], number)
	if s.iss.gone[tenant] == nil {
		s.iss.gone[tenant] = map[int]Issue{}
	}
	for _, n := range append([]int{number}, kids...) {
		s.iss.gone[tenant][n] = s.iss.rows[tenant][n]
		delete(s.iss.rows[tenant], n)
	}
	row.Prefix = s.iss.prefixOf(tenant)
	return copyIssue(row), kids, nil
}

func (s *Memory) ArchiveIssue(_ context.Context, tenant string, number int, _ string, _ time.Time, cascade bool) (Issue, []int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	row, ok := s.iss.rows[tenant][number]
	if !ok {
		return Issue{}, nil, ErrNotFound
	}
	var kids []int
	if cascade {
		kids = memSubtree(s.iss.rows[tenant], number)
	} else {
		for _, c := range s.iss.rows[tenant] {
			if c.Parent == number {
				return Issue{}, nil, ErrIssueHasChildren
			}
		}
	}
	if s.iss.archived[tenant] == nil {
		s.iss.archived[tenant] = map[int]Issue{}
	}
	for _, n := range append([]int{number}, kids...) {
		s.iss.archived[tenant][n] = s.iss.rows[tenant][n]
		delete(s.iss.rows[tenant], n)
	}
	row.Prefix = s.iss.prefixOf(tenant)
	return copyIssue(row), kids, nil
}

func (s *Memory) UnarchiveIssue(_ context.Context, tenant string, number int, _ string, _ time.Time, cascade bool) (Issue, []int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	row, ok := s.iss.archived[tenant][number]
	if !ok {
		return Issue{}, nil, ErrNotFound
	}
	var kids []int
	if cascade {
		kids = memSubtree(s.iss.archived[tenant], number)
	}
	if s.iss.rows[tenant] == nil {
		s.iss.rows[tenant] = map[int]Issue{}
	}
	for _, n := range append([]int{number}, kids...) {
		s.iss.rows[tenant][n] = s.iss.archived[tenant][n]
		delete(s.iss.archived[tenant], n)
	}
	row.Prefix = s.iss.prefixOf(tenant)
	return copyIssue(row), kids, nil
}

func (s *Memory) IssuePrefix(_ context.Context, tenant string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	return s.iss.prefixOf(tenant), nil
}

// CheckIssuePrefix upper-cases p and checks it (the rdb 0047 CHECK).
func CheckIssuePrefix(p string) (string, error) {
	p = strings.ToUpper(strings.TrimSpace(p))
	if !issuePrefixRe.MatchString(p) {
		return "", invalidIssue("prefix is 1..10 of A-Z and 0-9, starting with a letter")
	}
	return p, nil
}

func (s *Memory) SetIssuePrefix(_ context.Context, tenant, prefix string) (string, error) {
	p, err := CheckIssuePrefix(prefix)
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return "", ErrNotFound
	}
	s.iss.init()
	s.iss.prefix[tenant] = p
	return p, nil
}

func (s *Memory) ListIssueLabels(_ context.Context, tenant string) ([]IssueLabel, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	out := []IssueLabel{}
	for _, l := range s.iss.labels[tenant] {
		out = append(out, l)
	}
	sortLabels(out)
	return out, nil
}

func sortLabels(ls []IssueLabel) {
	sort.Slice(ls, func(a, b int) bool {
		x, y := strings.ToLower(ls[a].Name), strings.ToLower(ls[b].Name)
		if x != y {
			return x < y
		}
		return ls[a].LabelID < ls[b].LabelID
	})
}

func (s *Memory) CreateIssueLabel(_ context.Context, l IssueLabel, now time.Time) (IssueLabel, error) {
	if err := checkLabel(&l); err != nil {
		return IssueLabel{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[l.TenantID]; !ok {
		return IssueLabel{}, ErrNotFound
	}
	s.iss.init()
	if _, ok := s.iss.labels[l.TenantID][l.LabelID]; ok {
		return IssueLabel{}, ErrConflict
	}
	if s.iss.labels[l.TenantID] == nil {
		s.iss.labels[l.TenantID] = map[string]IssueLabel{}
	}
	l.CreatedAt = now
	s.iss.labels[l.TenantID][l.LabelID] = l
	return l, nil
}
