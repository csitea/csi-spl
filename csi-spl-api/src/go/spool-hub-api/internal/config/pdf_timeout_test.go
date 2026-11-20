package config

import (
	"testing"
	"time"
)

// spec 183 7.1.6: SPOOL_PDF_TIMEOUT is the hub's wait for one render. Unset
// loads 120s; a Go duration loads as given; zero, a negative and a
// non-duration refuse the hub's start. SPOOL_PDF_URL loads as given.
func TestLoadHubPDFTimeout(t *testing.T) {
	setHubBase(t)
	h, err := LoadHub()
	if err != nil {
		t.Fatal(err)
	}
	if h.PDFTimeout != 120*time.Second || h.PDFURL != "" {
		t.Fatalf("unset: PDFTimeout %s PDFURL %q, want 120s and \"\"", h.PDFTimeout, h.PDFURL)
	}
	t.Setenv("SPOOL_PDF_URL", "https://pdf.example.test")
	for v, want := range map[string]time.Duration{"2m": 2 * time.Minute, "150s": 150 * time.Second} {
		t.Setenv("SPOOL_PDF_TIMEOUT", v)
		h, err := LoadHub()
		if err != nil || h.PDFTimeout != want || h.PDFURL != "https://pdf.example.test" {
			t.Fatalf("%s: %v %v, want %s", v, err, h, want)
		}
	}
	// CONTROL: zero, a negative and a non-duration refuse.
	for _, bad := range []string{"0s", "-1s", "two minutes"} {
		t.Setenv("SPOOL_PDF_TIMEOUT", bad)
		if _, err := LoadHub(); err == nil {
			t.Fatalf("SPOOL_PDF_TIMEOUT=%s was accepted", bad)
		}
	}
}
