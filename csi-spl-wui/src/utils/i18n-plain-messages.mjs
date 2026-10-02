// Perf round 3, P3-20: a build ships every message without a placeholder,
// link, plural or escape as its plain string instead of the compiled AST
// (src/node/i18n/split-catalogue.mjs plainStatics) - about a third of the
// bytes, and nothing for vue-i18n to deep-copy or proxy. vue-i18n is
// runtime-only (CLE-35075): its compiler only evaluates an AST, so this one
// hands a plain string back exactly as the AST of a static message evaluates
// (@intlify/core-base formatMessageParts: the text, or normalize([text]) for
// <i18n-t>'s vnodes) and passes every AST on to vue-i18n's own.
// src/plugins/0.i18n-plain-messages.ts registers it.
import { compile } from '@intlify/core-base'

/** A vue-i18n message compiler: plain strings as they are, an AST to `compile`. */
export function plainMessageCompiler(message, context) {
  if (typeof message !== 'string') return compile(message, context)
  const text = message
  return (ctx) => (ctx.type === 'text' ? text : ctx.normalize([text]))
}
