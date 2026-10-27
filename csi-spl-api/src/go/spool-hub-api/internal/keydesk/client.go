package keydesk

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"time"
)

// RedactVia asks the desk socket at sock to remove every key it handed out
// from text (127 L9, the desk half), for a body that leaves the box: a spool
// send and the terminal mirror, which posts through spool send.
//
// No socket file means no key desk on this box root, so no key was handed
// out here: the text passes as it is. A socket that is there but does not
// answer FAILS CLOSED: the caller does not send. A seat may still hold a
// key the dead desk handed out, and nothing else can remove it.
func RedactVia(ctx context.Context, sock, text string) (string, error) {
	if _, err := os.Lstat(sock); errors.Is(err, os.ErrNotExist) {
		return text, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var d net.Dialer
	c, err := d.DialContext(ctx, "unix", sock)
	if err != nil {
		return "", fmt.Errorf("the desk key socket did not answer, so this text could not be checked for a vendor key: %w", err)
	}
	defer c.Close() //nolint:errcheck
	if t, ok := ctx.Deadline(); ok {
		_ = c.SetDeadline(t)
	}
	if err := json.NewEncoder(c).Encode(request{Op: "redact", Text: text}); err != nil {
		return "", fmt.Errorf("desk key socket: write: %w", err)
	}
	line, err := bufio.NewReader(io.LimitReader(c, 2*maxLine)).ReadBytes('\n')
	if err != nil {
		return "", errors.New("the desk key socket closed without redacting (refused this caller?)")
	}
	var r reply
	if json.Unmarshal(line, &r) != nil || !r.OK || r.Text == nil {
		return "", errors.New("the desk key socket refused to redact: " + r.Error)
	}
	return *r.Text, nil
}
