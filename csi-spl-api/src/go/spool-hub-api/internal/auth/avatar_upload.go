package auth

// A person changes their own picture, the simplest version (owner HUM-10,
// t1 ccaee528): PUT /api/v1/auth/avatar stores one uploaded image where the
// IdP picture lives, DELETE goes back to the IdP picture. GET (handler.go
// avatar) and every roster read pick it up unchanged.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
)

// AvatarSetter changes the signed-in human's own picture (t1 ccaee528,
// PUT / DELETE /api/v1/auth/avatar). An Options.Avatars that implements it
// backs those routes; else they answer 503.
type AvatarSetter interface {
	// SetOwnAvatar stores pic (already checked: an image type, the size cap)
	// as the human's picture; a later sign-in keeps it.
	SetOwnAvatar(ctx context.Context, humanID string, pic []byte) error
	// ClearOwnAvatar goes back to the IdP picture.
	ClearOwnAvatar(ctx context.Context, humanID string) error
}

// ErrAvatarFixed from an AvatarSetter refuses a demo visitor, who keeps the
// default picture as it keeps its pseudonym (specs/077 T011): 403.
var ErrAvatarFixed = errors.New("auth: a demo visitor keeps the default picture")

// uploadTypes are the pictures a person may upload: avatarTypes without gif
// (no animated avatars).
var uploadTypes = map[string]bool{"image/png": true, "image/jpeg": true, "image/webp": true}

// avatarWriter is the signed-in human allowed to change their own picture,
// or false with the refusal written: 401 without a session, 403 for an act-as
// clone (never the member's picture), 409 without a registered human, 503
// when no AvatarSetter is wired. There is no target id: only the session's
// own human can be changed.
func (h *Handler) avatarWriter(w http.ResponseWriter, r *http.Request) (string, AvatarSetter, bool) {
	w.Header().Set("Cache-Control", "no-store")
	s, ok := h.SessionFromRequest(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthenticated", "no valid session")
		return "", nil, false
	}
	if s.Provider == ProviderActAs {
		writeErr(w, http.StatusForbidden, "act_as", "an act-as session does not change the picture")
		return "", nil, false
	}
	if s.HumanID == "" {
		writeErr(w, http.StatusConflict, "no_human", "this session has no registered human")
		return "", nil, false
	}
	set, _ := h.avatars.(AvatarSetter)
	if set == nil {
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "pictures are not configured")
		return "", nil, false
	}
	return s.HumanID, set, true
}

// putAvatar stores the request body as the signed-in human's own picture
// (t1 ccaee528): one png, jpeg or webp image, the type sniffed from the bytes
// (415 else), at most AvatarMaxBytes (413 else). No crop, no resize. 204.
func (h *Handler) putAvatar(w http.ResponseWriter, r *http.Request) {
	hum, set, ok := h.avatarWriter(w, r)
	if !ok {
		return
	}
	pic, err := io.ReadAll(http.MaxBytesReader(w, r.Body, AvatarMaxBytes))
	var tooBig *http.MaxBytesError
	if errors.As(err, &tooBig) {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", fmt.Sprintf("a picture is at most %d KB", AvatarMaxBytes>>10))
		return
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "picture body")
		return
	}
	if ct := sniffImage(pic); !uploadTypes[ct] {
		writeErr(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "a picture is a png, jpeg or webp image")
		return
	}
	h.avatarStored(w, hum, set.SetOwnAvatar(r.Context(), hum, pic))
}

// deleteAvatar goes back to the signed-in human's IdP picture (204); with no
// upload it changes nothing.
func (h *Handler) deleteAvatar(w http.ResponseWriter, r *http.Request) {
	hum, set, ok := h.avatarWriter(w, r)
	if !ok {
		return
	}
	h.avatarStored(w, hum, set.ClearOwnAvatar(r.Context(), hum))
}

// avatarStored maps an AvatarSetter error onto the answer.
func (h *Handler) avatarStored(w http.ResponseWriter, hum string, err error) {
	switch {
	case err == nil:
		w.WriteHeader(http.StatusNoContent)
	case errors.Is(err, ErrNoHuman):
		writeErr(w, http.StatusConflict, "no_human", "the session's human no longer exists")
	case errors.Is(err, ErrAvatarFixed):
		writeErr(w, http.StatusForbidden, "demo", "a demo visitor keeps the default picture")
	default:
		h.log.Warn().Err(err).Str("human_id", hum).Msg("auth.avatar_write_failed")
		writeErr(w, http.StatusServiceUnavailable, ErrCodeUnavailable, "picture store")
	}
}
