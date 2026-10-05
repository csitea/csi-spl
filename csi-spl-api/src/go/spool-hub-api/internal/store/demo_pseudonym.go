package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"

	"github.com/jackc/pgx/v5"
)

// Pseudonyms (specs/077 FR-007, T011, spec 3.5). Demo visitors see each
// other's posts, so a demo_user seat never shows the IdP name, the email or
// the IdP picture: open admission sets humans.display_name to DemoPseudonym
// and clears the avatar (pseudonymTx; the memory store's grant), the sign-in
// stores no picture for it (AuthHooks.Register), and the visitor cannot
// rename themselves (AuthHooks.SetDisplayName). With no avatar_file_id the
// WUI draws its deterministic default, so the avatar is generated. The name
// leaves with the humans row when the expiry sweep drops it (demo_stay.go).

// DemoPseudonymPrefix starts every demo visitor's display name.
const DemoPseudonymPrefix = "visitor-"

// DemoPseudonym is humanID's display name in the demo: "visitor-" and the
// first 4 hex of sha256(humanID). Derived, so a return visit by the same
// human reads the same name; the hash keeps the HUM-* sequence out of it.
func DemoPseudonym(humanID string) string {
	sum := sha256.Sum256([]byte(humanID))
	return DemoPseudonymPrefix + hex.EncodeToString(sum[:2])
}

// pseudonymTx replaces hum's IdP name with its pseudonym and drops its IdP
// picture inside the admission transaction, so no reader ever sees the new
// demo seat under the IdP name.
func pseudonymTx(ctx context.Context, tx pgx.Tx, hum string) error {
	_, err := tx.Exec(ctx, `UPDATE humans SET display_name = $2, avatar_file_id = NULL WHERE human_id = $1`,
		hum, DemoPseudonym(hum))
	return err
}
