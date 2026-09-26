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

// Issue statuses in Linear's workflow order (the list groups by it).
const (
	IssueBacklog    = "backlog"
	IssueTodo       = "todo"
	IssueInProgress = "in_progress"
	IssueInReview   = "in_review"
	IssueDone       = "done"
	IssueCanceled   = "canceled"
)

// IssueStatuses is the workflow, in order.
var IssueStatuses = []string{IssueBacklog, IssueTodo, IssueInProgress, IssueInReview, IssueDone, IssueCanceled}

const (
	// IssuePriorityMax: 0 no priority, 1 urgent, 2 high, 3 medium, 4 low.
	IssuePriorityMax = 4
	// IssueLevelMax: the owner's "level", Linear's t-shirt estimate, 0 none,
	// 1 XS, 2 S, 3 M, 4 L, 5 XL.
	IssueLevelMax       = 5
	IssueTitleMax       = 255
	IssueDescriptionMax = 20000
	IssueLabelsMax      = 20
	IssueLabelNameMax   = 40
	// IssuePrefixDefault is the key prefix of a tenant that never set one.
	IssuePrefixDefault = "SPL"
	// issueParentDepthMax bounds the parent walk that refuses a cycle.
	issueParentDepthMax = 64
)

// ErrInvalidIssue wraps every refused field; the message names the field.
var ErrInvalidIssue = errors.New("invalid issue")

// ErrUnknownLabel: a label id not in the tenant's catalogue.
var ErrUnknownLabel = errors.New("unknown issue label")

// ErrUnknownParent: the parent number is not an issue of the tenant, or the
// parent would make a cycle.
var ErrUnknownParent = errors.New("unknown parent issue")

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
		p.Assignee == nil && p.Labels == nil && !p.DeadlineSet && p.Parent == nil
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
	// ErrUnknownLabel, ErrUnknownParent; ErrNotFound for an unknown tenant.
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
	// ListIssueLabels is the catalogue sorted by name.
	ListIssueLabels(ctx context.Context, tenantID string) ([]IssueLabel, error)
	// CreateIssueLabel adds one; ErrConflict when the id exists.
	CreateIssueLabel(ctx context.Context, l IssueLabel, now time.Time) (IssueLabel, error)
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
	case i.Priority < 0 || i.Priority > IssuePriorityMax:
		return invalidIssue("priority must be 0..%d", IssuePriorityMax)
	case i.Level < 0 || i.Level > IssueLevelMax:
		return invalidIssue("level must be 0..%d", IssueLevelMax)
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
	changed := p.Status != nil && *p.Status != i.Status
	ApplyIssuePatch(i, p)
	if changed {
		stampStatus(i, now)
	}
	i.UpdatedBy, i.UpdatedAt = by, now
}

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
	last   map[string]int
	prefix map[string]string
	rows   map[string]map[int]Issue
	labels map[string]map[string]IssueLabel
}

func (m *memIssues) init() {
	if m.rows == nil {
		m.last, m.prefix = map[string]int{}, map[string]string{}
		m.rows, m.labels = map[string]map[int]Issue{}, map[string]map[string]IssueLabel{}
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
	return false
}

func copyIssue(i Issue) Issue {
	i.Labels = append([]string{}, i.Labels...)
	return i
}

// refsOK checks labels and parent against the tenant's rows.
func (m *memIssues) refsOK(i Issue) error {
	for _, l := range i.Labels {
		if _, ok := m.labels[i.TenantID][l]; !ok {
			return fmt.Errorf("%w: %s", ErrUnknownLabel, l)
		}
	}
	for p, depth := i.Parent, 0; p != 0; depth++ {
		if p == i.Number || depth > issueParentDepthMax {
			return ErrUnknownParent
		}
		row, ok := m.rows[i.TenantID][p]
		if !ok {
			return ErrUnknownParent
		}
		p = row.Parent
	}
	return nil
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
	if err := s.iss.refsOK(in); err != nil {
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
	row = copyIssue(row)
	applyPatch(&row, p, by, now)
	if err := checkIssue(&row); err != nil {
		return Issue{}, err
	}
	if err := s.iss.refsOK(row); err != nil {
		return Issue{}, err
	}
	row.Prefix = s.iss.prefixOf(tenant)
	s.iss.rows[tenant][number] = copyIssue(row)
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

func (s *Memory) IssuePrefix(_ context.Context, tenant string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.iss.init()
	return s.iss.prefixOf(tenant), nil
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
