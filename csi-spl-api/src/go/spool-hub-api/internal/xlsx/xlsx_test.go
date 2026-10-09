package xlsx

import (
	"archive/zip"
	"bytes"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func TestColName(t *testing.T) {
	for i, want := range map[int]string{0: "A", 25: "Z", 26: "AA", 27: "AB", 51: "AZ", 52: "BA", 701: "ZZ", 702: "AAA"} {
		if got := ColName(i); got != want {
			t.Errorf("ColName(%d) = %q, want %q", i, got, want)
		}
		if got := colIndex(want + "7"); got != i {
			t.Errorf("colIndex(%q) = %d, want %d", want+"7", got, i)
		}
	}
}

// The package opens: every part a spreadsheet needs, one sheet, the cells
// read back, numbers as numeric cells and text with XML specials intact.
func TestWriteReadBack(t *testing.T) {
	rows := [][]Cell{
		{Str("date"), Str("minutes"), Str("note")},
		{Str("2026-10-05"), Num(90), Str(`a <b> & "c"`)},
		{Str("2026-10-06"), Num(1.25), Str("")},
	}
	var buf bytes.Buffer
	if err := Write(&buf, "Hours: 2026/10", rows); err != nil {
		t.Fatal(err)
	}
	z, err := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	sheets := 0
	for _, f := range z.File {
		names = append(names, f.Name)
		if strings.HasPrefix(f.Name, "xl/worksheets/") {
			sheets++
		}
	}
	want := []string{"[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml"}
	if !reflect.DeepEqual(names, want) || sheets != 1 {
		t.Fatalf("parts %v, want %v (one sheet)", names, want)
	}
	got, err := Read(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil {
		t.Fatal(err)
	}
	wantCells := [][]string{{"date", "minutes", "note"}, {"2026-10-05", "90", `a <b> & "c"`}, {"2026-10-06", "1.25", ""}}
	if !reflect.DeepEqual(got, wantCells) {
		t.Fatalf("cells %q, want %q", got, wantCells)
	}
	types, err := CellTypes(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil {
		t.Fatal(err)
	}
	if types[1][1] != "n" || types[2][1] != "n" || types[1][0] != "inlineStr" {
		t.Fatalf("cell types %v", types)
	}
	wb := part(t, z, "xl/workbook.xml")
	if !strings.Contains(wb, `name="Hours 202610"`) {
		t.Fatalf("sheet name not cleaned: %s", wb)
	}
	if ct := part(t, z, "[Content_Types].xml"); !strings.Contains(ct, "spreadsheetml.worksheet+xml") {
		t.Fatalf("content types: %s", ct)
	}
}

func part(t *testing.T, z *zip.Reader, name string) string {
	t.Helper()
	for _, f := range z.File {
		if f.Name == name {
			rc, err := f.Open()
			if err != nil {
				t.Fatal(err)
			}
			defer rc.Close()
			var b bytes.Buffer
			b.ReadFrom(rc) //nolint:errcheck
			return b.String()
		}
	}
	t.Fatalf("no part %s", name)
	return ""
}

// A zip without the sheet parts is refused; garbage is refused.
func TestReadRefusesOtherFiles(t *testing.T) {
	var buf bytes.Buffer
	z := zip.NewWriter(&buf)
	w, _ := z.Create("readme.txt")
	w.Write([]byte("hi")) //nolint:errcheck
	z.Close()
	if _, err := Read(bytes.NewReader(buf.Bytes()), int64(buf.Len())); !errors.Is(err, ErrNotSheet) {
		t.Fatalf("plain zip: %v", err)
	}
	junk := []byte("not a zip")
	if _, err := Read(bytes.NewReader(junk), int64(len(junk))); !errors.Is(err, ErrNotSheet) {
		t.Fatalf("junk: %v", err)
	}
}
