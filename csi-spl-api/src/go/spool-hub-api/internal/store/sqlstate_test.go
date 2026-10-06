package store

import (
	"errors"
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

// r4-16: one sqlState under the three named SQLSTATE helpers and mapFK; the
// same answer for every code, bare or wrapped.
func TestSQLState(t *testing.T) {
	pg := func(code, constraint string) error { return &pgconn.PgError{Code: code, ConstraintName: constraint} }
	tests := []struct {
		name       string
		err        error
		state      string
		unique     bool
		undefCol   bool
		fkInvite   bool
		mapsToMiss bool
	}{
		{name: "nil", err: nil},
		{name: "plain error", err: errors.New("23505")},
		{name: "unique", err: pg("23505", ""), state: "23505", unique: true},
		{name: "wrapped unique", err: fmt.Errorf("claim: %w", pg("23505", "tenants_operator_unique")), state: "23505", unique: true},
		{name: "undefined column", err: fmt.Errorf("list: %w", pg("42703", "")), state: "42703", undefCol: true},
		{name: "fk on the named constraint", err: pg("23503", "tenant_invites_role_fk"), state: "23503", fkInvite: true, mapsToMiss: true},
		{name: "wrapped fk on another constraint", err: fmt.Errorf("x: %w", pg("23503", "other_fk")), state: "23503", mapsToMiss: true},
		{name: "named constraint, other code", err: pg("23505", "tenant_invites_role_fk"), state: "23505", unique: true},
		{name: "check violation", err: pg("23514", ""), state: "23514"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := sqlState(tc.err); got != tc.state {
				t.Errorf("sqlState = %q, want %q", got, tc.state)
			}
			if got := isUniqueViolation(tc.err); got != tc.unique {
				t.Errorf("isUniqueViolation = %v, want %v", got, tc.unique)
			}
			if got := isUndefinedColumn(tc.err); got != tc.undefCol {
				t.Errorf("isUndefinedColumn = %v, want %v", got, tc.undefCol)
			}
			if got := isFKViolation(tc.err, "tenant_invites_role_fk"); got != tc.fkInvite {
				t.Errorf("isFKViolation = %v, want %v", got, tc.fkInvite)
			}
			if got := errors.Is(mapFK(tc.err), ErrNotFound); got != tc.mapsToMiss {
				t.Errorf("mapFK -> ErrNotFound = %v, want %v", got, tc.mapsToMiss)
			}
		})
	}
}
