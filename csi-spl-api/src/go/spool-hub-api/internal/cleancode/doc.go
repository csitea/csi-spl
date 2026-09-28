// Package cleancode holds no code: its test is the Go module's clean-code
// gate (SPL-1029). It walks every non-test .go file and fails on a new
// function over the length ceiling, a nesting depth or parameter list over
// the limit, or a helper that was folded into one package being pasted back.
package cleancode
