package hub

import (
	"bytes"
	"context"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The CSV import (spec 154 v1.3 section 11.2.1, build row B15):
//
//	POST /v1/me/contacts/import?dry_run=1   the counts, nothing written
//	POST /v1/me/contacts/import             the counts, the new rows added
//
// The body is the file itself, text/csv: any other type is 415, so a page of
// another site cannot post one without the preflight that refuses it. A file
// is told apart by its header row: Google Contacts' export or the Spool export.
// A file refused whole writes nothing; a bad row is skipped and reported by
// line and code, the good rows import. No contact value goes into an answer or
// a log line (C12): a log line carries the counts only.

const (
	contactsImportMaxBytes = 5 << 20
	contactsImportMaxRows  = 25000
	contactsFormatGoogle   = "google"
	contactsFormatSpool    = "spool"
	// contactsCSVMultiSep separates several values of one Google cell
	// (unchecked, I believe, that Google writes them so, spec 11.2.1).
	contactsCSVMultiSep = " ::: "
	// contactsCSVGuarded is what csvSafe (hours_export.go) puts a ' before.
	contactsCSVGuarded = "=+-@\t\r"
)

// The fields of a file's row.
const (
	contactFieldFirst    = "first"
	contactFieldLast     = "last"
	contactFieldEmail    = "email"
	contactFieldPhone    = "phone"
	contactFieldCompany  = "company"
	contactFieldTitle    = "title"
	contactFieldBirthday = "birthday"
	contactFieldNotes    = "notes"
	contactFieldPhoto    = "photo"
)

// contactsGoogleHeader is both vocabularies of Google's export (spec 11.2.1):
// unknown columns are ignored, and the order is the file's.
var contactsGoogleHeader = map[string]string{
	"First Name": contactFieldFirst, "Given Name": contactFieldFirst,
	"Last Name": contactFieldLast, "Family Name": contactFieldLast,
	"E-mail 1 - Value": contactFieldEmail, "Phone 1 - Value": contactFieldPhone,
	"Organization Name": contactFieldCompany, "Organization 1 - Name": contactFieldCompany,
	"Organization Title": contactFieldTitle, "Organization 1 - Title": contactFieldTitle,
	"Birthday": contactFieldBirthday, "Notes": contactFieldNotes, "Photo": contactFieldPhoto,
}

// contactsSpoolHeader is the Spool export's columns; google_resource is not
// read, a link to Google is made only by the sync (spec 11.2.1).
var contactsSpoolHeader = map[string]string{
	"first_name": contactFieldFirst, "last_name": contactFieldLast,
	"email": contactFieldEmail, "phone": contactFieldPhone,
	"company": contactFieldCompany, "job_title": contactFieldTitle,
	"birthday": contactFieldBirthday, "notes": contactFieldNotes,
}

// contactSkip is one skipped row: the file's line and the code, never a value.
type contactSkip struct {
	Line int    `json:"line"`
	Code string `json:"code"`
}

// contactsImportFile is a parsed file: the cleaned rows and what was skipped.
type contactsImportFile struct {
	format  string
	total   int
	rows    []store.Contact
	skipped []contactSkip
	photos  int
}

// contactsRefusal is a whole file refused.
type contactsRefusal struct {
	status int
	code   string
	detail string
}

func contactsBadEncoding() *contactsRefusal {
	return &contactsRefusal{http.StatusBadRequest, "csv_bad_encoding", "the file is not UTF-8 text"}
}

func contactsTooLarge() *contactsRefusal {
	return &contactsRefusal{http.StatusRequestEntityTooLarge, "csv_too_large",
		fmt.Sprintf("the file is over %d bytes or %d rows", contactsImportMaxBytes, contactsImportMaxRows)}
}

// contactsMalformed is a file the CSV reader cannot read on from (LazyQuotes
// off): the answer names the line, the reader's own error is not sent.
func contactsMalformed(err error) *contactsRefusal {
	detail := "the file is not valid CSV"
	var pe *csv.ParseError
	if errors.As(err, &pe) {
		detail = fmt.Sprintf("the file is not valid CSV at line %d", pe.Line)
	}
	return &contactsRefusal{http.StatusBadRequest, "csv_malformed", detail}
}

// contactsColumns is where each field sits in a file's rows; a Google header
// may hold both spellings of one field, so a field can have several columns.
type contactsColumns map[string][]int

// contactsColumnsOf maps a header through names, unknown columns ignored.
func contactsColumnsOf(header []string, names map[string]string) contactsColumns {
	cols := contactsColumns{}
	for i, name := range header {
		if f, ok := names[strings.TrimSpace(name)]; ok {
			cols[f] = append(cols[f], i)
		}
	}
	return cols
}

// contactsFormatOf tells the format by the header row, "" for anything else.
// The Spool export is its exact header, of today or of v1.2; a Google export
// has a name, an email and a phone column, whatever else it holds.
func contactsFormatOf(header []string) (string, contactsColumns) {
	if joined := strings.Join(header, ","); joined == contactsCSVHeader || joined == contactsCSVHeaderV12 {
		return contactsFormatSpool, contactsColumnsOf(header, contactsSpoolHeader)
	}
	cols := contactsColumnsOf(header, contactsGoogleHeader)
	if (len(cols[contactFieldFirst]) > 0 || len(cols[contactFieldLast]) > 0) &&
		len(cols[contactFieldEmail]) > 0 && len(cols[contactFieldPhone]) > 0 {
		return contactsFormatGoogle, cols
	}
	return "", nil
}

// cell is a field's first non-empty value; a row shorter than the header has
// no value in the missing cells.
func (c contactsColumns) cell(rec []string, field string) string {
	for _, i := range c[field] {
		if i < len(rec) && rec[i] != "" {
			return rec[i]
		}
	}
	return ""
}

// contactsUnguard undoes csvSafe on a Spool export's cell, so a +phone reads
// back as the phone it was. Only the guard goes: a ' before anything csvSafe
// does not guard is the person's own.
func contactsUnguard(s string) string {
	if len(s) > 1 && s[0] == '\'' && strings.IndexByte(contactsCSVGuarded, s[1]) >= 0 {
		return s[1:]
	}
	return s
}

// contactsFirstValue is the first of a Google cell's several values.
func contactsFirstValue(s string) string {
	first, _, _ := strings.Cut(s, contactsCSVMultiSep)
	return first
}

// contact reads one row. Only the list-like Google fields can hold several
// values: notes are the person's own text, " ::: " in them stays.
func (c contactsColumns) contact(format string, rec []string) store.Contact {
	one := func(field string) string {
		s := c.cell(rec, field)
		if format == contactsFormatSpool {
			return contactsUnguard(s)
		}
		return s
	}
	many := func(field string) string {
		return contactsFirstValue(one(field))
	}
	if format == contactsFormatSpool {
		many = one
	}
	return store.Contact{FirstName: one(contactFieldFirst), LastName: one(contactFieldLast),
		Email: many(contactFieldEmail), Phone: many(contactFieldPhone),
		Company: many(contactFieldCompany), JobTitle: many(contactFieldTitle),
		Birthday: one(contactFieldBirthday), Notes: one(contactFieldNotes)}
}

// contactSkipCode is the row's skip code for CleanContact's error. "" is an
// error with no code: "not valid text" (store checkContactText), which a file
// cannot reach, because parseContactsCSV refuses invalid UTF-8 and any NUL
// before a row is read. It refuses the file rather than invent a sixth code.
func contactSkipCode(err error) string {
	switch {
	case errors.Is(err, store.ErrContactEmpty):
		return "row_empty"
	case errors.Is(err, store.ErrContactBadEmail):
		return "bad_email"
	case errors.Is(err, store.ErrContactBadPhone):
		return "bad_phone"
	case errors.Is(err, store.ErrContactTooLong):
		return "too_long"
	case errors.Is(err, store.ErrContactBadBirthday):
		return "bad_birthday"
	}
	return ""
}

// parseContactsCSV reads a file, or refuses it whole. A NUL is valid UTF-8 but
// no text: it is what a UTF-16 file with no byte order mark looks like here.
func parseContactsCSV(body []byte) (*contactsImportFile, *contactsRefusal) {
	body = bytes.TrimPrefix(body, []byte("\xef\xbb\xbf"))
	if !utf8.Valid(body) || bytes.IndexByte(body, 0) >= 0 {
		return nil, contactsBadEncoding()
	}
	cr := csv.NewReader(bytes.NewReader(body))
	cr.FieldsPerRecord = -1
	header, err := cr.Read()
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, contactsMalformed(err)
	}
	format, cols := contactsFormatOf(header)
	if format == "" {
		return nil, &contactsRefusal{http.StatusBadRequest, "csv_unknown_format", "not a Google Contacts or Spool export"}
	}
	f := &contactsImportFile{format: format, rows: []store.Contact{}, skipped: []contactSkip{}}
	for {
		rec, err := cr.Read()
		if errors.Is(err, io.EOF) {
			return f, nil
		}
		if err != nil {
			return nil, contactsMalformed(err)
		}
		if f.total++; f.total > contactsImportMaxRows {
			return nil, contactsTooLarge()
		}
		line, _ := cr.FieldPos(0)
		if refused := f.addRow(cols, rec, line); refused != nil {
			return nil, refused
		}
	}
}

// addRow sorts one row into the good and the skipped; a Photo value is a URL,
// which the hub never fetches from a file (spec 11.4), so it is only counted.
func (f *contactsImportFile) addRow(cols contactsColumns, rec []string, line int) *contactsRefusal {
	if cols.cell(rec, contactFieldPhoto) != "" {
		f.photos++
	}
	ct, err := store.CleanContact(cols.contact(f.format, rec))
	if err == nil {
		f.rows = append(f.rows, ct)
		return nil
	}
	code := contactSkipCode(err)
	if code == "" {
		return contactsBadEncoding()
	}
	f.skipped = append(f.skipped, contactSkip{Line: line, Code: code})
	return nil
}

// alreadyThereByPhone is D1's number: the rows with a phone and no email and no
// name whose number a live contact holds. A second read, only for a file that
// has such rows, before the write: afterwards the file's own rows hold them.
func (f *contactsImportFile) alreadyThereByPhone(ctx context.Context, c contactsMe) (int, error) {
	phones := slices.DeleteFunc(slices.Clone(f.rows), func(ct store.Contact) bool {
		return ct.Email != "" || ct.FirstName != "" || ct.LastName != ""
	})
	if len(phones) == 0 {
		return 0, nil
	}
	n, err := c.st.PreviewContactsImport(ctx, c.person, phones)
	return n.AlreadyThere, err
}

// contactsImportAnswer is both steps' answer: would_add on the dry run, added
// on the import. AlreadyThereByPhone is its own number, not strictly a part of
// AlreadyThere: a phone-only row repeating an earlier row of the file counts
// as a file duplicate there and can still count here (spec 11.2.1).
type contactsImportAnswer struct {
	Format              string        `json:"format"`
	Rows                int           `json:"rows"`
	WouldAdd            *int          `json:"would_add,omitempty"`
	Added               *int          `json:"added,omitempty"`
	AlreadyThere        int           `json:"already_there"`
	AlreadyThereByPhone int           `json:"already_there_by_phone"`
	DeletedHere         int           `json:"deleted_here"`
	FileDuplicates      int           `json:"file_duplicates"`
	Skipped             []contactSkip `json:"skipped"`
	PhotosIgnored       int           `json:"photos_ignored"`
}

// readContactsFile is the route's body, or the answer that refuses it.
func readContactsFile(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "text/csv" {
		writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "Content-Type must be text/csv")
		return nil, false
	}
	body, err := readAllCapped(w, r, contactsImportMaxBytes)
	var tooBig *http.MaxBytesError
	switch {
	case errors.As(err, &tooBig):
		refused := contactsTooLarge()
		writeErr(w, refused.status, refused.code, refused.detail)
		return nil, false
	case err != nil:
		writeErr(w, http.StatusBadRequest, "bad_request", "the body is unreadable")
		return nil, false
	}
	return body, true
}

// POST /v1/me/contacts/import[?dry_run=1]: both steps run one parse and one
// matcher. Any other dry_run value is refused, never read as "write".
func (s *Server) handleImportContacts(w http.ResponseWriter, r *http.Request) {
	c, ok := s.contactsCaller(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	dry := q.Has("dry_run")
	if dry && q.Get("dry_run") != "1" {
		writeErr(w, http.StatusBadRequest, "bad_request", "dry_run takes only the value 1")
		return
	}
	body, ok := readContactsFile(w, r)
	if !ok {
		return
	}
	f, refused := parseContactsCSV(body)
	if refused != nil {
		s.o.Log.Info().Str("op", "contacts_import").Str("person", c.person).Str("refused", refused.code).Msg("contacts")
		writeErr(w, refused.status, refused.code, refused.detail)
		return
	}
	byPhone, err := f.alreadyThereByPhone(r.Context(), c)
	if err != nil {
		s.contactsFail(w, "contacts_import", c, "", err)
		return
	}
	var n store.ContactImportCounts
	if dry {
		n, err = c.st.PreviewContactsImport(r.Context(), c.person, f.rows)
	} else {
		n, err = c.st.ImportContacts(r.Context(), c.person, f.rows, s.o.Now())
	}
	if err != nil {
		s.contactsFail(w, "contacts_import", c, "", err)
		return
	}
	s.o.Log.Info().Str("op", "contacts_import").Str("person", c.person).Str("format", f.format).Bool("dry_run", dry).
		Int("rows", f.total).Int("add", n.Add).Int("already_there", n.AlreadyThere).Int("already_there_by_phone", byPhone).
		Int("deleted_here", n.DeletedHere).Int("file_duplicates", n.FileDuplicates).Int("skipped", len(f.skipped)).
		Int("photos_ignored", f.photos).Msg("contacts")
	out := contactsImportAnswer{Format: f.format, Rows: f.total, AlreadyThere: n.AlreadyThere, AlreadyThereByPhone: byPhone,
		DeletedHere: n.DeletedHere, FileDuplicates: n.FileDuplicates, Skipped: f.skipped, PhotosIgnored: f.photos}
	if dry {
		out.WouldAdd = &n.Add
	} else {
		out.Added = &n.Add
	}
	writeJSON(w, http.StatusOK, out)
}
