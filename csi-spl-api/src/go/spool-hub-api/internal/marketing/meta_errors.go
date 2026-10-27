package marketing

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"
)

// meta_errors.go maps a Graph API error answer to a kind the dispatcher acts
// on (spec 090 T032, SPL-3875; spec.md §21.2): an expired or revoked token
// (OAuthException 190) expires the channel, a rate limit reschedules, a media
// error fails the post at once, a transient error is retried.

// MetaErrorKind is what a Meta failure means for the post.
type MetaErrorKind int

// The kinds. MetaErrOther is any other terminal failure.
const (
	MetaErrOther      MetaErrorKind = iota
	MetaErrTransient                // retry later: Meta is down or busy
	MetaErrRateLimit                // a call or publish quota is used up; RetryAfter says when
	MetaErrAuth                     // the token expired, was revoked or is invalid: re-connect
	MetaErrPermission               // the app lacks a permission or the member is no Page admin
	MetaErrMedia                    // the media or caption is refused: terminal for the post
	MetaErrNotReady                 // the Instagram container is not finished yet
)

var metaErrorKindNames = [...]string{"other", "transient", "rate_limit", "auth", "permission", "media", "not_ready"}

// String is the kind's name, as the dispatcher logs it.
func (k MetaErrorKind) String() string {
	if int(k) < len(metaErrorKindNames) {
		return metaErrorKindNames[k]
	}
	return "kind(" + strconv.Itoa(int(k)) + ")"
}

// MetaError is a Graph API error (or a local check that refused the request
// before sending it, Status 0). It holds Meta's own fields, never a request
// header or URL, so never a token.
type MetaError struct {
	Status     int
	Code       int
	Subcode    int
	Type       string
	Message    string
	TraceID    string
	Kind       MetaErrorKind
	RetryAfter time.Duration // rate limits only, 0 when Meta did not say
}

// Error implements error.
func (e *MetaError) Error() string {
	return fmt.Sprintf("meta HTTP %d %s code %d subcode %d (%s): %s", e.Status, e.Type, e.Code, e.Subcode, e.Kind, e.Message)
}

// MetaKind is err's kind; any error that is no *MetaError is MetaErrTransient
// when the connection failed before sending, else MetaErrOther.
func MetaKind(err error) MetaErrorKind {
	var me *MetaError
	if errors.As(err, &me) {
		return me.Kind
	}
	if sentNothing(err) {
		return MetaErrTransient
	}
	return MetaErrOther
}

// MetaTokenInvalid reports an expired, revoked or invalid token
// (OAuthException 190 and its subcodes): the channel goes expired.
func MetaTokenInvalid(err error) bool { return MetaKind(err) == MetaErrAuth }

// MetaRetryable reports a failure the dispatcher may try again later:
// transient, rate-limited or a container still in progress.
func MetaRetryable(err error) bool {
	switch MetaKind(err) {
	case MetaErrTransient, MetaErrRateLimit, MetaErrNotReady:
		return true
	default:
		return false
	}
}

// parseMetaError reads Meta's {"error":{...}} body and the usage headers.
func parseMetaError(status int, h http.Header, body []byte) *MetaError {
	var e struct {
		Error struct {
			Message     string `json:"message"`
			Type        string `json:"type"`
			Code        int    `json:"code"`
			Subcode     int    `json:"error_subcode"`
			IsTransient bool   `json:"is_transient"`
			UserMsg     string `json:"error_user_msg"`
			FBTraceID   string `json:"fbtrace_id"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &e)
	msg := e.Error.Message
	if e.Error.UserMsg != "" {
		msg += " | " + e.Error.UserMsg
	}
	if len(msg) > 300 {
		msg = msg[:300]
	}
	me := &MetaError{Status: status, Code: e.Error.Code, Subcode: e.Error.Subcode, Type: e.Error.Type, Message: msg, TraceID: e.Error.FBTraceID}
	me.Kind = classifyMeta(status, me.Code, me.Subcode, e.Error.IsTransient)
	if me.Kind == MetaErrRateLimit {
		me.RetryAfter = metaRetryAfter(h)
	}
	return me
}

// The Instagram subcodes (2207xxx) that are not media errors.
const (
	igSubServerError   = 2207001
	igSubTempError     = 2207008
	igSubNotReady      = 2207027
	igSubPublishLimit  = 2207042
	igSubcodeRangeLow  = 2207000
	igSubcodeRangeHigh = 2207999
)

// metaAuthSubcodes are OAuthException 190's subcodes for a dead token:
// 458 app removed, 459 checkpoint, 460 password changed, 463 expired,
// 464 unconfirmed user, 467 invalid.
var metaAuthSubcodes = map[int]bool{458: true, 459: true, 460: true, 463: true, 464: true, 467: true}

// metaRateCodes are the throttling codes: 4 app, 17 user, 32 Page, 613 call
// rate; 80001..80014 are the Business Use Case limits (Pages, Instagram, ...).
func metaRateCode(code int) bool {
	return code == 4 || code == 17 || code == 32 || code == 613 || (code >= 80001 && code <= 80014)
}

// metaMediaCode: 36000..36003 image size, format or aspect ratio; 9004 the
// media URL could not be fetched; 352 unsupported video format.
func metaMediaCode(code int) bool {
	return (code >= 36000 && code <= 36003) || code == 9004 || code == 352
}

func classifyMeta(status, code, sub int, transient bool) MetaErrorKind {
	switch {
	case code == 190 || code == 102 || metaAuthSubcodes[sub] || status == http.StatusUnauthorized:
		return MetaErrAuth
	case metaRateCode(code) || sub == igSubPublishLimit || status == http.StatusTooManyRequests:
		return MetaErrRateLimit
	case code == 9007 || sub == igSubNotReady:
		return MetaErrNotReady
	case sub == igSubServerError || sub == igSubTempError:
		return MetaErrTransient
	case metaMediaCode(code) || (sub >= igSubcodeRangeLow && sub <= igSubcodeRangeHigh):
		return MetaErrMedia
	case code == 10 || (code >= 200 && code <= 299):
		return MetaErrPermission
	case transient || code == 1 || code == 2 || status >= 500:
		return MetaErrTransient
	default:
		return MetaErrOther
	}
}

// metaRetryAfter reads Retry-After (seconds) or the longest
// estimated_time_to_regain_access (minutes) in X-Business-Use-Case-Usage.
func metaRetryAfter(h http.Header) time.Duration {
	if s, err := strconv.Atoi(h.Get("Retry-After")); err == nil && s > 0 {
		return time.Duration(s) * time.Second
	}
	var usage map[string][]struct {
		Regain int `json:"estimated_time_to_regain_access"`
	}
	if json.Unmarshal([]byte(h.Get("X-Business-Use-Case-Usage")), &usage) != nil {
		return 0
	}
	most := 0
	for _, rows := range usage {
		for _, r := range rows {
			most = max(most, r.Regain)
		}
	}
	return time.Duration(most) * time.Minute
}

// metaMediaError is a request refused locally, before it is sent.
func metaMediaError(format string, a ...any) *MetaError {
	return &MetaError{Kind: MetaErrMedia, Type: "LocalValidation", Message: fmt.Sprintf(format, a...)}
}
