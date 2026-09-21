package auth

import "net/http"

// MintSessionCookie signs an arbitrary claims value with this handler's
// session subkey and returns it as the session cookie. It exists for one
// control (005 T035): a browser must not be able to assert
// `diagnostics_enabled`, not even by presenting a cookie whose payload names
// it and whose MAC verifies. Only a test can build that cookie, because only
// a test has the key.
func MintSessionCookie(h *Handler, v any) *http.Cookie {
	tok, err := signToken(h.sessionKey, v)
	if err != nil {
		panic(err)
	}
	return h.sessionCookie(tok, 3600)
}
