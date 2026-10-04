package blob

import (
	"context"
	"encoding/xml"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
)

func TestS3(t *testing.T) {
	s := openTestS3(t)
	testStore(t, s)
	testUploaded(t, openTestS3(t))
}

func TestS3PutKeepsExistingBytes(t *testing.T) {
	s := openTestS3(t)
	ctx := context.Background()
	key := "t/a/files/" + strings.Repeat("ab", 32)
	if err := s.Put(ctx, key, []byte("one")); err != nil {
		t.Fatal(err)
	}
	if err := s.Put(ctx, key, []byte("two-different")); err != nil {
		t.Fatal(err)
	}
	r, err := s.Get(ctx, key)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(r)
	r.Close()
	if string(b) != "one" {
		t.Fatalf("second Put overwrote %q", b)
	}
}

func TestS3ListPages(t *testing.T) {
	s := openTestS3(t)
	s.listMax = 1
	ctx := context.Background()
	var want int64
	for _, k := range []string{"p/a", "p/b", "p/c"} {
		body := []byte(k)
		want += int64(len(body))
		if err := s.Put(ctx, k, body); err != nil {
			t.Fatal(err)
		}
	}
	if n, err := s.PrefixBytes(ctx, "p/missing/"); err != nil || n != 0 {
		t.Fatalf("empty prefix: %d %v", n, err)
	}
	n, err := s.PrefixBytes(ctx, "p/")
	if err != nil || n != want {
		t.Fatalf("PrefixBytes across pages: %d %v, want %d", n, err, want)
	}
	var seen []string
	if err := s.List(ctx, "p/", func(k string, up time.Time) error {
		if up.IsZero() {
			t.Errorf("List time zero for %s", k)
		}
		seen = append(seen, k)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	sort.Strings(seen)
	if strings.Join(seen, ",") != "p/a,p/b,p/c" {
		t.Fatalf("List = %v", seen)
	}
}

func TestS3Addressing(t *testing.T) {
	regional := clientOptions("eu-north-1", "", nil)
	if regional.UsePathStyle || regional.BaseEndpoint != nil {
		t.Fatalf("regional: path-style=%v endpoint=%v", regional.UsePathStyle, regional.BaseEndpoint)
	}
	if regional.RequestChecksumCalculation != aws.RequestChecksumCalculationWhenRequired {
		t.Fatal("regional checksums are not limited to required")
	}
	custom := clientOptions("eu-north-1", "http://127.0.0.1:9", nil)
	if !custom.UsePathStyle || custom.BaseEndpoint == nil || *custom.BaseEndpoint != "http://127.0.0.1:9" {
		t.Fatalf("custom endpoint: path-style=%v endpoint=%v", custom.UsePathStyle, custom.BaseEndpoint)
	}
	if custom.ResponseChecksumValidation != aws.ResponseChecksumValidationWhenRequired {
		t.Fatal("custom endpoint still validates optional response checksums")
	}
	if len(regional.APIOptions) != 0 || len(custom.APIOptions) != 1 {
		t.Fatalf("unsigned payload: regional %d, http custom %d", len(regional.APIOptions), len(custom.APIOptions))
	}
	tls := clientOptions("eu-north-1", "https://127.0.0.1:9", nil)
	if !tls.UsePathStyle || len(tls.APIOptions) != 0 {
		t.Fatal("https custom endpoint should keep payload signing")
	}
}

func TestS3OpenRejects(t *testing.T) {
	ctx := context.Background()
	if _, err := OpenS3(ctx, S3Options{Region: "eu-north-1"}); err == nil {
		t.Fatal("empty bucket accepted")
	}
	if _, err := OpenS3(ctx, S3Options{Bucket: "a/b", Region: "eu-north-1"}); err == nil {
		t.Fatal("bucket with a slash accepted")
	}
	if _, err := OpenS3(ctx, S3Options{Bucket: "bkt"}); err == nil {
		t.Fatal("missing region accepted")
	}
	for _, ep := range []string{"127.0.0.1:9", "ftp://127.0.0.1:9", "http://name:value@127.0.0.1:9", "http://127.0.0.1:9/s3"} {
		if _, err := OpenS3(ctx, S3Options{Bucket: "bkt", Region: "eu-north-1", Endpoint: ep}); err == nil {
			t.Fatalf("endpoint %q accepted", ep)
		}
	}
}

func TestS3RegionAndCreds(t *testing.T) {
	got, err := resolveRegion("", func(k string) string {
		if k == EnvS3Region {
			return "eu-north-1"
		}
		return ""
	})
	if err != nil || got != "eu-north-1" {
		t.Fatalf("region from %s: %q %v", EnvS3Region, got, err)
	}
	got, err = resolveRegion("explicit", func(string) string { return "other" })
	if err != nil || got != "explicit" {
		t.Fatalf("explicit region: %q %v", got, err)
	}
	if _, err := resolveRegion("", func(string) string { return "" }); err == nil {
		t.Fatal("no region accepted")
	}
	p, ok := staticCreds(func(k string) string {
		switch k {
		case EnvS3AccessKey:
			return "AK"
		case EnvS3SecretKey:
			return "SK"
		case EnvS3SessionToken:
			return "TK"
		}
		return ""
	})
	if !ok {
		t.Fatal("pair not used")
	}
	c, err := p.Retrieve(context.Background())
	if err != nil || c.AccessKeyID != "AK" || c.SecretAccessKey != "SK" || c.SessionToken != "TK" {
		t.Fatalf("static creds: %+v %v", c, err)
	}
	if _, ok := staticCreds(func(k string) string {
		if k == EnvS3AccessKey {
			return "AK"
		}
		return ""
	}); ok {
		t.Fatal("partial pair used as static credentials")
	}
}

func TestS3IgnoresEndpointEnv(t *testing.T) {
	t.Setenv(EnvS3Endpoint, "http://127.0.0.1:1")
	t.Setenv(EnvS3AccessKey, "test-access-key")
	t.Setenv(EnvS3SecretKey, "test-secret-key")
	s, err := OpenS3(context.Background(), S3Options{Bucket: "bkt", Region: "eu-north-1"})
	if err != nil {
		t.Fatal(err)
	}
	if s.endpoint != "" {
		t.Fatalf("empty Endpoint read %s as %q", EnvS3Endpoint, s.endpoint)
	}
}

func TestS3DefaultChainConstructs(t *testing.T) {
	t.Setenv(EnvS3AccessKey, "")
	t.Setenv(EnvS3SecretKey, "")
	t.Setenv("AWS_EC2_METADATA_DISABLED", "true")
	s, err := OpenS3(context.Background(), S3Options{Bucket: "bkt", Region: "eu-north-1"})
	if err != nil || s == nil || s.endpoint != "" {
		t.Fatalf("default chain: %+v %v", s, err)
	}
}

func openTestS3(t *testing.T) *S3 {
	t.Helper()
	srv := httptest.NewServer(newFakeS3("bkt"))
	t.Cleanup(srv.Close)
	t.Setenv(EnvS3AccessKey, "test-access-key")
	t.Setenv(EnvS3SecretKey, "test-secret-key")
	t.Setenv(EnvS3SessionToken, "")
	s, err := OpenS3(context.Background(), S3Options{
		Bucket:   "bkt",
		Region:   "eu-north-1",
		Endpoint: srv.URL,
	})
	if err != nil {
		t.Fatalf("OpenS3: %v", err)
	}
	if s.endpoint != srv.URL {
		t.Fatalf("endpoint = %q, server %q", s.endpoint, srv.URL)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

// fakeS3 is an in-process S3 REST stand-in. It does not check signatures.
type fakeS3 struct {
	mu     sync.Mutex
	bucket string
	objs   map[string]*fakeObj
}

type fakeObj struct {
	body        []byte
	meta        map[string]string
	contentType string
	mod         time.Time
}

func newFakeS3(bucket string) *fakeS3 {
	return &fakeS3{bucket: bucket, objs: map[string]*fakeObj{}}
}

func (f *fakeS3) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	bucket, key := splitPath(r.URL.Path)
	if bucket != f.bucket {
		writeErr(w, http.StatusNotFound, "NoSuchBucket", "no such bucket")
		return
	}
	switch r.Method {
	case http.MethodGet:
		if key == "" || r.URL.Query().Get("list-type") == "2" {
			f.list(w, r)
			return
		}
		f.get(w, key, true)
	case http.MethodHead:
		f.get(w, key, false)
	case http.MethodPut:
		if src := r.Header.Get("X-Amz-Copy-Source"); src != "" {
			f.copy(w, r, key, src)
			return
		}
		f.put(w, r, key)
	case http.MethodDelete:
		f.mu.Lock()
		delete(f.objs, key)
		f.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	default:
		writeErr(w, http.StatusMethodNotAllowed, "MethodNotAllowed", "method")
	}
}

func (f *fakeS3) put(w http.ResponseWriter, r *http.Request, key string) {
	if key == "" {
		writeErr(w, http.StatusBadRequest, "InvalidArgument", "key")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 64<<20+1))
	if err != nil || len(body) > 64<<20 {
		// A failed stream commits nothing.
		writeErr(w, http.StatusInternalServerError, "InternalError", "read")
		return
	}
	f.mu.Lock()
	f.objs[key] = &fakeObj{
		body:        body,
		meta:        metaFrom(r),
		contentType: contentType(r),
		mod:         time.Now().UTC(),
	}
	f.mu.Unlock()
	w.Header().Set("ETag", `"etag"`)
	w.WriteHeader(http.StatusOK)
}

func (f *fakeS3) get(w http.ResponseWriter, key string, withBody bool) {
	o, ok := f.snapshot(key)
	if !ok {
		if withBody {
			writeErr(w, http.StatusNotFound, "NoSuchKey", "not found")
			return
		}
		w.WriteHeader(http.StatusNotFound)
		return
	}
	writeObjHeaders(w, &o)
	if withBody {
		_, _ = w.Write(o.body)
	}
}

func (f *fakeS3) copy(w http.ResponseWriter, r *http.Request, key, src string) {
	srcBucket, srcKey := splitCopySource(src)
	if srcBucket != f.bucket {
		writeErr(w, http.StatusNotFound, "NoSuchBucket", "no such bucket")
		return
	}
	o, ok := f.snapshot(srcKey)
	if !ok {
		writeErr(w, http.StatusNotFound, "NoSuchKey", "not found")
		return
	}
	if strings.EqualFold(r.Header.Get("X-Amz-Metadata-Directive"), "REPLACE") {
		o.meta = metaFrom(r)
		o.contentType = contentType(r)
	}
	o.mod = time.Now().UTC()
	stored := o
	f.mu.Lock()
	f.objs[key] = &stored
	f.mu.Unlock()
	w.Header().Set("Content-Type", "application/xml")
	_ = xml.NewEncoder(w).Encode(copyResultXML{
		LastModified: o.mod.Format(time.RFC3339),
		ETag:         `"etag"`,
	})
}

func (f *fakeS3) list(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	prefix := q.Get("prefix")
	token := q.Get("continuation-token")
	maxKeys := 1000
	if v := q.Get("max-keys"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			maxKeys = n
		}
	}
	f.mu.Lock()
	keys := make([]string, 0, len(f.objs))
	for k := range f.objs {
		if strings.HasPrefix(k, prefix) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	start := 0
	if token != "" {
		start = len(keys)
		for i, k := range keys {
			if k == token {
				start = i + 1
				break
			}
		}
	}
	end := start + maxKeys
	trunc := false
	next := ""
	if end < len(keys) {
		trunc = true
		next = keys[end-1]
	} else {
		end = len(keys)
	}
	page := make([]listObjXML, 0, end-start)
	for _, k := range keys[start:end] {
		o := f.objs[k]
		page = append(page, listObjXML{
			Key:          k,
			LastModified: o.mod.Format(time.RFC3339),
			ETag:         `"etag"`,
			Size:         int64(len(o.body)),
			StorageClass: "STANDARD",
		})
	}
	f.mu.Unlock()
	w.Header().Set("Content-Type", "application/xml")
	_ = xml.NewEncoder(w).Encode(listResultXML{
		Name:                  f.bucket,
		Prefix:                prefix,
		KeyCount:              len(page),
		MaxKeys:               maxKeys,
		IsTruncated:           trunc,
		Contents:              page,
		NextContinuationToken: next,
	})
}

func (f *fakeS3) snapshot(key string) (fakeObj, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	o, ok := f.objs[key]
	if !ok {
		return fakeObj{}, false
	}
	cp := *o
	cp.body = append([]byte(nil), o.body...)
	cp.meta = copyMeta(o.meta)
	return cp, true
}

func copyMeta(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

func metaFrom(r *http.Request) map[string]string {
	const p = "X-Amz-Meta-"
	var out map[string]string
	for k, vs := range r.Header {
		if len(k) <= len(p) || !strings.EqualFold(k[:len(p)], p) || len(vs) == 0 {
			continue
		}
		if out == nil {
			out = map[string]string{}
		}
		out[strings.ToLower(k[len(p):])] = vs[0]
	}
	return out
}

func contentType(r *http.Request) string {
	if ct := r.Header.Get("Content-Type"); ct != "" {
		return ct
	}
	return "application/octet-stream"
}

func writeObjHeaders(w http.ResponseWriter, o *fakeObj) {
	w.Header().Set("Content-Type", o.contentType)
	w.Header().Set("Content-Length", strconv.Itoa(len(o.body)))
	w.Header().Set("Last-Modified", o.mod.UTC().Format(http.TimeFormat))
	w.Header().Set("ETag", `"etag"`)
	for k, v := range o.meta {
		w.Header().Set("X-Amz-Meta-"+k, v)
	}
}

func writeErr(w http.ResponseWriter, code int, api, msg string) {
	w.Header().Set("Content-Type", "application/xml")
	w.WriteHeader(code)
	_ = xml.NewEncoder(w).Encode(errXML{Code: api, Message: msg})
}

func splitPath(p string) (string, string) {
	p = strings.TrimPrefix(p, "/")
	bucket, key, _ := strings.Cut(p, "/")
	return unescape(bucket), unescapeKey(key)
}

func splitCopySource(src string) (string, string) {
	src = strings.TrimPrefix(src, "/")
	bucket, key, _ := strings.Cut(src, "/")
	return unescape(bucket), unescapeKey(key)
}

func unescapeKey(key string) string {
	parts := strings.Split(key, "/")
	for i, p := range parts {
		parts[i] = unescape(p)
	}
	return strings.Join(parts, "/")
}

func unescape(s string) string {
	u, err := url.PathUnescape(s)
	if err != nil {
		return s
	}
	return u
}

type listResultXML struct {
	XMLName               xml.Name     `xml:"ListBucketResult"`
	Name                  string       `xml:"Name"`
	Prefix                string       `xml:"Prefix"`
	KeyCount              int          `xml:"KeyCount"`
	MaxKeys               int          `xml:"MaxKeys"`
	IsTruncated           bool         `xml:"IsTruncated"`
	Contents              []listObjXML `xml:"Contents"`
	NextContinuationToken string       `xml:"NextContinuationToken,omitempty"`
}

type listObjXML struct {
	Key          string `xml:"Key"`
	LastModified string `xml:"LastModified"`
	ETag         string `xml:"ETag"`
	Size         int64  `xml:"Size"`
	StorageClass string `xml:"StorageClass"`
}

type copyResultXML struct {
	XMLName      xml.Name `xml:"CopyObjectResult"`
	LastModified string   `xml:"LastModified"`
	ETag         string   `xml:"ETag"`
}

type errXML struct {
	XMLName xml.Name `xml:"Error"`
	Code    string   `xml:"Code"`
	Message string   `xml:"Message"`
}
