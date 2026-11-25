package wire

// The Costs > Taxes routes of the hub (spec 143 taxes-tab.md sections 3 and
// 5, build slice S2, SPL-6438; owner HUM-10, csitea topic dc7c9c9a, msg
// fc8f964e). Two callers:
//
//   - the main-box sync (do_spl_tax_sync, S4), as the env's operator service
//     account, in the tax workspace only (cnf SPOOL_HUB_TAX_WORKSPACE):
//     POST /v1/operator/tax/snapshots  TaxSnapshotIn -> TaxIngestResponse
//   - every person seated in the tax workspace ("Every person of csitea;
//     agents never"), from the browser session:
//     GET  /v1/view/tax/overview       -> TaxOverviewResponse
//
// Dates are "YYYY-MM-DD" ("" when absent), times RFC 3339 UTC. No body has
// a field for an amount, a business id, a tax number, a file name or a
// personal name: the tax index carries no amount and the documents stay on
// the main box. No MCP tool and no spool message carries these bodies.

// TaxDocumentIn is one row of the main box's tax index.
type TaxDocumentIn struct {
	ArrivalDate   string `json:"arrival_date"`
	Kind          string `json:"kind"`
	DocType       string `json:"doc_type"`
	TaxType       string `json:"tax_type"`
	Period        string `json:"period"`
	DueDate       string `json:"due_date"`
	Category      string `json:"category"`
	ContentSHA256 string `json:"content_sha256"`
}

// TaxSnapshotIn is one sync of one tax year's index.
type TaxSnapshotIn struct {
	SnapshotID string          `json:"snapshot_id"`
	TaxYear    int             `json:"tax_year"`
	TakenAt    string          `json:"taken_at"`
	Documents  []TaxDocumentIn `json:"documents"`
}

// TaxIngestResponse is the operator's answer: counts, never a row.
type TaxIngestResponse struct {
	SnapshotID string `json:"snapshot_id"`
	TaxYear    int    `json:"tax_year"`
	Documents  int    `json:"documents"`
}

// TaxDocument is one document of the newest snapshot, with what the hub
// computed: Status "new" (its kind, type, tax type and period were not in
// the snapshot before), "changed" (they were, with another content) or ""
// (unchanged, or no snapshot before to compare with); DueSoon when its due
// date is within 30 days of Today either way; Overdue when it is before
// Today; OpenQuestion for a decision with no due date.
type TaxDocument struct {
	ArrivalDate  string `json:"arrival_date"`
	Kind         string `json:"kind"`
	DocType      string `json:"doc_type"`
	TaxType      string `json:"tax_type"`
	Period       string `json:"period"`
	DueDate      string `json:"due_date"`
	Category     string `json:"category"`
	Status       string `json:"status"`
	DueSoon      bool   `json:"due_soon"`
	Overdue      bool   `json:"overdue"`
	OpenQuestion bool   `json:"open_question"`
}

// TaxOverviewResponse is the Taxes page: the newest snapshot of TaxYear
// (the newest year filed unless ?year= names one of Years), its documents
// newest first, and when the snapshot it is compared with was taken.
// Snapshot is null and Documents empty before the first sync.
type TaxOverviewResponse struct {
	TaxYear         int           `json:"tax_year"`
	Years           []int         `json:"years"`
	Today           string        `json:"today"`
	TakenAt         string        `json:"taken_at"`
	PreviousTakenAt string        `json:"previous_taken_at"`
	SnapshotID      string        `json:"snapshot_id"`
	Documents       []TaxDocument `json:"documents"`
}
