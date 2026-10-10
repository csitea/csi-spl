// Package embedassets holds the files the hub serves under /embed/v1/
// (specs/121 section 5, T202): the loader a customer page includes with one
// script tag, and the chat page that loader frames. hub.routeEmbedServe
// serves them; T201 set their headers (embed_serve.go).
//
// The parent page and the chat iframe talk only through postMessage, with an
// exact targetOrigin and an event.origin check, and carry UI events only:
// open, close and the unread count, never message text (spec 5). The visitor
// token lives in the iframe's own localStorage and travels as
// Authorization: Bearer (spec 4.1).
package embedassets

import "embed"

// FS holds loader.js and chat.html, the names hub.serveEmbed reads.
//
//go:embed loader.js chat.html
var FS embed.FS
