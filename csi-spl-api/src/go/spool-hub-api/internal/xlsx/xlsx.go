// Package xlsx writes (and reads back) a one-sheet Office Open XML
// spreadsheet with Go's standard archive/zip and encoding/xml: no dependency
// (spec 107 v1.0, T009, section 6.2). Text is written as inline strings and
// numbers as numeric cells (t="n"), so a spreadsheet sums them. There is no
// styles part: every cell takes the default format.
package xlsx

import (
	"archive/zip"
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// Cell is one cell: text, or a number when IsNum.
type Cell struct {
	Text  string
	Num   float64
	IsNum bool
}

// Str is a text cell.
func Str(s string) Cell { return Cell{Text: s} }

// Num is a numeric cell.
func Num(f float64) Cell { return Cell{Num: f, IsNum: true} }

// The parts of the package, in the order they are written.
const (
	partContentTypes = "[Content_Types].xml"
	partRels         = "_rels/.rels"
	partWorkbook     = "xl/workbook.xml"
	partWorkbookRels = "xl/_rels/workbook.xml.rels"
	partSheet        = "xl/worksheets/sheet1.xml"
)

// ContentType is the media type of an .xlsx file.
const ContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

const xmlHead = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` + "\n"

const contentTypesXML = xmlHead + `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
	`<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>` +
	`<Default Extension="xml" ContentType="application/xml"/>` +
	`<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>` +
	`<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>` +
	`</Types>`

const relsXML = xmlHead + `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
	`<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>` +
	`</Relationships>`

const workbookRelsXML = xmlHead + `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
	`<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>` +
	`</Relationships>`

const nsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

// MaxSheetName is the longest sheet name a spreadsheet accepts.
const MaxSheetName = 31

// sheetName is name without the characters a sheet name refuses, cut to
// MaxSheetName; "Sheet1" when nothing is left.
func sheetName(name string) string {
	name = strings.Map(func(r rune) rune {
		if strings.ContainsRune(`[]:*?/\`, r) || r < 0x20 {
			return -1
		}
		return r
	}, strings.TrimSpace(name))
	if rs := []rune(name); len(rs) > MaxSheetName {
		name = string(rs[:MaxSheetName])
	}
	if name == "" {
		return "Sheet1"
	}
	return name
}

func escape(s string) string {
	var b bytes.Buffer
	xml.EscapeText(&b, []byte(s)) //nolint:errcheck // a bytes.Buffer does not fail
	return b.String()
}

// ColName is the column letters of the 0-based column i (0 = A, 26 = AA).
func ColName(i int) string {
	s := ""
	for i++; i > 0; i = (i - 1) / 26 {
		s = string(rune('A'+(i-1)%26)) + s
	}
	return s
}

func workbookXML(sheet string) string {
	return xmlHead + `<workbook xmlns="` + nsMain + `" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">` +
		`<sheets><sheet name="` + escape(sheetName(sheet)) + `" sheetId="1" r:id="rId1"/></sheets></workbook>`
}

func sheetXML(rows [][]Cell) string {
	var b strings.Builder
	b.WriteString(xmlHead + `<worksheet xmlns="` + nsMain + `"><sheetData>`)
	for ri, row := range rows {
		fmt.Fprintf(&b, `<row r="%d">`, ri+1)
		for ci, c := range row {
			ref := ColName(ci) + strconv.Itoa(ri+1)
			if c.IsNum {
				fmt.Fprintf(&b, `<c r="%s" t="n"><v>%s</v></c>`, ref, strconv.FormatFloat(c.Num, 'f', -1, 64))
				continue
			}
			fmt.Fprintf(&b, `<c r="%s" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>`, ref, escape(c.Text))
		}
		b.WriteString(`</row>`)
	}
	b.WriteString(`</sheetData></worksheet>`)
	return b.String()
}

// Write writes rows as the one sheet named sheet.
func Write(w io.Writer, sheet string, rows [][]Cell) error {
	z := zip.NewWriter(w)
	parts := []struct{ name, body string }{
		{partContentTypes, contentTypesXML},
		{partRels, relsXML},
		{partWorkbook, workbookXML(sheet)},
		{partWorkbookRels, workbookRelsXML},
		{partSheet, sheetXML(rows)},
	}
	for _, p := range parts {
		f, err := z.Create(p.name)
		if err != nil {
			return err
		}
		if _, err := io.WriteString(f, p.body); err != nil {
			return err
		}
	}
	return z.Close()
}

// ---- reading back -------------------------------------------------------------

// ErrNotSheet: the file is not a package this package wrote.
var ErrNotSheet = errors.New("xlsx: not a one-sheet spreadsheet")

type readCell struct {
	Ref    string `xml:"r,attr"`
	Type   string `xml:"t,attr"`
	Value  string `xml:"v"`
	Inline string `xml:"is>t"`
}

type readSheet struct {
	Rows []struct {
		Cells []readCell `xml:"c"`
	} `xml:"sheetData>row"`
}

// colIndex is the 0-based column of a cell reference such as "AB12".
func colIndex(ref string) int {
	n := 0
	for _, r := range ref {
		if r < 'A' || r > 'Z' {
			break
		}
		n = n*26 + int(r-'A'+1)
	}
	return n - 1
}

// sheet decodes the first sheet, after checking the parts Write writes are
// all present.
func sheet(r io.ReaderAt, size int64) (readSheet, error) {
	var ws readSheet
	z, err := zip.NewReader(r, size)
	if err != nil {
		return ws, fmt.Errorf("%w: %v", ErrNotSheet, err)
	}
	files := map[string]*zip.File{}
	for _, f := range z.File {
		files[f.Name] = f
	}
	for _, p := range []string{partContentTypes, partRels, partWorkbook, partWorkbookRels, partSheet} {
		if files[p] == nil {
			return ws, fmt.Errorf("%w: no %s", ErrNotSheet, p)
		}
	}
	rc, err := files[partSheet].Open()
	if err != nil {
		return ws, err
	}
	defer rc.Close()
	if err := xml.NewDecoder(rc).Decode(&ws); err != nil {
		return ws, fmt.Errorf("%w: %v", ErrNotSheet, err)
	}
	return ws, nil
}

// Read is the cells of the first sheet as text, by row, each cell at its
// column.
func Read(r io.ReaderAt, size int64) ([][]string, error) {
	ws, err := sheet(r, size)
	if err != nil {
		return nil, err
	}
	out := make([][]string, 0, len(ws.Rows))
	for _, row := range ws.Rows {
		var line []string
		for _, c := range row.Cells {
			i := colIndex(c.Ref)
			if i < 0 {
				i = len(line)
			}
			for len(line) <= i {
				line = append(line, "")
			}
			if c.Type == "inlineStr" {
				line[i] = c.Inline
			} else {
				line[i] = c.Value
			}
		}
		out = append(out, line)
	}
	return out, nil
}

// CellTypes is the t attribute of every cell of the first sheet, by row: how
// a test proves a number is written as a number.
func CellTypes(r io.ReaderAt, size int64) ([][]string, error) {
	ws, err := sheet(r, size)
	if err != nil {
		return nil, err
	}
	out := make([][]string, 0, len(ws.Rows))
	for _, row := range ws.Rows {
		var ts []string
		for _, c := range row.Cells {
			ts = append(ts, c.Type)
		}
		out = append(out, ts)
	}
	return out, nil
}
