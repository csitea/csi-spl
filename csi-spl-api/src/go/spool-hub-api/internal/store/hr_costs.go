package store

import (
	"context"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Human costs per person, component and month, and the month lock (SPL-5433,
// rdb 0280, spec 123 section 16.2; owner HUM-10, t1 2d974709, polls a82c0089
// and 2ff12c21). A person is a code (E-01); the real name lives in its own
// table that only a costs.write caller reads (names = true). A month of hr
// lines closes by itself on the 6th of the next month at 00:00
// Europe/Helsinki; the operator admin may reopen it, with a reason, and close
// it again. The rows are the estate's, operator scope only, like rdb 0245.

// HRGroups are rdb 0280's hr_cost_components.grp CHECK (HUM-24's 8 groups).
var HRGroups = []string{"salaries_wages", "employer_contributions", "working_time_allowances",
	"bonuses_incentives", "leave_absence", "benefits_insurance", "training_recruitment", "transport_meals"}

// HREmploymentTypes are rdb 0280's hr_people.employment_type CHECK.
var HREmploymentTypes = []string{"employee", "hourly", "owner_management", "contractor"}

// CostCloseDay is the day of the next month a month closes on (owner, poll
// a82c0089 answer 2 B: "It closes by itself on the 6th of the next month").
const CostCloseDay = 6

// costCloseZone is where that day starts: the books are Finnish.
var costCloseZone = func() *time.Location {
	if loc, err := time.LoadLocation("Europe/Helsinki"); err == nil {
		return loc
	}
	return time.FixedZone("EET", 2*3600)
}()

// HRComponent is one row of hr_cost_components.
type HRComponent struct {
	Component      string `json:"component"`
	Group          string `json:"group"`
	Label          string `json:"label"`
	DefaultAccount string `json:"default_account"`
	SortOrder      int    `json:"sort_order"`
}

// DefaultHRComponents is rdb 0280's seed, the Memory driver's rows; a
// Postgres test holds the two equal.
var DefaultHRComponents = []HRComponent{
	{"monthly_salary", "salaries_wages", "Monthly salary", "", 10},
	{"hourly_pay", "salaries_wages", "Hourly pay (hours x rate)", "", 11},
	{"owner_salary", "salaries_wages", "Owner's salary", "", 12},
	{"base_pay", "salaries_wages", "Base pay", "", 13},
	{"tyel_employer", "employer_contributions", "TyEL, employer's share", "", 20},
	{"yel", "employer_contributions", "YEL, entrepreneur's pension", "", 21},
	{"unemployment_employer", "employer_contributions", "Unemployment insurance, employer's share", "", 22},
	{"health_insurance", "employer_contributions", "Health insurance contribution", "", 23},
	{"accident_insurance", "employer_contributions", "Accident insurance", "", 24},
	{"group_life_insurance", "employer_contributions", "Group life insurance", "", 25},
	{"overtime", "working_time_allowances", "Overtime", "", 30},
	{"evening_night", "working_time_allowances", "Evening and night allowance", "", 31},
	{"sunday_holiday", "working_time_allowances", "Sunday and holiday allowance", "", 32},
	{"shift", "working_time_allowances", "Shift allowance", "", 33},
	{"bonus", "bonuses_incentives", "Bonus or incentive", "", 40},
	{"annual_leave", "leave_absence", "Annual leave pay", "", 50},
	{"holiday_bonus", "leave_absence", "Holiday bonus (lomaraha)", "", 51},
	{"sick_leave", "leave_absence", "Sick leave pay", "", 52},
	{"other_paid_absence", "leave_absence", "Other paid absence", "", 53},
	{"occupational_healthcare", "benefits_insurance", "Occupational healthcare", "", 60},
	{"voluntary_insurance", "benefits_insurance", "Voluntary personal insurance", "", 61},
	{"lunch_benefit", "benefits_insurance", "Lunch benefit", "", 62},
	{"sports_benefit", "benefits_insurance", "Sports and culture benefit", "", 63},
	{"training", "training_recruitment", "Training", "", 70},
	{"recruitment", "training_recruitment", "Recruitment", "", 71},
	{"business_travel", "transport_meals", "Business travel", "", 80},
	{"mileage", "transport_meals", "Mileage allowance", "", 81},
	{"company_car", "transport_meals", "Company car", "", 82},
	{"meals", "transport_meals", "Meal allowance", "", 83},
}

// HRPerson is one row of hr_people, Name from hr_person_names when the
// caller may read it (else "").
type HRPerson struct {
	ID             string    `json:"id"`
	Code           string    `json:"code"`
	Name           string    `json:"name,omitempty"`
	Department     string    `json:"department"`
	EmploymentType string    `json:"employment_type"`
	BirthYear      int       `json:"birth_year,omitempty"`
	LeftOn         string    `json:"left_on,omitempty"`
	CreatedBy      string    `json:"created_by"`
	CreatedAt      time.Time `json:"created_at"`
}

var hrCodeRe = regexp.MustCompile(`^[A-Z]{1,3}-[0-9]{2,4}$`)

// CheckHRPerson names the first thing p may not carry ("" = fine), rdb
// 0280's CHECKs. A person is entered with a name (the accountant enters it).
func CheckHRPerson(p HRPerson) string {
	switch {
	case !hrCodeRe.MatchString(p.Code):
		return "code must be 1..3 capital letters, a dash and 2..4 digits, e.g. E-01"
	case strings.TrimSpace(p.Name) == "" || len(p.Name) > 200:
		return "name must be 1..200 characters"
	case len(p.Department) > 100:
		return "department must be at most 100 characters"
	case !slices.Contains(HREmploymentTypes, p.EmploymentType):
		return "employment_type must be employee, hourly, owner_management or contractor"
	case p.BirthYear != 0 && (p.BirthYear < 1900 || p.BirthYear > 2100):
		return "birth_year must be a year between 1900 and 2100"
	case p.LeftOn != "" && !isDay(p.LeftOn):
		return "left_on must be a day YYYY-MM-DD"
	}
	return ""
}

// CostPeriod is one month's lock state at a moment.
type CostPeriod struct {
	Period       string     `json:"period"`
	Closed       bool       `json:"closed"`
	ClosesAt     time.Time  `json:"closes_at"`
	ClosedAt     *time.Time `json:"closed_at,omitempty"`
	ClosedBy     string     `json:"closed_by,omitempty"`
	ReopenedAt   *time.Time `json:"reopened_at,omitempty"`
	ReopenedBy   string     `json:"reopened_by,omitempty"`
	ReopenReason string     `json:"reopen_reason,omitempty"`
}

// costPeriodRow is a cost_periods row; nil = none.
type costPeriodRow struct {
	closedAt, reopenedAt     *time.Time
	closedBy, reopenedBy, re string
}

// CostMonthClosesAt is when month YYYY-MM closes by itself: the 6th of the
// next month, 00:00 Europe/Helsinki, in UTC.
func CostMonthClosesAt(month string) time.Time {
	t, _ := time.Parse("2006-01", month)
	return time.Date(t.Year(), t.Month()+1, CostCloseDay, 0, 0, 0, 0, costCloseZone).UTC()
}

// costPeriodAt is month's state at now from its row (nil = no row).
func costPeriodAt(month string, row *costPeriodRow, now time.Time) CostPeriod {
	p := CostPeriod{Period: month, ClosesAt: CostMonthClosesAt(month)}
	if row == nil {
		p.Closed = !now.Before(p.ClosesAt)
		if p.Closed {
			at := p.ClosesAt
			p.ClosedAt = &at
		}
		return p
	}
	p.Closed = row.closedAt != nil
	p.ClosedAt, p.ClosedBy = row.closedAt, row.closedBy
	p.ReopenedAt, p.ReopenedBy, p.ReopenReason = row.reopenedAt, row.reopenedBy, row.re
	return p
}

// CostLockMonth is the month whose lock an entry follows: its own, or for a
// yearly line (period the year's January) the year's December.
func CostLockMonth(e CostEntry) string {
	if e.PeriodKind == "year" && len(e.Period) == 7 {
		return e.Period[:4] + "-12"
	}
	return e.Period
}

// HRCostStore is the store half of rdb 0280. Optional, like CostEntryStore.
type HRCostStore interface {
	// ListHRComponents is every component, group then sort order.
	ListHRComponents(ctx context.Context) ([]HRComponent, error)
	// ListHRPeople is every person by code; names = read hr_person_names too.
	ListHRPeople(ctx context.Context, names bool) ([]HRPerson, error)
	// CreateHRPerson stores a checked person and its name; ErrConflict on a
	// code already taken.
	CreateHRPerson(ctx context.Context, p HRPerson) (HRPerson, error)
	// CostPeriodState is month's lock state at now.
	CostPeriodState(ctx context.Context, month string, now time.Time) (CostPeriod, error)
	// SetCostPeriod closes (closed) or reopens month at now, by who, with
	// reason (a reopen's, required there); it answers the new state.
	SetCostPeriod(ctx context.Context, month string, closed bool, by, reason string, now time.Time) (CostPeriod, error)
}

// The Memory driver's rows beside the store.
var (
	memHRMu      sync.Mutex
	memHRPeople  = map[*Memory]map[string]HRPerson{}
	memHRPeriods = map[*Memory]map[string]costPeriodRow{}
)

// memHRPersonExists is whether Memory s holds person id.
func memHRPersonExists(s *Memory, id string) bool {
	memHRMu.Lock()
	defer memHRMu.Unlock()
	_, ok := memHRPeople[s][id]
	return ok
}

// ListHRComponents is HRCostStore on Memory.
func (s *Memory) ListHRComponents(context.Context) ([]HRComponent, error) {
	return slices.Clone(DefaultHRComponents), nil
}

// ListHRPeople is HRCostStore on Memory.
func (s *Memory) ListHRPeople(_ context.Context, names bool) ([]HRPerson, error) {
	memHRMu.Lock()
	defer memHRMu.Unlock()
	out := []HRPerson{}
	for _, p := range memHRPeople[s] {
		if !names {
			p.Name = ""
		}
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Code < out[j].Code })
	return out, nil
}

// CreateHRPerson is HRCostStore on Memory.
func (s *Memory) CreateHRPerson(_ context.Context, p HRPerson) (HRPerson, error) {
	if why := CheckHRPerson(p); why != "" {
		return HRPerson{}, fmt.Errorf("hr person: %s", why)
	}
	memHRMu.Lock()
	defer memHRMu.Unlock()
	for _, x := range memHRPeople[s] {
		if x.Code == p.Code {
			return HRPerson{}, ErrConflict
		}
	}
	if memHRPeople[s] == nil {
		memHRPeople[s] = map[string]HRPerson{}
	}
	p.ID, p.CreatedAt = uuid.New(), time.Now().UTC().Truncate(time.Microsecond)
	memHRPeople[s][p.ID] = p
	return p, nil
}

// CostPeriodState is HRCostStore on Memory.
func (s *Memory) CostPeriodState(_ context.Context, month string, now time.Time) (CostPeriod, error) {
	if !IsCostMonth(month) {
		return CostPeriod{}, fmt.Errorf("cost period: month must be YYYY-MM")
	}
	memHRMu.Lock()
	defer memHRMu.Unlock()
	if row, ok := memHRPeriods[s][month]; ok {
		return costPeriodAt(month, &row, now), nil
	}
	return costPeriodAt(month, nil, now), nil
}

// SetCostPeriod is HRCostStore on Memory.
func (s *Memory) SetCostPeriod(_ context.Context, month string, closed bool, by, reason string, now time.Time) (CostPeriod, error) {
	if why := checkCostPeriodSet(month, closed, by, reason); why != "" {
		return CostPeriod{}, fmt.Errorf("cost period: %s", why)
	}
	memHRMu.Lock()
	defer memHRMu.Unlock()
	if memHRPeriods[s] == nil {
		memHRPeriods[s] = map[string]costPeriodRow{}
	}
	row := memHRPeriods[s][month]
	at := now.UTC().Truncate(time.Microsecond)
	if closed {
		row.closedAt, row.closedBy = &at, by
	} else {
		row.closedAt, row.reopenedAt, row.reopenedBy, row.re = nil, &at, by, reason
	}
	memHRPeriods[s][month] = row
	return costPeriodAt(month, &row, now), nil
}

// checkCostPeriodSet names what a close or reopen may not carry.
func checkCostPeriodSet(month string, closed bool, by, reason string) string {
	switch {
	case !IsCostMonth(month):
		return "month must be YYYY-MM"
	case strings.TrimSpace(by) == "" || len(by) > 200:
		return "by must be 1..200 characters"
	case !closed && (strings.TrimSpace(reason) == "" || len(reason) > 500):
		return "a reopen needs a reason of 1..500 characters"
	}
	return ""
}

var _ HRCostStore = (*Memory)(nil)
