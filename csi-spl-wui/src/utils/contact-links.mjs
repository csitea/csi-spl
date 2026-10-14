// csi-spl-wui/src/utils/contact-links.mjs
//
// SPL-1609 (owner HUM-10, t1 51363151): an email address or a phone number in
// a message opens the app the reader picked in Settings -> Behaviour.
//
//   email_client  'gmail'        Gmail compose in the browser (the default,
//                                owner f8d7f523), a new tab
//                 'system'       mailto:, the device's own mail app
//                 'outlook-web'  Outlook on the web compose, a new tab
//                 'outlook'      mailto:, the desktop Outlook as the OS handler
//                 'thunderbird'  mailto:, Thunderbird as the OS handler
//   phone_app     'whatsapp'     https://wa.me/<digits> (the default, 81228b5b)
//                 'tel'          tel:+<digits>, the phone
//                 'viber' 'telegram' 'signal' 'teams'
//
// The parse tree keeps the canonical href (mailto:<addr>, tel:+<e164>); the
// renderers (MessageRuns, MarkdownBlock) build the chosen app's link from it
// with contactHref at render time, so a change of the setting re-renders
// every open body. The hub keeps both choices (auth.ViewPrefs, rdb 0193);
// tests/unit/contact-links.test.mjs pins the lists equal.

export const EMAIL_CLIENTS = Object.freeze(['gmail', 'system', 'outlook-web', 'outlook', 'thunderbird'])
export const PHONE_APPS = Object.freeze(['whatsapp', 'tel', 'viber', 'telegram', 'signal', 'teams'])

/** One of EMAIL_CLIENTS exactly, else the default (Gmail in the browser). */
export function parseEmailClient(raw) {
  return EMAIL_CLIENTS.includes(raw) ? raw : EMAIL_CLIENTS[0]
}

/** One of PHONE_APPS exactly, else the default (WhatsApp). */
export function parsePhoneApp(raw) {
  return PHONE_APPS.includes(raw) ? raw : PHONE_APPS[0]
}

function decode(s) {
  try { return decodeURIComponent(s) } catch { return s }
}

/* the compose url's own name of each mailto header it keeps */
const WEB_COMPOSE = {
  gmail: { base: 'https://mail.google.com/mail/?view=cm&fs=1', names: { subject: 'su', body: 'body', cc: 'cc', bcc: 'bcc' } },
  'outlook-web': { base: 'https://outlook.office.com/mail/deeplinkcompose?', names: { subject: 'subject', body: 'body', cc: 'cc', bcc: 'bcc' } },
}

/**
 * The link a mailto: href opens with `client`: a web composer's url (the
 * address, subject, body, cc and bcc kept, url-encoded) or the mailto: link
 * itself. null when href is not a mailto: link with an address.
 * @param {string} href
 * @param {unknown} client
 */
export function emailHref(href, client) {
  const s = String(href ?? '')
  if (!/^mailto:/i.test(s)) return null
  const q = s.indexOf('?')
  const to = decode(s.slice(7, q < 0 ? undefined : q)).trim()
  if (!to.includes('@')) return null
  const web = WEB_COMPOSE[parseEmailClient(client)]
  if (!web) return s
  const params = [['to', to]]
  for (const kv of q < 0 ? [] : s.slice(q + 1).split('&')) {
    const i = kv.indexOf('=')
    const name = web.names[decode(i < 0 ? kv : kv.slice(0, i)).toLowerCase()]
    if (name && i > 0) params.push([name, decode(kv.slice(i + 1))])
  }
  const sep = web.base.endsWith('?') ? '' : '&'
  return web.base + sep + params.map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&')
}

/**
 * The link a tel: href opens with `app`, the number in E.164 (+ and 7..15
 * digits). null when href is not a tel: link with such a number.
 * @param {string} href
 * @param {unknown} app
 */
export function phoneHref(href, app) {
  const s = String(href ?? '')
  if (!/^tel:/i.test(s)) return null
  const m = /^\+?(\d{7,15})$/.exec(decode(s.slice(4)).replace(/[\s().-]/g, ''))
  if (!m) return null
  const d = m[1]
  switch (parsePhoneApp(app)) {
    case 'tel': return `tel:+${d}`
    case 'viber': return `viber://chat?number=%2B${d}`
    case 'telegram': return `https://t.me/+${d}`
    case 'signal': return `sgnl://signal.me/#p/+${d}`
    case 'teams': return `https://teams.microsoft.com/l/call/0/0?users=4:+${d}`
    default: return `https://wa.me/${d}`
  }
}

/**
 * The href an anchor carries for this reader: a mailto: or tel: link built
 * for their email_client / phone_app (never picked = Gmail / WhatsApp);
 * every other href as it is.
 * @param {string} href
 * @param {{ email_client?: unknown, phone_app?: unknown } | null | undefined} prefs
 */
export function contactHref(href, prefs) {
  const s = String(href ?? '')
  if (/^mailto:/i.test(s)) return emailHref(s, prefs?.email_client) ?? s
  if (/^tel:/i.test(s)) return phoneHref(s, prefs?.phone_app) ?? s
  return s
}

/*
 * A phone number in text: + and 7..15 digits, single spaces or dashes
 * between them, standing on its own. Not glued to a word, a digit, a slash,
 * a dot, a colon, a # or an @ on either side (an id, a sha, a url path, a
 * version, an order number, a time offset), and not a date (+2026-10-13).
 */
const PHONE_RE = /(?<![\w+/.:#@&=%-])\+\d(?:[ -]?\d){6,14}(?![\w+@/]|[ -]\d|[.:,]\d)/g
const DATE_RE = /^\+\d{4}-\d{2}-\d{2}$/

/** Plain text -> text / link parts, each phone number a tel:+<e164> link. */
export function phoneParts(text) {
  const s = String(text)
  const parts = []
  let last = 0
  for (const m of s.matchAll(PHONE_RE)) {
    if (DATE_RE.test(m[0])) continue
    if (m.index > last) parts.push({ type: 'text', text: s.slice(last, m.index) })
    parts.push({ type: 'link', text: m[0], href: 'tel:+' + m[0].replace(/\D/g, '') })
    last = m.index + m[0].length
  }
  if (last === 0) return [{ type: 'text', text: s }]
  if (last < s.length) parts.push({ type: 'text', text: s.slice(last) })
  return parts
}

/** Does the text hold a phone number at all? A cheap test before splitting. */
export function hasPhone(text) {
  return String(text).includes('+') && phoneParts(text).length > 1
}

function phoneRuns(parts) {
  if (!parts.some((p) => p.type === 'text' && hasPhone(p.text))) return parts
  return parts.flatMap((p) => (p.type === 'text' ? phoneParts(p.text) : [p]))
}

/** parseBody's blocks with every phone number in their text runs a link. */
export function phoneBlocks(blocks) {
  return blocks.map((b) => {
    if (Array.isArray(b.parts)) {
      const parts = phoneRuns(b.parts)
      return parts === b.parts ? b : { ...b, parts }
    }
    if (Array.isArray(b.items)) {
      const items = b.items.map((it) => {
        const parts = phoneRuns(it.parts || [])
        return parts === it.parts ? it : { ...it, parts }
      })
      return items.every((it, i) => it === b.items[i]) ? b : { ...b, items }
    }
    return b
  })
}
