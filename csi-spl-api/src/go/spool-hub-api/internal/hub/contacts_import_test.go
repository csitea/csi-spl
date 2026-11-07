package hub_test

import (
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 154 B15: the CSV import, the five fields and the picture route (cases
// C34-C37, C37b, C40, C12, and the choices of section 11.2.1). Memory, and
// Postgres under SPOOL_TEST_PG_DSN. Fixtures are FirstName LastName and
// example.com only.

const (
	contactsImportPath = contactsBase + "/import"
	contactsDryRun     = contactsImportPath + "?dry_run=1"
	// contactsGoogleFixture is HAND-WRITTEN from the header names of spec
	// 11.2.1, NOT a real export of a test account (the holder's ruling, msg
	// b3e76fe6): format google stays unproven against Google.
	contactsGoogleFixture = "testdata/contacts-google-export.csv"
	spoolHeaderNow        = "first_name,last_name,email,phone,google_resource,company,job_title,birthday,notes"
	spoolHeaderV12        = "first_name,last_name,email,phone,google_resource"
	googleHeaderOld       = "Name,Given Name,Family Name,Birthday,Notes,Photo,E-mail 1 - Type,E-mail 1 - Value,Phone 1 - Type,Phone 1 - Value,Organization 1 - Name,Organization 1 - Title"
)

// importCSV posts a file with the type text/csv.
func (c *contactsRig) importCSV(t *testing.T, path, file string) (int, map[string]any) {
	t.Helper()
	code, _, out := c.postRaw(t, path, "text/csv; charset=utf-8", []byte(file))
	return code, out
}

// postRaw posts a body as it is, from P1's browser.
func (c *contactsRig) postRaw(t *testing.T, path, ctype string, body []byte) (int, []byte, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, "http://api"+domain+path, bytes.NewReader(body))
	req.Header.Set("Origin", wuiOrigin)
	req.Header.Set("Content-Type", ctype)
	resp, err := c.b1.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	return resp.StatusCode, raw, out
}

// listAll is P1's whole list, every page.
func (c *contactsRig) listAll(t *testing.T) []store.Contact {
	t.Helper()
	all, err := c.r.e.st.(store.PersonalContacts).ExportContacts(context.Background(), c.p1)
	if err != nil {
		t.Fatal(err)
	}
	return all
}

// contactNamed is the row with that first name: the rows of one import share
// their created_at, so their order among themselves is their random ids'.
func contactNamed(t *testing.T, all []store.Contact, first string) store.Contact {
	t.Helper()
	for _, ct := range all {
		if ct.FirstName == first {
			return ct
		}
	}
	t.Fatalf("no contact named %q among %d", first, len(all))
	return store.Contact{}
}

// wantCounts checks the answer's numbers; rows must add up in every answer.
func wantCounts(t *testing.T, out map[string]any, want map[string]int) {
	t.Helper()
	for k, v := range want {
		if got, _ := out[k].(float64); int(got) != v {
			t.Errorf("%s = %v, want %d (answer %v)", k, out[k], v, out)
		}
	}
	num := func(k string) int { n, _ := out[k].(float64); return int(n) }
	skipped, _ := out["skipped"].([]any)
	if sum := num("would_add") + num("added") + num("already_there") + num("deleted_here") + num("file_duplicates") + len(skipped); sum != num("rows") {
		t.Errorf("the counts add to %d, rows = %d: %v", sum, num("rows"), out)
	}
}

// C34, C35: the dry run writes nothing, its twin writes the same rows, the
// second import adds 0; the several values of a cell give the first.
func TestContactsImportGoogleFixture(t *testing.T) {
	file, err := os.ReadFile(contactsGoogleFixture)
	if err != nil {
		t.Fatal(err)
	}
	c := newContactsRig(t, onAll)
	code, out := c.importCSV(t, contactsDryRun, string(file))
	if code != http.StatusOK || out["format"] != "google" {
		t.Fatalf("dry run = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"rows": 4, "would_add": 4, "already_there": 0, "photos_ignored": 1})
	if _, has := out["added"]; has {
		t.Errorf("a dry run answers added: %v", out)
	}
	if n := len(c.listAll(t)); n != 0 {
		t.Fatalf("the dry run wrote %d rows", n)
	}

	code, out = c.importCSV(t, contactsImportPath, string(file))
	if code != http.StatusOK {
		t.Fatalf("import = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"rows": 4, "added": 4})
	if _, has := out["would_add"]; has {
		t.Errorf("an import answers would_add: %v", out)
	}
	all := c.listAll(t)
	if len(all) != 4 {
		t.Fatalf("CONTROL: the import wrote %d rows, want 4", len(all))
	}
	first := contactNamed(t, all, "FirstName")
	for _, a := range [][2]string{{first.FirstName, "FirstName"}, {first.LastName, "LastName"}, {first.Email, "first.last@example.com"},
		{first.Phone, "+1 555 010 0001"}, {first.Company, "Example Company"}, {first.JobTitle, "Example Title"}, {first.Birthday, "1990-03-14"}} {
		if a[0] != a[1] {
			t.Errorf("read %q, want %q", a[0], a[1])
		}
	}
	if b := contactNamed(t, all, "FirstNameB"); b.Notes != "A note on\ntwo lines" || b.Birthday != "--07-02" {
		t.Errorf("second row = %q %q", b.Notes, b.Birthday)
	}

	code, out = c.importCSV(t, contactsImportPath, string(file))
	if code != http.StatusOK {
		t.Fatalf("second import = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"added": 0, "already_there": 4, "already_there_by_phone": 1})
	if n := len(c.listAll(t)); n != 4 {
		t.Errorf("the second import left %d rows, want 4", n)
	}
}

// Google's older vocabulary, columns in another order: the same fields.
func TestContactsImportGoogleOldHeader(t *testing.T) {
	c := newContactsRig(t, onAll)
	file := googleHeaderOld + "\nFirstName LastName,FirstName,LastName,--03-14,,,Work,first.last@example.com,Mobile,+1 555 010 0001,Example Company,Example Title\n"
	code, out := c.importCSV(t, contactsImportPath, file)
	if code != http.StatusOK || out["format"] != "google" {
		t.Fatalf("import = %d %v", code, out)
	}
	all := c.listAll(t)
	if len(all) != 1 || all[0].FirstName != "FirstName" || all[0].Email != "first.last@example.com" || all[0].JobTitle != "Example Title" {
		t.Fatalf("list = %+v", all)
	}
}

// " ::: " in notes is the person's own text; a row shorter than the header has
// no value in the missing cells, and a byte order mark is dropped.
func TestContactsImportCells(t *testing.T) {
	c := newContactsRig(t, onAll)
	file := "\xef\xbb\xbf" + googleHeaderOld + "\nX,FirstName,LastName,,one ::: two\nX,FirstNameB,LastNameB\n"
	code, out := c.importCSV(t, contactsImportPath, file)
	if code != http.StatusOK {
		t.Fatalf("import = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"added": 2})
	if got := contactNamed(t, c.listAll(t), "FirstName"); got.Notes != "one ::: two" {
		t.Errorf("notes = %q", got.Notes)
	}
}

// C36: what is refused whole writes nothing; the twins at the caps import.
func TestContactsImportRefusedWhole(t *testing.T) {
	c := newContactsRig(t, onAll)
	row := "FirstName,LastName,first.last@example.com,,\n"
	tooBig := spoolHeaderV12 + "\n" + row + strings.Repeat(" ", contactsImportMax+1-len(spoolHeaderV12)-1-len(row))
	var many strings.Builder
	many.WriteString(spoolHeaderV12 + "\n")
	for i := range 25001 {
		fmt.Fprintf(&many, "FirstName%d,LastName,,,\n", i)
	}
	for _, tc := range []struct {
		name, file string
		status     int
		code       string
	}{
		{"5 MiB + 1", tooBig, http.StatusRequestEntityTooLarge, "csv_too_large"},
		{"25,001 rows", many.String(), http.StatusRequestEntityTooLarge, "csv_too_large"},
		{"unknown header", "a,b,c\n1,2,3\n", http.StatusBadRequest, "csv_unknown_format"},
		{"empty file", "", http.StatusBadRequest, "csv_unknown_format"},
		{"the old header reordered", "last_name,first_name,email,phone,google_resource\nLastName,FirstName,,,\n", http.StatusBadRequest, "csv_unknown_format"},
		{"Latin-1", spoolHeaderV12 + "\nFirstN\xe4me,LastName,,,\n", http.StatusBadRequest, "csv_bad_encoding"},
		{"a NUL in a name", spoolHeaderV12 + "\nFirst\x00Name,LastName,,,\n", http.StatusBadRequest, "csv_bad_encoding"},
		{"a NUL in an email", spoolHeaderV12 + "\nFirstName,,first\x00@example.com,,\n", http.StatusBadRequest, "csv_bad_encoding"},
		{"UTF-16 with no BOM", "f\x00i\x00r\x00s\x00t\x00\n\x00", http.StatusBadRequest, "csv_bad_encoding"},
		{"a bare quote", spoolHeaderV12 + "\nFirst\"Name,LastName,,,\n", http.StatusBadRequest, "csv_malformed"},
		{"an open quote", spoolHeaderV12 + "\n\"FirstName,LastName,,,\n", http.StatusBadRequest, "csv_malformed"},
	} {
		for _, path := range []string{contactsDryRun, contactsImportPath} {
			code, out := c.importCSV(t, path, tc.file)
			if code != tc.status || realmToken(out) != tc.code {
				t.Errorf("%s %s = %d %v, want %d %s", tc.name, path, code, out, tc.status, tc.code)
			}
		}
	}
	if n := len(c.listAll(t)); n != 0 {
		t.Fatalf("a refused file wrote %d rows", n)
	}
	if strings.Contains(realmLogs(c.logs), "FirstName") {
		t.Error("C12: a refusal logged a value")
	}
}

const contactsImportMax = 5 << 20

// C36's twin: exactly 5 MiB and exactly 25,000 rows import.
func TestContactsImportAtTheCaps(t *testing.T) {
	c := newContactsRig(t, onAll)
	head := spoolHeaderV12 + "\n"
	row := "FirstName,LastName,first.last@example.com,,\n"
	file := head + row + strings.Repeat("\n", contactsImportMax-len(head)-len(row))
	code, out := c.importCSV(t, contactsImportPath, file)
	if code != http.StatusOK {
		t.Fatalf("5 MiB = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"rows": 1, "added": 1})

	var many strings.Builder
	many.WriteString(head)
	for i := range 25000 {
		fmt.Fprintf(&many, "First%d,Last,,,\n", i)
	}
	code, out = c.importCSV(t, contactsImportPath, many.String())
	if code != http.StatusOK {
		t.Fatalf("25,000 rows = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"rows": 25000, "added": 25000})
}

// A body that is not text/csv is 415, so a form of another site cannot post
// one without the preflight; a dry_run other than 1 is never read as a write.
func TestContactsImportContentTypeAndDryRun(t *testing.T) {
	c := newContactsRig(t, onAll)
	file := spoolHeaderV12 + "\nFirstName,LastName,,,\n"
	for _, ctype := range []string{"text/plain", "application/x-www-form-urlencoded", "multipart/form-data; boundary=x", ""} {
		code, _, out := c.postRaw(t, contactsImportPath, ctype, []byte(file))
		if code != http.StatusUnsupportedMediaType || realmToken(out) != "unsupported_media_type" {
			t.Errorf("type %q = %d %v, want 415", ctype, code, out)
		}
	}
	for _, q := range []string{"?dry_run=true", "?dry_run=0", "?dry_run="} {
		code, out := c.importCSV(t, contactsImportPath+q, file)
		if code != http.StatusBadRequest {
			t.Errorf("%s = %d %v, want 400", q, code, out)
		}
	}
	if n := len(c.listAll(t)); n != 0 {
		t.Fatalf("CONTROL: %d rows written by refused requests", n)
	}
	if code, out := c.importCSV(t, contactsImportPath, file); code != http.StatusOK {
		t.Fatalf("CONTROL: text/csv = %d %v", code, out)
	}
	code, raw, _ := c.do(t, c.b1, http.MethodOptions, contactsImportPath, nil, map[string]string{"Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "content-type"})
	if code != http.StatusNoContent {
		t.Errorf("preflight = %d %s", code, raw)
	}
}

// C37, C12: good rows import; each bad row is listed by the file's line and
// code, with no value in the answer or the log. Line numbers count the lines
// of a quoted cell. Its twin: a clean file has skipped: [].
func TestContactsImportSkipsBadRows(t *testing.T) {
	c := newContactsRig(t, onAll)
	long := strings.Repeat("x", 101)
	file := strings.Join([]string{
		spoolHeaderNow,
		`,,,,,,,,`,                  // line 2: no value
		`SecretFirst,,no-at-sign,,`, // 3: a bad email
		`"FirstName","LastName",first.last@example.com,,,,,,"a note on`, // 4-5
		`two lines"`,
		`SecretSecond,,,bad!phone,`,          // 6
		long + `,,,,`,                        // 7: over a cap
		`SecretThird,,,,,,,1990-13-40,`,      // 8: not a date
		`FirstNameB,LastNameB,,,,,,--02-29,`, // 9: good, a leap day
		`,,,,,Only A Company,,,`,             // 10: a company alone is no contact
	}, "\n") + "\n"
	code, out := c.importCSV(t, contactsImportPath, file)
	if code != http.StatusOK {
		t.Fatalf("import = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"rows": 8, "added": 2})
	want := []struct {
		line int
		code string
	}{{2, "row_empty"}, {3, "bad_email"}, {6, "bad_phone"}, {7, "too_long"}, {8, "bad_birthday"}, {10, "row_empty"}}
	got, _ := out["skipped"].([]any)
	if len(got) != len(want) {
		t.Fatalf("skipped = %v", got)
	}
	for i, w := range want {
		row := got[i].(map[string]any)
		if int(row["line"].(float64)) != w.line || row["code"] != w.code || len(row) != 2 {
			t.Errorf("skipped[%d] = %v, want %+v", i, row, w)
		}
	}
	all := c.listAll(t)
	if len(all) != 2 || contactNamed(t, all, "FirstNameB").Birthday != "--02-29" {
		t.Fatalf("list = %d rows", len(all))
	}
	logs := realmLogs(c.logs)
	for _, banned := range []string{"Secret", "no-at-sign", "bad!phone", "first.last", "1990-13-40", "Only A Company", "a note on"} {
		if strings.Contains(logs, banned) {
			t.Errorf("C12: the log carries %q", banned)
		}
	}
	if !strings.Contains(logs, `"skipped":6`) {
		t.Errorf("CONTROL: the log has no count of the skipped rows: %s", logs)
	}
	code, out = c.importCSV(t, contactsImportPath, spoolHeaderV12+"\nFirstNameC,LastNameC,,,\n")
	if code != http.StatusOK || len(out["skipped"].([]any)) != 0 {
		t.Errorf("twin: a clean file = %d %v, want skipped: []", code, out)
	}
}

// C37b: a row matching a soft-deleted contact is not resurrected; its twin
// after the purge imports. The purge runs through the store's door.
func TestContactsImportDeletedHere(t *testing.T) {
	c := newContactsRig(t, onAll)
	id := c.create(t, c.b1, map[string]any{"first_name": ctFirst, "email": ctEmail})
	st := c.r.e.st.(store.PersonalContacts)
	if err := st.DeleteContact(context.Background(), c.p1, id, store.ContactDeletedByMember, time.Now()); err != nil {
		t.Fatal(err)
	}
	file := spoolHeaderV12 + "\n" + ctFirst + ",," + ctEmail + ",,\n"
	code, out := c.importCSV(t, contactsImportPath, file)
	if code != http.StatusOK {
		t.Fatalf("import = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"added": 0, "deleted_here": 1})
	if _, err := st.PurgeDeletedContacts(context.Background(), time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	code, out = c.importCSV(t, contactsImportPath, file)
	if code != http.StatusOK {
		t.Fatalf("twin = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"added": 1, "deleted_here": 0})
}

// D1, the holder's ruling: a row with a phone and no email and no name counts
// as already there when any contact holds the number; its company and notes
// are not added, and already_there_by_phone shows the count. A named row that
// matches is not in it. The corner: a phone-only row repeating an earlier row of
// the file is a file duplicate in the main counts and still counts here.
func TestContactsImportAlreadyThereByPhone(t *testing.T) {
	c := newContactsRig(t, onAll)
	id := c.create(t, c.b1, map[string]any{"first_name": ctFirst, "last_name": ctLast, "phone": "+1 555 010 0000", "email": ctEmail})
	file := spoolHeaderNow + "\n" + strings.Join([]string{
		`,,,15550100000,,Example Company,,,a note`,    // the held number, written another way
		ctFirst + `,` + ctLast + `,` + ctEmail + `,,`, // matches by email, not by phone
		`,,,+1 555 010 0009,`,                         // a new number
	}, "\n") + "\n"
	code, out := c.importCSV(t, contactsDryRun, file)
	if code != http.StatusOK {
		t.Fatalf("dry run = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"would_add": 1, "already_there": 2, "already_there_by_phone": 1})
	code, out = c.importCSV(t, contactsImportPath, file)
	if code != http.StatusOK {
		t.Fatalf("import = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"added": 1, "already_there": 2, "already_there_by_phone": 1})
	ct, err := c.r.e.st.(store.PersonalContacts).ContactOf(context.Background(), c.p1, id)
	if err != nil {
		t.Fatal(err)
	}
	if ct.Company != "" || ct.Notes != "" {
		t.Errorf("D1: an import merged into a held contact: %q %q", ct.Company, ct.Notes)
	}

	c2 := newContactsRig(t, onAll)
	c2.create(t, c2.b1, map[string]any{"phone": "+1 555 010 0000"})
	corner := spoolHeaderV12 + "\nFirstName,LastName,,+1 555 010 0000,\n,,,15550100000,\n"
	code, out = c2.importCSV(t, contactsDryRun, corner)
	if code != http.StatusOK {
		t.Fatalf("corner = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"would_add": 1, "file_duplicates": 1, "already_there": 0, "already_there_by_phone": 1})

	// Twin: nothing held, the number is 0 and the row is added.
	c3 := newContactsRig(t, onAll)
	code, out = c3.importCSV(t, contactsImportPath, spoolHeaderV12+"\n,,,+1 555 010 0000,\n")
	if code != http.StatusOK {
		t.Fatalf("twin = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"added": 1, "already_there_by_phone": 0})
}

// C40: the nine-column export, the old header its prefix, the formula guard on
// every cell; a v1.2 export file imports with format spool; a list moved through
// the export comes back equal, +phone and --MM-DD included (the guard undone).
func TestContactsExportImportRoundTrip(t *testing.T) {
	c := newContactsRig(t, onAll)
	c.create(t, c.b1, map[string]any{"first_name": ctFirst, "last_name": ctLast, "email": ctEmail, "phone": ctPhone,
		"company": "Example Company", "job_title": "Example Title", "birthday": "--03-14", "notes": "=cmd"})
	code, raw, _ := c.do(t, c.b1, http.MethodGet, contactsBase+"/export", nil, nil)
	if code != http.StatusOK {
		t.Fatalf("export = %d %s", code, raw)
	}
	rows, err := csv.NewReader(bytes.NewReader(raw)).ReadAll()
	if err != nil || len(rows) != 2 {
		t.Fatalf("export = %v %q", err, raw)
	}
	head := strings.Join(rows[0], ",")
	if head != spoolHeaderNow || !strings.HasPrefix(head, spoolHeaderV12) {
		t.Errorf("header = %q", head)
	}
	if rows[1][8] != "'=cmd" || rows[1][3] != "'"+ctPhone || rows[1][7] != "'--03-14" {
		t.Errorf("C40: the guard is missing: %q", rows[1])
	}

	c2 := newContactsRig(t, onAll)
	code, out := c2.importCSV(t, contactsImportPath, string(raw))
	if code != http.StatusOK || out["format"] != "spool" {
		t.Fatalf("import = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"added": 1})
	all := c2.listAll(t)
	if len(all) != 1 {
		t.Fatalf("list = %d rows", len(all))
	}
	got := all[0]
	if got.Phone != ctPhone || got.Birthday != "--03-14" || got.Notes != "=cmd" || got.Company != "Example Company" || got.JobTitle != "Example Title" {
		t.Errorf("came back as %+v", got)
	}
	if got.GoogleResource != "" {
		t.Errorf("an import linked to Google: %q", got.GoogleResource)
	}

	c3 := newContactsRig(t, onAll)
	v12 := spoolHeaderV12 + "\nFirstName,LastName," + ctEmail + ",'+1 555 010 0000,people/c1\n"
	code, out = c3.importCSV(t, contactsImportPath, v12)
	if code != http.StatusOK || out["format"] != "spool" {
		t.Fatalf("v1.2 = %d %v", code, out)
	}
	wantCounts(t, out, map[string]int{"added": 1})
	if all := c3.listAll(t); all[0].Phone != "+1 555 010 0000" || all[0].GoogleResource != "" {
		t.Errorf("v1.2 row = %+v", all[0])
	}

	// A ' the guard did not write stays; Google's format has no guard at all.
	c4 := newContactsRig(t, onAll)
	own := spoolHeaderV12 + "\n'Own,LastName,,,\n"
	if code, out = c4.importCSV(t, contactsImportPath, own); code != http.StatusOK {
		t.Fatalf("own = %d %v", code, out)
	}
	if all := c4.listAll(t); all[0].FirstName != "'Own" {
		t.Errorf("own ' = %q", all[0].FirstName)
	}
	g := googleHeaderOld + "\nX,'=FirstName,LastName\n"
	if code, out = c4.importCSV(t, contactsImportPath, g); code != http.StatusOK {
		t.Fatalf("google = %d %v", code, out)
	}
	contactNamed(t, c4.listAll(t), "'=FirstName")
}

// The five fields on the routes; "" clears, null keeps; the two new codes. The
// values at their caps fit the route's body, which 4 KiB did not (11.2.1).
func TestContactsFiveFields(t *testing.T) {
	c := newContactsRig(t, onAll)
	notes := strings.Repeat("ä", store.ContactNotesMax)
	code, raw, out := c.do(t, c.b1, http.MethodPost, contactsBase, map[string]any{"first_name": ctFirst, "company": "Example Company",
		"job_title": "Example Title", "birthday": "1990-03-14", "notes": notes}, nil)
	if code != http.StatusCreated {
		t.Fatalf("POST at the caps = %d %s", code, raw[:min(len(raw), 200)])
	}
	if out["company"] != "Example Company" || out["job_title"] != "Example Title" || out["birthday"] != "1990-03-14" || out["notes"] != notes ||
		out["in_only"] != false || out["photo"] != nil {
		t.Errorf("answer = %v", out)
	}
	id, _ := out["contact_id"].(string)
	one := contactsBase + "/" + id
	code, _, out = c.do(t, c.b1, http.MethodPatch, one, map[string]any{"company": "", "birthday": ""}, nil)
	if code != http.StatusOK || out["company"] != "" || out["birthday"] != nil || out["job_title"] != "Example Title" {
		t.Errorf("patch = %d %v", code, out)
	}
	for _, tc := range []struct {
		name string
		body map[string]any
		code string
	}{
		{"notes over", map[string]any{"first_name": ctFirst, "notes": strings.Repeat("x", store.ContactNotesMax+1)}, "too_long"},
		{"company over", map[string]any{"first_name": ctFirst, "company": strings.Repeat("x", store.ContactCompanyMax+1)}, "too_long"},
		{"a bad date", map[string]any{"first_name": ctFirst, "birthday": "1990-13-40"}, "bad_birthday"},
	} {
		if code, _, out := c.do(t, c.b1, http.MethodPost, contactsBase, tc.body, nil); code != http.StatusBadRequest || realmToken(out) != tc.code {
			t.Errorf("%s = %d %v, want 400 %s", tc.name, code, out, tc.code)
		}
	}
	// The sync switch keeps its small body.
	big := map[string]any{"enabled": true, "x": strings.Repeat("x", 5<<10)}
	if code, _, _ := c.do(t, c.b1, http.MethodPut, contactsBase+"/sync", big, nil); code != http.StatusBadRequest {
		t.Errorf("sync switch with 5 KiB = %d, want 400", code)
	}
}

// The picture route (11.4): bytes, type and the avatar route's headers, a 304,
// and 404 for none, another person's id and after the erase; the sha reaches
// the list and the card, and the bytes neither.
func TestContactPhotoRoute(t *testing.T) {
	c := newContactsRig(t, onAll)
	id := c.create(t, c.b1, map[string]any{"first_name": ctFirst})
	one := contactsBase + "/" + id
	path := one + "/photo"
	if code, _, _ := c.do(t, c.b1, http.MethodGet, path, nil, nil); code != http.StatusNotFound {
		t.Errorf("no picture = %d, want 404", code)
	}
	st := c.r.e.st.(store.PersonalContacts)
	png := []byte("\x89PNG\r\n\x1a\nsynthetic")
	p, err := st.PutContactPhoto(context.Background(), c.p1, id, store.ContactPhoto{Mime: "image/png", Bytes: png, SourceURLHash: strings.Repeat("a", 64)}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest(http.MethodGet, "http://api"+domain+path, nil)
	req.Header.Set("Origin", wuiOrigin)
	resp, err := c.b1.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	etag := `"` + p.SHA256 + `"`
	for k, v := range map[string]string{"Content-Type": "image/png", "Cache-Control": "private, no-cache", "ETag": etag, "X-Content-Type-Options": "nosniff"} {
		if got := resp.Header.Get(k); got != v {
			t.Errorf("%s = %q, want %q", k, got, v)
		}
	}
	if resp.StatusCode != http.StatusOK || !bytes.Equal(body, png) {
		t.Errorf("picture = %d %q", resp.StatusCode, body)
	}
	if code, raw, _ := c.do(t, c.b1, http.MethodGet, path, nil, map[string]string{"If-None-Match": etag}); code != http.StatusNotModified || len(raw) != 0 {
		t.Errorf("If-None-Match = %d %q, want 304", code, raw)
	}
	_, raw, out := c.do(t, c.b1, http.MethodGet, one, nil, nil)
	if out["photo"] != p.SHA256 || bytes.Contains(raw, []byte("synthetic")) {
		t.Errorf("card = %s", raw)
	}
	_, _, out = c.do(t, c.b1, http.MethodGet, contactsBase, nil, nil)
	if l := contactsOf(t, out); l[0]["photo"] != p.SHA256 {
		t.Errorf("list row = %v", l[0])
	}

	other, _ := c.other(t, "developer")
	if code, _, _ := c.do(t, other, http.MethodGet, path, nil, nil); code != http.StatusNotFound {
		t.Errorf("another person's picture = %d, want 404", code)
	}
	if code, _, _ := c.do(t, c.b1, http.MethodDelete, one, nil, nil); code != http.StatusNoContent {
		t.Fatalf("delete = %d", code)
	}
	if code, _, _ := c.do(t, c.b1, http.MethodGet, path, nil, nil); code != http.StatusNotFound {
		t.Errorf("after the erase = %d, want 404", code)
	}
}

// Who may import: the same gate as every contacts route (C4b, C6).
func TestContactsImportGates(t *testing.T) {
	c := newContactsRig(t, func(w1, _ string) []string { return []string{w1} })
	file := spoolHeaderV12 + "\nFirstName,LastName,,,\n"
	req, _ := http.NewRequest(http.MethodPost, "http://api"+domain+contactsImportPath, strings.NewReader(file))
	req.Header.Set("Origin", wuiOrigin)
	req.Header.Set("Content-Type", "text/csv")
	req.Header.Set("Authorization", "Bearer box-token")
	resp, err := c.b1.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Errorf("a box token = %d, want 403", resp.StatusCode)
	}
	req2, _ := http.NewRequest(http.MethodPost, "http://api"+domain+contactsImportPath, strings.NewReader(file))
	req2.Header.Set("Origin", wuiOrigin)
	req2.Header.Set("Content-Type", "text/csv")
	resp2, err := c.b2.Do(req2)
	if err != nil {
		t.Fatal(err)
	}
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusNotFound {
		t.Errorf("a workspace off the switch = %d, want 404", resp2.StatusCode)
	}
	if n := len(c.listAll(t)); n != 0 {
		t.Errorf("a refused import wrote %d rows", n)
	}
}
