//go:build tools

// Spec 136 section 11: lane L1 owns go.mod for the whole spec. This file,
// never built, keeps the modules of the later lanes direct requires, so they
// import them with no go.mod edit: x/term (L2, the passphrase read on
// /dev/tty) and x/sys/unix (L2, keyd's mlock and SO_PEERCRED).
package enc

import (
	_ "golang.org/x/sys/unix"
	_ "golang.org/x/term"
)
