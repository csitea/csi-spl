package wire

import (
	"encoding/json"
	"net/http"
)

// WriteJSON answers status with v as the JSON body. Headers set before the
// call (Cache-Control, Retry-After) are kept. It is the one response writer
// of the hub, auth, payments and edge packages (SPL-1031).
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v) //nolint:errcheck // the client went away; nothing to answer
}

// WriteError answers status with the shared error envelope
// (003 contracts/http-v1.md): {"error": token, "detail": detail}.
func WriteError(w http.ResponseWriter, status int, token, detail string) {
	WriteJSON(w, status, ErrorBody{Error: token, Detail: detail})
}
