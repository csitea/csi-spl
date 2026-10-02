package hub

import (
	"crypto/sha256"
	"encoding/base64"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// A change-stamp validator BEFORE the view's DB reads (DB payload round 2,
// R2-5). etag.go hashes the finished body, so a 304 saved the wire but every
// read of the view still ran. The tenant's change stamp (rdb 0103: triggers
// on every table these views read, bumped in the writing transaction) lets
// an unchanged repeat read answer 304 after ONE small read.
//
// The tag is W/"s<mint ms>.<hash>": hash covers the request key (stampKey:
// tenant, reader, path, query, locale, hub build and view cnf) and the stamp.
// A conditional read answers 304 only when
//   - the hash of the key and the CURRENT stamp equals the tag's, and
//   - no message of the tenant left the live window since the mint (expiry
//     changes a view with no write).
// A tag is minted only when the stamp is settled (store.ChangeStampSettle
// after the last change), so a body read through another instance's door
// cache before it saw the change is never pinned. The stamp is read BEFORE
// the data, so a write landing in between makes the tag older than the body,
// never newer: the next read just reads again.
//
// Only a request that already carries If-None-Match (a browser repeat read)
// reads the stamp, so a first read costs what it did. A store without a
// stamp (memory) and since= delta reads (R2-2, whose body carries the hub
// clock) keep the body hash. Anything that fails falls back to it too.

const stampTagPrefix = `W/"s`

// stampGate answers a matching conditional read with 304 (true), or returns
// the writer the handler should use: one that tags a 200 with a fresh stamp
// validator when one may be minted.
func (s *Server) stampGate(w http.ResponseWriter, r *http.Request, tenant, hum string) (http.ResponseWriter, bool) {
	cs, ok := s.o.Store.(store.ChangeStamper)
	inm := r.Header.Get("If-None-Match")
	if !ok || inm == "" || r.URL.Query().Has("since") {
		return w, false
	}
	now := s.o.Now()
	mint, sum, held := parseStampTag(inm)
	since := now
	if held {
		since = mint
	}
	c, err := cs.ChangeStamp(r.Context(), tenant, since, now)
	if err != nil {
		return w, false
	}
	key := s.stampKey(r, tenant, hum)
	if held && !c.Expired && stampHash(key, c.Stamp) == sum {
		h := w.Header()
		h.Set("ETag", strings.TrimSpace(inm))
		h.Set("Cache-Control", "private, no-cache")
		w.WriteHeader(http.StatusNotModified)
		return w, true
	}
	if !c.Settled {
		return w, false
	}
	return &stampWriter{ResponseWriter: w, tag: stampTag(now, stampHash(key, c.Stamp))}, false
}

// stampKey is everything besides the stamp that decides a covered view's
// body: who reads what, and the hub build and cnf that render it.
func (s *Server) stampKey(r *http.Request, tenant, hum string) string {
	return strings.Join([]string{tenant, hum, r.URL.Path, r.URL.RawQuery,
		r.Header.Get("X-Locale"), r.Header.Get("Accept-Language"),
		s.o.Version, s.o.Commit, s.o.LobbyTaskID, s.o.ViewDoor,
		s.o.RetentionChannels.String(), s.o.RetentionAlerts.String(), strconv.Itoa(s.writeVersion())}, "\x00")
}

func stampHash(key string, stamp int64) string {
	sum := sha256.Sum256([]byte(key + "\x00" + strconv.FormatInt(stamp, 10)))
	return base64.RawURLEncoding.EncodeToString(sum[:16])
}

func stampTag(mint time.Time, hash string) string {
	return stampTagPrefix + strconv.FormatInt(mint.UnixMilli(), 10) + "." + hash + `"`
}

// parseStampTag reads the one stamp tag of an If-None-Match (a browser sends
// back the one ETag it holds); false for a body-hash tag, a list or junk.
func parseStampTag(inm string) (mint time.Time, hash string, ok bool) {
	rest, ok := strings.CutPrefix(strings.TrimSpace(inm), stampTagPrefix)
	if !ok || !strings.HasSuffix(rest, `"`) {
		return time.Time{}, "", false
	}
	ms, hash, ok := strings.Cut(strings.TrimSuffix(rest, `"`), ".")
	n, err := strconv.ParseInt(ms, 10, 64)
	if !ok || err != nil || n <= 0 || hash == "" {
		return time.Time{}, "", false
	}
	return time.UnixMilli(n), hash, true
}

// stampWriter tags the handler's 200 JSON with the stamp validator, under
// the same rule as etagWriter (no Cache-Control or ETag of its own). Any
// other answer goes out untouched; etagViews then leaves a tagged one alone.
type stampWriter struct {
	http.ResponseWriter
	tag     string
	decided bool
}

func (sw *stampWriter) WriteHeader(code int) {
	if !sw.decided {
		sw.decided = true
		h := sw.Header()
		mt, _, _ := mime.ParseMediaType(h.Get("Content-Type"))
		if code == http.StatusOK && mt == "application/json" && h.Get("Cache-Control") == "" && h.Get("ETag") == "" {
			h.Set("ETag", sw.tag)
			h.Set("Cache-Control", "private, no-cache")
		}
	}
	sw.ResponseWriter.WriteHeader(code)
}

func (sw *stampWriter) Write(p []byte) (int, error) {
	if !sw.decided {
		sw.WriteHeader(http.StatusOK)
	}
	return sw.ResponseWriter.Write(p)
}

func (sw *stampWriter) Unwrap() http.ResponseWriter { return sw.ResponseWriter }
