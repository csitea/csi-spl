package hubclient

import "context"

// UploadToken is the bearer this session presents on REST. It is the token
// the welcome frame minted, refreshed when it is about to expire: the same
// credential the file and pin calls send as Authorization: Bearer. The
// workspace doc verbs send it on /v1/workspace/docs/.
func (s *Session) UploadToken(ctx context.Context) (string, error) {
	return s.uploadToken(ctx)
}
