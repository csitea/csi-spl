package store

import (
	"context"
	"errors"
	"regexp"
	"time"
)

// The Netvisor finance store (spec 125 v0.1 sections 3, 4, 5.2, build row
// B4, SPL-4721; rdb 0255_netvisor_finance.sql, 0260). A workspace's Netvisor
// data is filed under ONE human, netvisor_settings.owner_human_id (C7: data,
// never a code literal), who alone writes the settings and the refresh
// request. Since rdb 0260 (C7 as rewritten, SPL-4792; owner msg cfa78746:
// every member of the workspace) a person seated in the workspace READS the
// owner's rows too. Every read and write runs in the caller's scope
// (inNetvisorOwner: the tenant plus that human id); an agent seat, an act-as
// clone, a channel guest, another workspace, the tenant alone and the
// operator scope read 0 rows.
// The operator ingest (B5) runs in inNetvisorIngest, which reaches
// netvisor_settings alone, learns the owner there and then writes the
// snapshot in that owner's scope. The hub (B5) passes as human only the id
// of an authenticated human session, never an act-as clone, an agent, a box
// or a value from a path, query, header or body.

// NetvisorEnvs is rdb 0255's env CHECK: the Netvisor test company first,
// production after the owner's go (spec 125 sections 7 and 9).
var NetvisorEnvs = []string{"test", "prd"}

// NetvisorForecastCategories is rdb 0255's netvisor_forecast_items.category
// CHECK, the terms of the month-end sum (spec 125 section 3.1).
var NetvisorForecastCategories = []string{"bank_balance", "receivable", "payable", "payment", "payroll", "vat", "tax", "contract"}

// NetvisorCardRoutes is rdb 0255's netvisor_card_cost_lines.route CHECK
// (spec 125 section 4.1).
var NetvisorCardRoutes = []string{"credit_einvoice", "debit_ledger", "expense_report"}

// Bounds of one snapshot, so one ingest is one bounded transaction.
const (
	NetvisorMaxForecastItems = 10000
	NetvisorMaxCardCostLines = 50000
)

var (
	// ErrNoHuman: an owner-scoped statement without a valid human id
	// (HUM-<digits>). Refused before Postgres sees it; rdb 0255's NULLIF is
	// the database half.
	ErrNoHuman = errors.New("store: netvisor statement without a valid human")
	// ErrNetvisorNoOwner: the workspace has no netvisor_settings row, so
	// no human a snapshot could belong to.
	ErrNetvisorNoOwner = errors.New("store: the workspace has no netvisor owner")
	// ErrNetvisorEnv: a snapshot of another Netvisor company than the
	// workspace's settings name.
	ErrNetvisorEnv = errors.New("store: snapshot env differs from the workspace's netvisor env")
	// ErrBadNetvisor: a value outside rdb 0255's CHECKs.
	ErrBadNetvisor = errors.New("store: bad netvisor value")
)

// NetvisorSettings is the workspace's netvisor_settings row. Accounts are
// bookkeeping account numbers (digits), never a bank account number (C3).
type NetvisorSettings struct {
	Tenant           string    `json:"-"`
	OwnerHumanID     string    `json:"owner_human_id"`
	Env              string    `json:"env"`
	BankAccount      string    `json:"bank_account"`
	VATAccounts      []string  `json:"vat_accounts"`
	TaxAccounts      []string  `json:"tax_accounts"`
	VendorExclusions []string  `json:"vendor_exclusions"`
	UpdatedBy        string    `json:"updated_by"`
	UpdatedAt        time.Time `json:"updated_at"`
	// RefreshRequestedAt is the owner's open "Refresh now" (rdb 0257), nil
	// when none is open; NetvisorIngest clears it.
	RefreshRequestedAt *time.Time `json:"refresh_requested_at"`
}

// NetvisorForecastItem is one term of the month-end sum. Amount is decimal
// text (numeric(18,2) in Postgres, never a float). DueDate is zero when
// the term has none.
type NetvisorForecastItem struct {
	ItemNo   int       `json:"item_no"`
	Category string    `json:"category"`
	Sign     int       `json:"sign"`
	Amount   string    `json:"amount"`
	Currency string    `json:"currency"`
	DueDate  time.Time `json:"due_date"`
	Overdue  bool      `json:"overdue"`
	Approved *bool     `json:"approved"`
	Label    string    `json:"label"`
}

// NetvisorCardCostLine is one card cost line; Month is the first day of
// its calendar month.
type NetvisorCardCostLine struct {
	LineNo        int       `json:"line_no"`
	Month         time.Time `json:"month"`
	Route         string    `json:"route"`
	Vendor        string    `json:"vendor"`
	AccountNumber string    `json:"account_number"`
	AccountName   string    `json:"account_name"`
	Dimension     string    `json:"dimension"`
	DimensionItem string    `json:"dimension_item"`
	Amount        string    `json:"amount"`
	Currency      string    `json:"currency"`
	VATCode       string    `json:"vat_code"`
	Excluded      bool      `json:"excluded"`
}

// NetvisorSnapshot is one fetch with its forecast items and card lines.
// NewestBankVoucherDate is zero when no bank voucher is booked yet.
type NetvisorSnapshot struct {
	Tenant                string                 `json:"-"`
	SnapshotID            string                 `json:"snapshot_id"`
	OwnerHumanID          string                 `json:"-"`
	Env                   string                 `json:"env"`
	AsOf                  time.Time              `json:"as_of"`
	MonthEnd              time.Time              `json:"month_end"`
	NewestBankVoucherDate time.Time              `json:"newest_bank_voucher_date"`
	FetchedAt             time.Time              `json:"fetched_at"`
	Items                 []NetvisorForecastItem `json:"items"`
	CardLines             []NetvisorCardCostLine `json:"card_lines"`
}

// Netvisor is the store API of spec 125 B4; *Postgres implements it, and
// the hub (B5) reaches it by type assertion, like MarketingMetrics.
type Netvisor interface {
	// NetvisorSetOwner names the one human who reads the workspace's
	// Netvisor data (the operator's call; it creates the settings row).
	NetvisorSetOwner(ctx context.Context, tenant, human, by string, now time.Time) error
	// NetvisorSettings reads the settings as human: ErrNotFound unless
	// human is the owner or a person seated in tenant (rdb 0260); the hub
	// answers the settings route to the owner alone.
	NetvisorSettings(ctx context.Context, tenant, human string) (NetvisorSettings, error)
	// NetvisorPutSettings writes env, accounts and exclusions as human
	// (never the owner): ErrNotFound unless human is the owner.
	NetvisorPutSettings(ctx context.Context, tenant, human string, s NetvisorSettings, now time.Time) (NetvisorSettings, error)
	// NetvisorIngest files one snapshot under the workspace's owner.
	NetvisorIngest(ctx context.Context, tenant string, snap NetvisorSnapshot) (NetvisorSnapshot, error)
	// NetvisorLatest reads the current owner's newest snapshot of env as
	// human: ErrNotFound when there is none human may read.
	NetvisorLatest(ctx context.Context, tenant, human, env string) (NetvisorSnapshot, error)
	// NetvisorRequestRefresh opens human's "Refresh now" (rdb 0257) and
	// answers its time: ErrNotFound unless human is the owner.
	NetvisorRequestRefresh(ctx context.Context, tenant, human string, now time.Time) (time.Time, error)
	// NetvisorRefreshRequested is the open request in the ingest scope (the
	// B6 poller's read): nil when none, ErrNetvisorNoOwner with no settings.
	NetvisorRefreshRequested(ctx context.Context, tenant string) (*time.Time, error)
}

var (
	nvsAccountRe  = regexp.MustCompile(`^[0-9]{1,12}$`)
	nvsAmountRe   = regexp.MustCompile(`^-?[0-9]{1,16}(\.[0-9]{1,2})?$`)
	nvsCurrencyRe = regexp.MustCompile(`^[A-Z]{3}$`)
	nvsUUIDRe     = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

// checkHuman is the store half of the owner scope's fail-closed.
func checkHuman(human string) error {
	if !personIDRe.MatchString(human) {
		return ErrNoHuman
	}
	return nil
}

func nvsOneOf(v string, set []string) bool {
	for _, s := range set {
		if v == s {
			return true
		}
	}
	return false
}

func nvsBad(what string) error { return errors.Join(ErrBadNetvisor, errors.New(what)) }

// normNetvisorSettings checks s against rdb 0255's CHECKs.
func normNetvisorSettings(s NetvisorSettings) (NetvisorSettings, error) {
	if !nvsOneOf(s.Env, NetvisorEnvs) {
		return s, nvsBad("env")
	}
	if s.BankAccount != "" && !nvsAccountRe.MatchString(s.BankAccount) {
		return s, nvsBad("bank_account")
	}
	for _, list := range [][]string{s.VATAccounts, s.TaxAccounts} {
		if len(list) > 32 {
			return s, nvsBad("too many accounts")
		}
		for _, a := range list {
			if !nvsAccountRe.MatchString(a) {
				return s, nvsBad("account")
			}
		}
	}
	n := 0
	for _, v := range s.VendorExclusions {
		n += len(v)
	}
	if len(s.VendorExclusions) > 200 || n > 20000 {
		return s, nvsBad("vendor_exclusions")
	}
	s.VATAccounts, s.TaxAccounts, s.VendorExclusions = nvsNonNil(s.VATAccounts), nvsNonNil(s.TaxAccounts), nvsNonNil(s.VendorExclusions)
	return s, nil
}

func nvsNonNil(v []string) []string {
	if v == nil {
		return []string{}
	}
	return v
}

// normNetvisorSnapshot checks snap against rdb 0255's CHECKs.
func normNetvisorSnapshot(snap NetvisorSnapshot) (NetvisorSnapshot, error) {
	switch {
	case !nvsUUIDRe.MatchString(snap.SnapshotID):
		return snap, nvsBad("snapshot_id")
	case snap.Env != "" && !nvsOneOf(snap.Env, NetvisorEnvs):
		return snap, nvsBad("env")
	case snap.AsOf.IsZero() || snap.MonthEnd.Before(snap.AsOf) || snap.FetchedAt.IsZero():
		return snap, nvsBad("dates")
	case len(snap.Items) > NetvisorMaxForecastItems || len(snap.CardLines) > NetvisorMaxCardCostLines:
		return snap, nvsBad("too many rows")
	}
	for i := range snap.Items {
		if err := normNetvisorItem(&snap.Items[i]); err != nil {
			return snap, err
		}
	}
	for i := range snap.CardLines {
		if err := normNetvisorCardLine(&snap.CardLines[i]); err != nil {
			return snap, err
		}
	}
	return snap, nil
}

func normNetvisorItem(it *NetvisorForecastItem) error {
	if it.Currency == "" {
		it.Currency = "EUR"
	}
	switch {
	case it.ItemNo < 0 || !nvsOneOf(it.Category, NetvisorForecastCategories):
		return nvsBad("forecast item")
	case it.Sign != -1 && it.Sign != 1:
		return nvsBad("forecast sign")
	case !nvsAmountRe.MatchString(it.Amount) || !nvsCurrencyRe.MatchString(it.Currency):
		return nvsBad("forecast amount")
	case len(it.Label) > 200:
		return nvsBad("forecast label")
	}
	return nil
}

func normNetvisorCardLine(l *NetvisorCardCostLine) error {
	if l.Currency == "" {
		l.Currency = "EUR"
	}
	switch {
	case l.LineNo < 0 || !nvsOneOf(l.Route, NetvisorCardRoutes):
		return nvsBad("card line")
	case l.Month.IsZero() || l.Month.Day() != 1:
		return nvsBad("card month")
	case l.AccountNumber != "" && !nvsAccountRe.MatchString(l.AccountNumber):
		return nvsBad("card account")
	case !nvsAmountRe.MatchString(l.Amount) || !nvsCurrencyRe.MatchString(l.Currency):
		return nvsBad("card amount")
	case len(l.Vendor) > 200 || len(l.AccountName) > 200 || len(l.Dimension) > 200 || len(l.DimensionItem) > 200 || len(l.VATCode) > 32:
		return nvsBad("card text")
	}
	return nil
}
