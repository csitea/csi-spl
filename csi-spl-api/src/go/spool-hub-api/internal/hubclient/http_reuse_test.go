package hubclient

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

// TestDefaultHTTPReusesConnections (CLE-35076): the default client is built
// once per Client, so a desk sidecar's REST calls ride one kept-alive
// connection instead of dialling (TCP + TLS on the hub) for every call.
func TestDefaultHTTPReusesConnections(t *testing.T) {
	var conns atomic.Int32
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		io.WriteString(w, `{"pins":[]}`) //nolint:errcheck
	}))
	srv.Config.ConnState = func(_ net.Conn, st http.ConnState) {
		if st == http.StateNew {
			conns.Add(1)
		}
	}
	srv.Start()
	defer srv.Close()

	c := New(nil)
	if first, second := c.http(), c.http(); first != second {
		t.Fatal("http() built a new client on the second call")
	}
	const calls = 5
	for i := 0; i < calls; i++ {
		resp, err := c.HTTPClient().Get(srv.URL + "/v1/pins")
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body) //nolint:errcheck
		resp.Body.Close()
	}
	if n := conns.Load(); n != 1 {
		t.Fatalf("%d REST calls opened %d connections, want 1", calls, n)
	}

	// a caller-supplied client is used as it is
	own := &http.Client{}
	if (&Client{HTTP: own}).http() != own {
		t.Fatal("Client.HTTP was not used")
	}
}
