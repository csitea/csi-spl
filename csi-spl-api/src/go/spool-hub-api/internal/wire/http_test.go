package wire

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// The bytes every client parses: pinned before the four package-local
// copies were folded into WriteJSON / WriteError (SPL-1031).
func TestWriteErrorBytes(t *testing.T) {
	rec := httptest.NewRecorder()
	rec.Header().Set("Cache-Control", "no-store")
	WriteError(rec, http.StatusConflict, "pin_conflict", "box already pinned")
	if rec.Code != http.StatusConflict {
		t.Fatalf("status %d", rec.Code)
	}
	if got := rec.Header().Get("Content-Type"); got != "application/json" {
		t.Fatalf("content-type %q", got)
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("an earlier header was lost: %q", got)
	}
	if got, want := rec.Body.String(), `{"error":"pin_conflict","detail":"box already pinned"}`+"\n"; got != want {
		t.Fatalf("body %q, want %q", got, want)
	}
}

func TestWriteJSONBytes(t *testing.T) {
	rec := httptest.NewRecorder()
	WriteJSON(rec, http.StatusOK, map[string]any{"ok": true, "n": 2})
	if got, want := rec.Body.String(), `{"n":2,"ok":true}`+"\n"; got != want || rec.Code != 200 {
		t.Fatalf("%d %q, want %q", rec.Code, got, want)
	}
}
