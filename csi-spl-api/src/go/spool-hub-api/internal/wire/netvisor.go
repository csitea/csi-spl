package wire

// The Netvisor finance routes of the hub (spec 125 v0.1 sections 3, 4, 5.2,
// build row B5, SPL-4732; owner HUM-10, topic fc0119cd). Two callers:
//
//   - the main-box sync (B6), as the env's operator service account, in the
//     Netvisor workspace only (cnf SPOOL_HUB_NETVISOR_WORKSPACE):
//     PUT  /v1/operator/netvisor/owner      NetvisorOwnerBody -> NetvisorOwnerResponse
//     POST /v1/operator/netvisor/snapshots  NetvisorSnapshotIn -> NetvisorIngestResponse
//     GET  /v1/operator/netvisor/refresh    -> NetvisorRefreshResponse
//   - the workspace's Netvisor owner human (C7), from the browser session:
//     GET  /v1/view/netvisor/forecast       -> NetvisorForecastResponse
//     GET  /v1/view/netvisor/card-costs     -> NetvisorCardCostsResponse
//     POST /v1/netvisor/refresh             -> NetvisorRefreshResponse
//     PUT  /v1/netvisor/settings            NetvisorSettingsBody -> NetvisorSettingsBody
//
// Dates are "YYYY-MM-DD" ("" when absent), times RFC 3339 UTC, amounts
// decimal text with at most 2 decimals (never a float). The operator's
// answers carry counts and times only, never a figure (C2, C8). No MCP tool
// and no spool message carries any of these bodies (C8).

// NetvisorDateLayout is the layout of every date of these bodies.
const NetvisorDateLayout = "2006-01-02"

// NetvisorOwnerBody names the one human who reads the workspace's Netvisor
// data (C7). The owner is data in netvisor_settings, never a code literal.
type NetvisorOwnerBody struct {
	HumanID string `json:"human_id"`
}

// NetvisorOwnerResponse confirms the owner move; it names no figure.
type NetvisorOwnerResponse struct {
	Workspace string `json:"workspace"`
	HumanID   string `json:"human_id"`
}

// NetvisorForecastItem is one term of the month-end sum (spec 125 3.1).
// Approved is null when the term has no approval (only payables have one).
type NetvisorForecastItem struct {
	ItemNo   int    `json:"item_no"`
	Category string `json:"category"`
	Sign     int    `json:"sign"`
	Amount   string `json:"amount"`
	Currency string `json:"currency"`
	DueDate  string `json:"due_date"`
	Overdue  bool   `json:"overdue"`
	Approved *bool  `json:"approved"`
	Label    string `json:"label"`
}

// NetvisorCardCostLine is one card cost line (spec 125 4.1); Month is the
// first day of its calendar month.
type NetvisorCardCostLine struct {
	LineNo        int    `json:"line_no"`
	Month         string `json:"month"`
	Route         string `json:"route"`
	Vendor        string `json:"vendor"`
	AccountNumber string `json:"account_number"`
	AccountName   string `json:"account_name"`
	Dimension     string `json:"dimension"`
	DimensionItem string `json:"dimension_item"`
	Amount        string `json:"amount"`
	Currency      string `json:"currency"`
	VATCode       string `json:"vat_code"`
	Excluded      bool   `json:"excluded"`
}

// NetvisorSnapshotIn is one fetch as the main-box sync posts it. Env ""
// takes the workspace's settings env; another env than the settings' is
// refused (409).
type NetvisorSnapshotIn struct {
	SnapshotID            string                 `json:"snapshot_id"`
	Env                   string                 `json:"env"`
	AsOf                  string                 `json:"as_of"`
	MonthEnd              string                 `json:"month_end"`
	NewestBankVoucherDate string                 `json:"newest_bank_voucher_date"`
	FetchedAt             string                 `json:"fetched_at"`
	Items                 []NetvisorForecastItem `json:"items"`
	CardLines             []NetvisorCardCostLine `json:"card_lines"`
}

// NetvisorIngestResponse is the operator's answer: counts, never a figure.
type NetvisorIngestResponse struct {
	SnapshotID string `json:"snapshot_id"`
	Env        string `json:"env"`
	Items      int    `json:"items"`
	CardLines  int    `json:"card_lines"`
}

// NetvisorSnapshotHead is a snapshot's header, shared by both views.
type NetvisorSnapshotHead struct {
	SnapshotID            string `json:"snapshot_id"`
	Env                   string `json:"env"`
	AsOf                  string `json:"as_of"`
	MonthEnd              string `json:"month_end"`
	NewestBankVoucherDate string `json:"newest_bank_voucher_date"`
	FetchedAt             string `json:"fetched_at"`
}

// NetvisorForecastResponse is the owner's month-end cash forecast. Snapshot
// is null (and Items empty) until the first snapshot of Env is filed.
type NetvisorForecastResponse struct {
	Env                string                 `json:"env"`
	Snapshot           *NetvisorSnapshotHead  `json:"snapshot"`
	Items              []NetvisorForecastItem `json:"items"`
	RefreshRequestedAt *string                `json:"refresh_requested_at"`
}

// NetvisorCardCostsResponse is the owner's card cost lines; the breakdowns
// (by cost type, vendor, cost centre) are the screen's (B7).
type NetvisorCardCostsResponse struct {
	Env                string                 `json:"env"`
	Snapshot           *NetvisorSnapshotHead  `json:"snapshot"`
	Lines              []NetvisorCardCostLine `json:"lines"`
	RefreshRequestedAt *string                `json:"refresh_requested_at"`
}

// NetvisorRefreshResponse is the open "Refresh now" request: null when none.
type NetvisorRefreshResponse struct {
	RefreshRequestedAt *string `json:"refresh_requested_at"`
}

// NetvisorSettingsBody is the owner's settings: the Netvisor company (env)
// and the bookkeeping account numbers of the forecast (never a bank account
// number, C3), plus the spec-123 vendor exclusion list. A PUT replaces all
// of them; owner_human_id, updated_by, updated_at and refresh_requested_at
// are answered, never written (the owner moves only by the operator route).
type NetvisorSettingsBody struct {
	OwnerHumanID       string   `json:"owner_human_id,omitempty"`
	Env                string   `json:"env"`
	BankAccount        string   `json:"bank_account"`
	VATAccounts        []string `json:"vat_accounts"`
	TaxAccounts        []string `json:"tax_accounts"`
	VendorExclusions   []string `json:"vendor_exclusions"`
	UpdatedBy          string   `json:"updated_by,omitempty"`
	UpdatedAt          string   `json:"updated_at,omitempty"`
	RefreshRequestedAt *string  `json:"refresh_requested_at,omitempty"`
}
