package auth

import "time"

// BreakMicrosoftPKCE swaps the PKCE key after the flow started, so the token
// call sends a verifier that does not hash to the challenge (spec 018 SC-002).
func BreakMicrosoftPKCE(h *Handler) {
	h.idps[ProviderMicrosoft].(*Microsoft).pkceKey = []byte("another-key")
}

// SetMicrosoftJWKSClock drives the JWKS cache's clock (spec 018 FR-003).
func SetMicrosoftJWKSClock(h *Handler, now func() time.Time) {
	h.idps[ProviderMicrosoft].(*Microsoft).jwks.now = now
}
