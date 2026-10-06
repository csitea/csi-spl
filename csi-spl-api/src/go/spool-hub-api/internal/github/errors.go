package github

import (
	"errors"
	"fmt"
	"net/http"
)

// The worker sorts every failure into one of these (spec §3 "Retries").
var (
	// ErrTransient: GitHub 5xx, 429, a network error, or ErrRefMoved. Retry
	// with backoff.
	ErrTransient = errors.New("github: transient")
	// ErrPermanent: 401 (key missing or revoked), 403, 404, 422 validation.
	// The row goes failed at once.
	ErrPermanent = errors.New("github: permanent")
	// ErrRefMoved: the fast-forward ref update was refused (422) because the
	// branch moved past the commit's parent. Transient: re-read head, merge,
	// commit again (spec §6.2, §8).
	ErrRefMoved = errors.New("github: ref moved")
)

// APIError is one refused or failed call. Status 0 is a network error.
type APIError struct {
	Op      string
	Status  int
	Message string
	refMove bool
}

func (e *APIError) Error() string {
	if e.Status == 0 {
		return fmt.Sprintf("github %s: %s", e.Op, e.Message)
	}
	return fmt.Sprintf("github %s: %d %s", e.Op, e.Status, e.Message)
}

// Unwrap lets errors.Is match ErrTransient / ErrPermanent / ErrRefMoved.
func (e *APIError) Unwrap() []error {
	if e.refMove {
		return []error{ErrRefMoved, ErrTransient}
	}
	if e.transient() {
		return []error{ErrTransient}
	}
	return []error{ErrPermanent}
}

func (e *APIError) transient() bool {
	return e.Status == 0 || e.Status == http.StatusTooManyRequests || e.Status >= 500
}
