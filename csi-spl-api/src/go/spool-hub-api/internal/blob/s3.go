package blob

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	v4 "github.com/aws/aws-sdk-go-v2/aws/signer/v4"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"
	smithyhttp "github.com/aws/smithy-go/transport/http"
)

// Env names for the S3 driver (spec 076 T004). T003 wires them.
//
// EnvS3Endpoint is not read here. An empty S3Options.Endpoint is standard
// regional addressing, so a process that also has the variable set can still
// open a regional bucket. T003 copies the variable into S3Options.Endpoint.
const (
	EnvS3AccessKey    = "SPOOL_S3_ACCESS_KEY"
	EnvS3SecretKey    = "SPOOL_S3_SECRET_KEY"
	EnvS3SessionToken = "SPOOL_S3_SESSION_TOKEN"
	EnvS3Region       = "SPOOL_S3_REGION"
	EnvS3Endpoint     = "SPOOL_S3_ENDPOINT"
)

// S3Options selects the bucket and how it is addressed.
//
// Endpoint empty is standard regional addressing (virtual-hosted). Endpoint
// set is that base URL with path-style addressing, which a Compose S3 needs.
// Region empty reads EnvS3Region, then AWS_REGION, then AWS_DEFAULT_REGION.
//
// Credentials are not an option. EnvS3AccessKey and EnvS3SecretKey, when both
// are set, win, with EnvS3SessionToken if that is set too. Otherwise the AWS
// SDK default chain is used. No key, host or bucket is compiled in.
type S3Options struct {
	Bucket   string
	Region   string
	Endpoint string
}

// S3 is a blob.Store on one S3-compatible bucket.
type S3 struct {
	client   *s3.Client
	bucket   string
	endpoint string // empty: regional. Set: path-style at this base URL.
	listMax  int32  // tests page the lister; 0 keeps the service default
}

// OpenS3 opens bucket. See S3Options for addressing and credentials.
func OpenS3(ctx context.Context, opt S3Options) (*S3, error) {
	bucket := strings.TrimSpace(opt.Bucket)
	if bucket == "" || strings.Contains(bucket, "/") {
		return nil, errors.New("open s3: bucket is required")
	}
	region, err := resolveRegion(opt.Region, os.Getenv)
	if err != nil {
		return nil, err
	}
	endpoint, err := resolveEndpoint(opt.Endpoint)
	if err != nil {
		return nil, err
	}
	client, err := newS3Client(ctx, region, endpoint, os.Getenv)
	if err != nil {
		return nil, err
	}
	return &S3{client: client, bucket: bucket, endpoint: endpoint}, nil
}

func resolveRegion(explicit string, getenv func(string) string) (string, error) {
	if v := strings.TrimSpace(explicit); v != "" {
		return v, nil
	}
	for _, k := range []string{EnvS3Region, "AWS_REGION", "AWS_DEFAULT_REGION"} {
		if v := strings.TrimSpace(getenv(k)); v != "" {
			return v, nil
		}
	}
	return "", errors.New("open s3: region is required (" + EnvS3Region + ", AWS_REGION, or AWS_DEFAULT_REGION)")
}

// resolveEndpoint accepts an empty string (regional) or an absolute http(s)
// URL with no userinfo, path or query. Credentials do not belong in the URL.
func resolveEndpoint(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") ||
		u.User != nil || u.RawQuery != "" || (u.Path != "" && u.Path != "/") {
		return "", errors.New("open s3: endpoint needs an http or https URL with no path or credentials")
	}
	return strings.TrimRight(raw, "/"), nil
}

// staticCreds is the compose secret pair. A partial pair is not used: one
// side empty would sign with a blank secret instead of the default chain.
func staticCreds(getenv func(string) string) (aws.CredentialsProvider, bool) {
	id, secret := getenv(EnvS3AccessKey), getenv(EnvS3SecretKey)
	if id == "" || secret == "" {
		return nil, false
	}
	return credentials.NewStaticCredentialsProvider(id, secret, getenv(EnvS3SessionToken)), true
}

func newS3Client(ctx context.Context, region, endpoint string, getenv func(string) string) (*s3.Client, error) {
	if creds, ok := staticCreds(getenv); ok {
		return s3.New(clientOptions(region, endpoint, creds)), nil
	}
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	if err != nil {
		return nil, fmt.Errorf("open s3: %w", err)
	}
	return s3.NewFromConfig(cfg, func(o *s3.Options) { applyEndpoint(o, endpoint) }), nil
}

func clientOptions(region, endpoint string, creds aws.CredentialsProvider) s3.Options {
	o := s3.Options{Region: region, Credentials: creds}
	applyEndpoint(&o, endpoint)
	return o
}

// applyEndpoint forces path-style only for a custom endpoint. Checksums are
// calculated only when the operation requires one: the default (always) sends
// aws-chunked trailing checksums that a minimal S3 service rejects, and a
// non-seekable upload body would be framed that way.
//
// Plain http cannot hash a stream and then rewind it, so a custom http
// endpoint signs the payload as unsigned. https (regional AWS, or a custom
// TLS endpoint) keeps the default, which already uses an unsigned payload
// for a non-seekable body.
func applyEndpoint(o *s3.Options, endpoint string) {
	o.RequestChecksumCalculation = aws.RequestChecksumCalculationWhenRequired
	o.ResponseChecksumValidation = aws.ResponseChecksumValidationWhenRequired
	if endpoint != "" {
		o.BaseEndpoint = aws.String(endpoint)
		o.UsePathStyle = true
		if strings.HasPrefix(endpoint, "http://") {
			o.APIOptions = append(o.APIOptions, v4.SwapComputePayloadSHA256ForUnsignedPayloadMiddleware)
		}
		return
	}
	o.BaseEndpoint = nil
	o.UsePathStyle = false
}

var _ Store = (*S3)(nil)

func (s *S3) Put(ctx context.Context, key string, data []byte) error {
	// Content-addressed: the object already holds these bytes.
	ok, err := s.Exists(ctx, key)
	if err != nil || ok {
		return err
	}
	_, err = s.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:        aws.String(s.bucket),
		Key:           aws.String(key),
		Body:          bytes.NewReader(data),
		ContentLength: aws.Int64(int64(len(data))),
		ContentType:   aws.String("application/octet-stream"),
	})
	return err
}

func (s *S3) PutReader(ctx context.Context, key string, r io.Reader) (int64, error) {
	cr := &countingReader{r: r}
	_, err := s.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(s.bucket),
		Key:         aws.String(key),
		Body:        cr,
		ContentType: aws.String("application/octet-stream"),
	})
	if err != nil {
		// A failed stream must leave nothing at key. One delete covers a
		// server that committed the bytes the client then abandoned.
		if derr := s.remove(context.WithoutCancel(ctx), key); derr != nil {
			return cr.n, errors.Join(err, derr)
		}
		return cr.n, err
	}
	return cr.n, nil
}

type countingReader struct {
	r io.Reader
	n int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += int64(n)
	return n, err
}

func (s *S3) Promote(ctx context.Context, src, dst string) (bool, error) {
	existed, err := s.Exists(ctx, dst)
	if err != nil {
		return false, err
	}
	if !existed {
		_, err = s.client.CopyObject(ctx, &s3.CopyObjectInput{
			Bucket:            aws.String(s.bucket),
			Key:               aws.String(dst),
			CopySource:        aws.String(copySource(s.bucket, src)),
			MetadataDirective: types.MetadataDirectiveCopy,
		})
		if err != nil {
			return false, err
		}
	}
	if err := s.dropSrc(ctx, src); err != nil {
		return existed, err
	}
	return existed, nil
}

// copySource is bucket/key, URL-encoded. The SDK writes the header as given.
func copySource(bucket, key string) string {
	return url.PathEscape(bucket) + "/" + escapeKey(key)
}

func escapeKey(key string) string {
	parts := strings.Split(key, "/")
	for i, p := range parts {
		parts[i] = url.PathEscape(p)
	}
	return strings.Join(parts, "/")
}

func (s *S3) dropSrc(ctx context.Context, src string) error {
	err := s.Delete(ctx, src)
	if errors.Is(err, ErrNotFound) {
		return nil
	}
	return err
}

func (s *S3) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	out, err := s.client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	})
	if isNotFound(err) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return out.Body, nil
}

func (s *S3) Exists(ctx context.Context, key string) (bool, error) {
	_, err := s.head(ctx, key)
	if errors.Is(err, ErrNotFound) {
		return false, nil
	}
	return err == nil, err
}

func (s *S3) Delete(ctx context.Context, key string) error {
	// DeleteObject on a missing key is success. The contract wants ErrNotFound.
	ok, err := s.Exists(ctx, key)
	if err != nil {
		return err
	}
	if !ok {
		return ErrNotFound
	}
	return s.remove(ctx, key)
}

func (s *S3) remove(ctx context.Context, key string) error {
	_, err := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	})
	if err == nil || isNotFound(err) {
		return nil
	}
	return err
}

func (s *S3) PrefixBytes(ctx context.Context, prefix string) (int64, error) {
	var n int64
	err := s.each(ctx, prefix, func(o types.Object) error {
		if o.Size != nil {
			n += *o.Size
		}
		return nil
	})
	return n, err
}

func (s *S3) Uploaded(ctx context.Context, key string) (time.Time, error) {
	h, err := s.head(ctx, key)
	if err != nil {
		return time.Time{}, err
	}
	var last time.Time
	if h.LastModified != nil {
		last = *h.LastModified
	}
	return s3Uploaded(last, h.Metadata), nil
}

// Touch rewrites user metadata. S3 has no in-place metadata update, and
// Last-Modified is whole seconds, so a re-upload inside that second would
// not move Uploaded. The spool-uploaded value is nanoseconds.
func (s *S3) Touch(ctx context.Context, key string) error {
	h, err := s.head(ctx, key)
	if err != nil {
		return err
	}
	meta := make(map[string]string, len(h.Metadata)+1)
	for k, v := range h.Metadata {
		meta[k] = v
	}
	meta[uploadedMeta] = time.Now().UTC().Format(time.RFC3339Nano)
	ct := "application/octet-stream"
	if h.ContentType != nil && *h.ContentType != "" {
		ct = *h.ContentType
	}
	_, err = s.client.CopyObject(ctx, &s3.CopyObjectInput{
		Bucket:            aws.String(s.bucket),
		Key:               aws.String(key),
		CopySource:        aws.String(copySource(s.bucket, key)),
		Metadata:          meta,
		MetadataDirective: types.MetadataDirectiveReplace,
		ContentType:       aws.String(ct),
	})
	return err
}

func (s *S3) List(ctx context.Context, prefix string, fn func(string, time.Time) error) error {
	// ListObjectsV2 does not return user metadata, and Uploaded reads it, so
	// each key is headed. List's time and Uploaded's time are then the same.
	return s.each(ctx, prefix, func(o types.Object) error {
		if o.Key == nil {
			return nil
		}
		up, err := s.Uploaded(ctx, *o.Key)
		if err != nil {
			return err
		}
		return fn(*o.Key, up)
	})
}

func (s *S3) each(ctx context.Context, prefix string, fn func(types.Object) error) error {
	var token *string
	for {
		in := &s3.ListObjectsV2Input{
			Bucket:            aws.String(s.bucket),
			Prefix:            aws.String(prefix),
			ContinuationToken: token,
		}
		if s.listMax > 0 {
			in.MaxKeys = aws.Int32(s.listMax)
		}
		out, err := s.client.ListObjectsV2(ctx, in)
		if err != nil {
			return err
		}
		for i := range out.Contents {
			if err := fn(out.Contents[i]); err != nil {
				return err
			}
		}
		next := out.NextContinuationToken
		if out.IsTruncated == nil || !*out.IsTruncated || next == nil || *next == "" || aws.ToString(next) == aws.ToString(token) {
			return nil
		}
		token = next
	}
}

func (s *S3) Close() error { return nil }

func (s *S3) head(ctx context.Context, key string) (*s3.HeadObjectOutput, error) {
	out, err := s.client.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	})
	if isNotFound(err) {
		return nil, ErrNotFound
	}
	return out, err
}

func s3Uploaded(last time.Time, meta map[string]string) time.Time {
	v, ok := meta[uploadedMeta]
	if !ok {
		return last
	}
	t, err := time.Parse(time.RFC3339Nano, v)
	if err != nil || !t.After(last) {
		return last
	}
	return t
}

func isNotFound(err error) bool {
	if err == nil {
		return false
	}
	var ae smithy.APIError
	if errors.As(err, &ae) {
		switch ae.ErrorCode() {
		case "NotFound", "NoSuchKey", "404":
			return true
		}
	}
	var re *smithyhttp.ResponseError
	return errors.As(err, &re) && re.HTTPStatusCode() == 404
}
