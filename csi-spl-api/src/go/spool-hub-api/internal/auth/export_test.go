package auth

// ClientIP exposes clientIP to the external test package.
var ClientIP = clientIP

// ErrExchange and ExchangeToken expose the token-exchange sentinel and helper
// to the external test package.
var (
	ErrExchange   = errExchange
	ExchangeToken = exchangeToken
)
