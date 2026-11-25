package store

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// The tax index store of the Costs > Taxes page (spec 143 taxes-tab.md
// sections 3 and 4, build slice S1, SPL-6438; rdb 0326_tax_documents.sql).
// One snapshot per weekly sync of the main box's tax index, one document
// row per index row. No amount, business id, tax number, file name or
// personal name has a field here: the index carries none, and the
// documents stay on the main box.
//
// Every person seated in the tax workspace READS (owner HUM-10, csitea
// topic dc7c9c9a, msg fc8f964e: "Every person of csitea; agents never"):
// TaxLatest runs in inTaxReader (the tenant plus the session's human id),
// where rdb 0326's tax_read passes a person seat only; an agent seat, a
// time accountant, an act-as clone, a channel guest, another workspace,
// the tenant alone and the operator scope read 0 rows. Only the operator
// sync writes (TaxIngest, inTaxIngest). The hub passes as human only the
// id of an authenticated person's browser session.

// TaxCategories is rdb 0326's tax_documents.category CHECK, the private
// tax project's filing folders.
var TaxCategories = []string{"decisions", "payments", "balance", "msgs"}

// Bounds of one snapshot and its fields (rdb 0326's CHECKs).
const (
	TaxMaxDocuments = 10000
	TaxMaxText      = 80
	// TaxKeepWeeks is the prune horizon: snapshots of a tax year older
	// than this before the newest are dropped, the two newest always kept.
	TaxKeepWeeks = 26
)

var (
	// ErrBadTax: a value outside rdb 0326's CHECKs.
	ErrBadTax = errors.New("store: bad tax value")
	// ErrTaxDuplicate: the snapshot id is already filed.
	ErrTaxDuplicate = errors.New("store: tax snapshot already filed")
)

// TaxDocument is one row of the tax index. DueDate is zero when the
// document has none. ContentSHA256 tells a changed document from a new
// one; it is not the document.
type TaxDocument struct {
	RowNo         int       `json:"row_no"`
	ArrivalDate   time.Time `json:"arrival_date"`
	Kind          string    `json:"kind"`
	DocType       string    `json:"doc_type"`
	TaxType       string    `json:"tax_type"`
	Period        string    `json:"period"`
	DueDate       time.Time `json:"due_date"`
	Category      string    `json:"category"`
	ContentSHA256 string    `json:"content_sha256"`
}

// TaxSnapshot is one sync of a tax year's index with its documents.
type TaxSnapshot struct {
	Tenant     string        `json:"-"`
	SnapshotID string        `json:"snapshot_id"`
	TaxYear    int           `json:"tax_year"`
	TakenAt    time.Time     `json:"taken_at"`
	FiledBy    string        `json:"-"`
	Documents  []TaxDocument `json:"documents"`
}

// Tax is the store API of the Taxes page; *Postgres implements it, and the
// hub reaches it by type assertion, like Netvisor.
type Tax interface {
	// TaxIngest files one snapshot in the ingest scope and prunes the tax
	// year's snapshots older than TaxKeepWeeks before it (the two newest
	// kept). ErrTaxDuplicate for a snapshot id already filed.
	TaxIngest(ctx context.Context, tenant string, snap TaxSnapshot) (TaxSnapshot, error)
	// TaxLatest reads, as human, up to n newest snapshots of year (0 = the
	// newest year filed), newest first, with their documents, and the tax
	// years filed, newest first. Empty when there is none human may read.
	TaxLatest(ctx context.Context, tenant, human string, year, n int) ([]TaxSnapshot, []int, error)
}

var taxSHA256Re = regexp.MustCompile(`^[0-9a-f]{64}$`)

func taxBad(what string) error { return errors.Join(ErrBadTax, errors.New(what)) }

// taxText is a bounded, single-line text field of the index.
func taxText(v string) bool {
	if utf8.RuneCountInString(v) > TaxMaxText || !utf8.ValidString(v) {
		return false
	}
	return strings.IndexFunc(v, unicode.IsControl) < 0
}

// normTaxSnapshot checks snap against rdb 0326's CHECKs and numbers its
// documents in order.
func normTaxSnapshot(snap TaxSnapshot) (TaxSnapshot, error) {
	switch {
	case !nvsUUIDRe.MatchString(snap.SnapshotID):
		return snap, taxBad("snapshot_id")
	case snap.TaxYear < 2000 || snap.TaxYear > 2100:
		return snap, taxBad("tax_year")
	case snap.TakenAt.IsZero():
		return snap, taxBad("taken_at")
	case snap.FiledBy == "" || len(snap.FiledBy) > 200:
		return snap, taxBad("filed_by")
	case len(snap.Documents) > TaxMaxDocuments:
		return snap, taxBad("too many documents")
	}
	if snap.Documents == nil {
		snap.Documents = []TaxDocument{}
	}
	for i := range snap.Documents {
		d := &snap.Documents[i]
		d.RowNo = i
		switch {
		case d.ArrivalDate.IsZero():
			return snap, taxBad("arrival_date")
		case !nvsOneOf(d.Category, TaxCategories):
			return snap, taxBad("category")
		case !taxSHA256Re.MatchString(d.ContentSHA256):
			return snap, taxBad("content_sha256")
		case !taxText(d.Kind) || !taxText(d.DocType) || !taxText(d.TaxType) || !taxText(d.Period):
			return snap, taxBad("text")
		}
	}
	return snap, nil
}
