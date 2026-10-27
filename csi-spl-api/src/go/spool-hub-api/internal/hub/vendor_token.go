package hub

import (
	"net/http"
	"regexp"
)

// CodeVendorTokenInBody refuses a message body that holds a Claude
// subscription token (spec 159 4.3 / L23, row T8): the sign-in token lives
// only in the CLI's own files of the workspace's OS user, so a body that
// carries one is a leak and is never stored, fanned out or logged. Spec 127
// L9's hub redaction (row H2, per-workspace key fingerprints) is not built;
// until it is, this shape is refused at every body write rather than
// rewritten: a box body is signed, and the hub cannot change it without
// breaking the sender's signature. Not named Token*: gosec G101 reads a
// Token const as a credential.
const CodeVendorTokenInBody = "vendor_token_in_body"

// claudeOAuthShape is the Claude Code OAuth access (oat) and refresh (ort)
// token shape: sk-ant-oat01-<base64url>. The box redaction pass
// (csi-spl-orc spawn-agents/lib/spool_redact.py, claude-oauth-token) holds
// the same pattern, so a mirror post arrives already redacted.
var claudeOAuthShape = regexp.MustCompile(`sk-ant-o[ar]t[0-9]{2}-[A-Za-z0-9_-]{20,}`)

// vendorTokenRefusal is the 422 of a body that holds a vendor subscription
// token. The detail names the rule, never the matched text.
func vendorTokenRefusal(body string) *frameRefusal {
	if claudeOAuthShape.MatchString(body) {
		return &frameRefusal{CodeVendorTokenInBody, http.StatusUnprocessableEntity,
			"the body holds a Claude subscription token: remove it (spec 159 L23)"}
	}
	return nil
}
