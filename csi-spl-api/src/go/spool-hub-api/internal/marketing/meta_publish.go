package marketing

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"unicode/utf8"
)

// meta_publish.go posts on a Facebook Page and publishes on Instagram
// through the two-step container flow (spec 090 T032, SPL-3875; spec.md
// §16.1, §21.1): POST /{ig-user-id}/media makes a container, GET
// /{container}?fields=status_code says when it is FINISHED, POST
// /{ig-user-id}/media_publish makes it public.

// The caps of spec.md §21.1.
const (
	FacebookMessageMaxChars  = 63206
	InstagramCaptionMaxChars = 2200
	InstagramMaxHashtags     = 30
	InstagramCarouselMax     = 20
)

// FacebookPost is one Page post: a message with an optional link (Meta
// builds the preview card), or a photo by public URL with Message as caption.
type FacebookPost struct {
	Message  string
	Link     string
	PhotoURL string
}

// PublishFacebookPagePost posts on pageID as the Page and returns the post
// id. Never retried once sent (ErrMetaUnknownOutcome), so never posted twice.
func (m *Meta) PublishFacebookPagePost(ctx context.Context, pageAccessToken Plaintext, pageID string, post FacebookPost) (string, error) {
	if err := checkGraphID("page id", pageID); err != nil {
		return "", err
	}
	if utf8.RuneCountInString(post.Message) > FacebookMessageMaxChars {
		return "", metaMediaError("facebook message is over %d characters", FacebookMessageMaxChars)
	}
	c := metaCall{method: http.MethodPost, tok: pageAccessToken, form: url.Values{}}
	if post.PhotoURL != "" {
		if err := checkHTTPS("photo url", post.PhotoURL); err != nil {
			return "", err
		}
		c.path = "/" + pageID + "/photos"
		c.form.Set("url", post.PhotoURL)
		c.form.Set("published", "true")
		if post.Message != "" {
			c.form.Set("caption", post.Message)
		}
	} else {
		if post.Message == "" && post.Link == "" {
			return "", metaMediaError("facebook post has neither message nor link")
		}
		c.path = "/" + pageID + "/feed"
		if post.Message != "" {
			c.form.Set("message", post.Message)
		}
		if post.Link != "" {
			c.form.Set("link", post.Link)
		}
	}
	var out struct {
		ID     string `json:"id"`
		PostID string `json:"post_id"`
	}
	if err := m.do(ctx, c, &out); err != nil {
		return "", fmt.Errorf("meta page post: %w", err)
	}
	if out.PostID != "" {
		return out.PostID, nil
	}
	if out.ID == "" {
		return "", errors.New("meta page post: no id in the answer")
	}
	return out.ID, nil
}

// InstagramMedia is one container: an image (JPEG, public HTTPS URL), a
// carousel item (IsCarouselItem, no caption) or a carousel parent (Children
// holds the item container ids, MediaType CAROUSEL).
type InstagramMedia struct {
	ImageURL       string
	Caption        string
	MediaType      string // IMAGE (default) or CAROUSEL
	IsCarouselItem bool
	Children       []string
}

func (md InstagramMedia) validate() error {
	if utf8.RuneCountInString(md.Caption) > InstagramCaptionMaxChars {
		return metaMediaError("instagram caption is over %d characters", InstagramCaptionMaxChars)
	}
	if n := countHashtags(md.Caption); n > InstagramMaxHashtags {
		return metaMediaError("instagram caption has %d hashtags, at most %d", n, InstagramMaxHashtags)
	}
	switch md.MediaType {
	case "", "IMAGE":
		return checkHTTPS("image url", md.ImageURL)
	case "CAROUSEL":
		if len(md.Children) < 2 || len(md.Children) > InstagramCarouselMax {
			return metaMediaError("instagram carousel needs 2..%d items, has %d", InstagramCarouselMax, len(md.Children))
		}
		for _, id := range md.Children {
			if err := checkGraphID("carousel item", id); err != nil {
				return err
			}
		}
		return nil
	default:
		return metaMediaError("instagram media type %q is not supported", md.MediaType)
	}
}

// CreateInstagramContainer makes a media container for igUserID and returns
// its id. Retried on a transient failure: an unpublished container is
// private and expires after 24 h.
func (m *Meta) CreateInstagramContainer(ctx context.Context, pageAccessToken Plaintext, igUserID string, media InstagramMedia) (string, error) {
	if err := checkGraphID("instagram user id", igUserID); err != nil {
		return "", err
	}
	if err := media.validate(); err != nil {
		return "", err
	}
	f := url.Values{}
	if media.MediaType == "CAROUSEL" {
		f.Set("media_type", "CAROUSEL")
		f.Set("children", strings.Join(media.Children, ","))
	} else {
		f.Set("image_url", media.ImageURL)
	}
	if media.IsCarouselItem {
		f.Set("is_carousel_item", "true")
	} else if media.Caption != "" {
		f.Set("caption", media.Caption)
	}
	var out struct {
		ID string `json:"id"`
	}
	c := metaCall{method: http.MethodPost, path: "/" + igUserID + "/media", form: f, tok: pageAccessToken, safe: true}
	if err := m.do(ctx, c, &out); err != nil {
		return "", fmt.Errorf("meta instagram container: %w", err)
	}
	if out.ID == "" {
		return "", errors.New("meta instagram container: no id in the answer")
	}
	return out.ID, nil
}

// The container status codes Meta reports.
const (
	ContainerFinished   = "FINISHED"
	ContainerInProgress = "IN_PROGRESS"
	ContainerPublished  = "PUBLISHED"
	ContainerErrored    = "ERROR"
	ContainerExpired    = "EXPIRED"
)

// ContainerStatus is a container's status_code and Meta's detail line.
type ContainerStatus struct {
	Code   string
	Detail string
}

// PollInstagramContainer reads containerID's status once.
func (m *Meta) PollInstagramContainer(ctx context.Context, pageAccessToken Plaintext, containerID string) (ContainerStatus, error) {
	if err := checkGraphID("container id", containerID); err != nil {
		return ContainerStatus{}, err
	}
	var out struct {
		StatusCode string `json:"status_code"`
		Status     string `json:"status"`
	}
	c := metaCall{method: http.MethodGet, path: "/" + containerID, query: url.Values{"fields": {"status_code,status"}}, tok: pageAccessToken, safe: true}
	if err := m.do(ctx, c, &out); err != nil {
		return ContainerStatus{}, fmt.Errorf("meta instagram container status: %w", err)
	}
	if out.StatusCode == "" {
		return ContainerStatus{}, errors.New("meta instagram container status: no status_code in the answer")
	}
	return ContainerStatus{Code: out.StatusCode, Detail: out.Status}, nil
}

// The container states that stop a publish.
var (
	ErrContainerNotReady  = errors.New("meta: instagram container is not finished yet")
	ErrContainerFailed    = errors.New("meta: instagram container failed or expired")
	ErrContainerPublished = errors.New("meta: instagram container is already published")
)

// ContainerStateError is a publish refused because of the container's state;
// it unwraps to ErrContainerNotReady, ErrContainerFailed or ErrContainerPublished.
type ContainerStateError struct {
	ContainerID string
	Status      ContainerStatus
	cause       error
}

// Error implements error.
func (e *ContainerStateError) Error() string {
	return fmt.Sprintf("%s (container %s, status %s: %s)", e.cause.Error(), e.ContainerID, e.Status.Code, e.Status.Detail)
}

// Unwrap returns the sentinel.
func (e *ContainerStateError) Unwrap() error { return e.cause }

func containerGate(id string, st ContainerStatus) error {
	switch st.Code {
	case ContainerFinished:
		return nil
	case ContainerInProgress:
		return &ContainerStateError{ContainerID: id, Status: st, cause: ErrContainerNotReady}
	case ContainerPublished:
		return &ContainerStateError{ContainerID: id, Status: st, cause: ErrContainerPublished}
	default:
		return &ContainerStateError{ContainerID: id, Status: st, cause: ErrContainerFailed}
	}
}

// PublishInstagramContainer makes containerID public on igUserID and returns
// the media id. It reads the container's status first and refuses anything
// but FINISHED with a *ContainerStateError, so an ERROR or EXPIRED container
// fails the post at once and a PUBLISHED one is never published twice.
// media_publish itself is never retried once sent.
func (m *Meta) PublishInstagramContainer(ctx context.Context, pageAccessToken Plaintext, igUserID, containerID string) (string, error) {
	if err := checkGraphID("instagram user id", igUserID); err != nil {
		return "", err
	}
	st, err := m.PollInstagramContainer(ctx, pageAccessToken, containerID)
	if err != nil {
		return "", err
	}
	if err := containerGate(containerID, st); err != nil {
		return "", err
	}
	var out struct {
		ID string `json:"id"`
	}
	c := metaCall{method: http.MethodPost, path: "/" + igUserID + "/media_publish", form: url.Values{"creation_id": {containerID}}, tok: pageAccessToken}
	if err := m.do(ctx, c, &out); err != nil {
		return "", fmt.Errorf("meta instagram publish: %w", err)
	}
	if out.ID == "" {
		return "", errors.New("meta instagram publish: no media id in the answer")
	}
	return out.ID, nil
}

// countHashtags counts the words that start with '#'.
func countHashtags(s string) int {
	n := 0
	for _, w := range strings.Fields(s) {
		if strings.HasPrefix(w, "#") && len(w) > 1 {
			n++
		}
	}
	return n
}

// checkGraphID refuses an empty id or one that would change the path.
func checkGraphID(what, id string) error {
	if id == "" || strings.ContainsAny(id, "/?#&%. ") {
		return fmt.Errorf("meta: %s %q is not a Graph id", what, id)
	}
	return nil
}

// checkHTTPS refuses a media URL Meta's crawler cannot fetch.
func checkHTTPS(what, raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return metaMediaError("%s must be a public https URL", what)
	}
	return nil
}

// The permalink fields: a Page post's is permalink_url, an Instagram
// media's is permalink.
const (
	PermalinkFacebook  = "permalink_url"
	PermalinkInstagram = "permalink"
)

// Permalink reads the public link of a published Page post or Instagram
// media (field PermalinkFacebook or PermalinkInstagram). A read, so it is
// retried on a transient failure; "" with no error when Meta gives none.
func (m *Meta) Permalink(ctx context.Context, pageAccessToken Plaintext, id, field string) (string, error) {
	if err := checkGraphID("post id", id); err != nil {
		return "", err
	}
	if field != PermalinkFacebook && field != PermalinkInstagram {
		return "", fmt.Errorf("meta: permalink field %q is not known", field)
	}
	var out map[string]any
	c := metaCall{method: http.MethodGet, path: "/" + id, query: url.Values{"fields": {field}}, tok: pageAccessToken, safe: true}
	if err := m.do(ctx, c, &out); err != nil {
		return "", fmt.Errorf("meta permalink: %w", err)
	}
	link, _ := out[field].(string)
	return link, nil
}
