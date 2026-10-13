/**
 * poll-control (SPL-1637, owner HUM-10, t1 aab3d88b): questions in a post
 * answered by a click. The wire stays plain text, no new message field:
 *
 *   ```poll
 *   Which deploy path?
 *   (A) Deploy now
 *   (B) Wait for CI
 *   ```
 *
 * The fence is the FORM: one per message (owner msg b14c95a4); a second
 * ```poll fence in the same body stays a code block. A form holds one or more
 * questions: a line that is not an option starts the next question, its
 * options follow. `(A) text` options make a radio form (pick one per
 * question), `[A] text` a checkbox form (pick any). A form is all radios or
 * all checkboxes, never both (owner msg f24f06f2): a mixed fence is not a
 * form and stays a code block. An old client shows the fence as text, which
 * still reads as questions with lettered options.
 *
 * The answer is a normal reply in the poll's topic, posted by the click
 * (radio, fire and forget, owner msg 87b56449) or when a checkbox form locks
 * in (45 s per question after the first click, or its Send; owner msg
 * 8f0da7ca). Its lines are the machine-readable marker:
 *
 *   Poll: <msg_id>                the form's message
 *   Answer: A — Deploy now        one question (checkbox: `A,C — x; y`, `none`)
 *   Answer 2: B — Later           a form of several questions, one line each
 *   Chat: wants to discuss        "Chat about this" (owner msg 6cd5873a): text follows
 *
 * Each answer reply carries the sender's whole current form; the newest one
 * of a sender is that sender's answer (re-answer replaces). The one rule for
 * writers: csi-spl-doc/doc/help/how-to-post.md.
 */

/** owner msg 8f0da7ca: checkbox picks lock in 45 s per question after the first click */
export const LOCK_SECONDS_PER_QUESTION = 45

const OPEN_RE = /^(`{3,})poll[ \t]*$/
const FENCE_RE = /^(`{3,})/
const CLOSE_RE = /^(`{3,})[ \t]*$/
const OPTION_RE = /^(?:[-*][ \t]+)?([([])[ \t]*([A-Za-z0-9]{1,3})[ \t]*([)\]])[ \t]+(\S.*)$/
const CHAT_RE = /^chat about this\.?$/i
const KEYS_SRC = String.raw`([A-Za-z0-9]{1,3}(?:[ \t]*,[ \t]*[A-Za-z0-9]{1,3})*|none)\b`
const MARKER_ANSWER_RE = new RegExp(String.raw`^Answer(?:[ \t]+(\d+))?:[ \t]*${KEYS_SRC}`, 'gim')
const MARKER_CHAT_RE = /^Chat:[ \t]*wants to discuss\b/im
const MARKER_POLL_RE = /^Poll:[ \t]*([0-9A-Za-z-]{8,})[ \t]*$/im

export { mayHavePoll } from './poll-fence.mjs'

/**
 * One form fence's text -> { multi, questions: [{ text, options: [{ key, text }] }] },
 * or null when it is not a form (a question with no option, an option before
 * any question is fine, radios and checkboxes mixed, a key twice in one
 * question). An author's own "Chat about this" option is dropped: the
 * renderer always adds it.
 */
export function parsePoll(text) {
  const questions = []
  let shape = ''
  let q = null
  for (const raw of String(text || '').split('\n')) {
    const line = raw.trim()
    if (!line) continue
    const m = OPTION_RE.exec(line)
    const opt = m && (m[1] === '(' ? m[3] === ')' : m[3] === ']')
    if (!opt) {
      if (q && !q.options.length) q.text += ` ${line}`
      else questions.push(q = { text: line, options: [] })
      continue
    }
    const kind = m[1] === '(' ? 'radio' : 'check'
    if (shape && shape !== kind) return null
    shape = kind
    if (!q) questions.push(q = { text: '', options: [] })
    if (CHAT_RE.test(m[4].trim())) { q.chat = true; continue }
    const key = m[2].toUpperCase()
    if (q.options.some((o) => o.key === key)) return null
    q.options.push({ key, text: m[4].trim() })
  }
  const real = questions.filter((x) => x.options.length || x.chat)
  if (!real.length || real.length !== questions.length || real.some((x) => !x.options.length)) return null
  return { multi: shape === 'check', questions: real.map(({ text, options }) => ({ text, options })) }
}

/**
 * The body as segments in order: { type: 'text', text } and one
 * { type: 'poll', poll } at most. A ```poll inside another fence is that
 * fence's content; an unclosed, invalid or second form stays text.
 */
export function splitPolls(body) {
  const lines = String(body || '').replace(/\r\n?/g, '\n').split('\n')
  const out = []
  let text = []
  let seen = false
  const flush = () => {
    if (text.join('\n').trim()) out.push({ type: 'text', text: text.join('\n') })
    text = []
  }
  for (let i = 0; i < lines.length; i++) {
    const open = seen ? null : OPEN_RE.exec(lines[i])
    const fence = open ? null : FENCE_RE.exec(lines[i])
    if (fence) {
      /* any other fence: copied through to its closer untouched */
      const n = fence[1].length
      text.push(lines[i])
      for (i++; i < lines.length; i++) {
        text.push(lines[i])
        const c = CLOSE_RE.exec(lines[i])
        if (c && c[1].length >= n) break
      }
      continue
    }
    if (!open) { text.push(lines[i]); continue }
    const n = open[1].length
    let close = -1
    for (let j = i + 1; j < lines.length; j++) {
      const c = CLOSE_RE.exec(lines[j])
      if (c && c[1].length >= n) { close = j; break }
    }
    const poll = close < 0 ? null : parsePoll(lines.slice(i + 1, close).join('\n'))
    if (!poll) { text.push(lines[i]); continue }
    flush()
    seen = true
    out.push({ type: 'poll', poll })
    i = close
  }
  flush()
  return out
}

/**
 * The reply a pick posts: the sender's whole current form. `picks` is one
 * key array per question; an empty one is `none` on a checkbox form and left
 * out on a radio form (not answered yet).
 */
export function answerBody(poll, picks, msgId) {
  const lines = [`Poll: ${msgId}`]
  const many = poll.questions.length > 1
  poll.questions.forEach((q, i) => {
    const keys = picks[i] || []
    if (!keys.length && !poll.multi) return
    const picked = q.options.filter((o) => keys.includes(o.key))
    const head = picked.length ? picked.map((o) => o.key).join(',') : 'none'
    const words = picked.map((o) => o.text).join('; ')
    lines.push(`Answer${many ? ` ${i + 1}` : ''}: ${head}${words ? ` — ${words}` : ''}`)
  })
  return lines.join('\n')
}

/** the start of the reply "Chat about this" opens: the marker and the question quoted */
export function chatBody(poll, msgId, question = 0) {
  const q = poll.questions[question] || poll.questions[0]
  const quote = q && q.text ? `> ${q.text}\n` : ''
  return `Chat: wants to discuss\nPoll: ${msgId}\n${quote}\n`
}

/**
 * A reply's marker -> { msgId, chat, picks } or null; `picks` maps the
 * question number (1-based) to its keys ([] for `none`).
 */
export function parseAnswer(body) {
  const s = String(body || '')
  const p = MARKER_POLL_RE.exec(s)
  if (!p) return null
  if (MARKER_CHAT_RE.test(s)) return { msgId: p[1], chat: true, picks: {} }
  const picks = {}
  for (const a of s.matchAll(MARKER_ANSWER_RE)) {
    picks[a[1] ? Number(a[1]) : 1] = a[2].toLowerCase() === 'none' ? [] : a[2].split(',').map((k) => k.trim().toUpperCase())
  }
  return Object.keys(picks).length ? { msgId: p[1], chat: false, picks } : null
}

/**
 * The answers to one form from a list of rows: the newest marker reply per
 * sender (chats skipped: they are not answers), oldest answerer first.
 * -> [{ from, picks, ts }]
 */
export function pollAnswers(rows, msgId) {
  const latest = new Map()
  for (const r of rows || []) {
    const a = parseAnswer(r && r.body)
    if (!a || a.chat || a.msgId !== String(msgId)) continue
    const from = String(r.from || '')
    const ts = String(r.ts || '')
    const prev = latest.get(from)
    if (!prev || prev.ts <= ts) latest.set(from, { from, picks: a.picks, ts, first: prev ? prev.first : ts })
  }
  return [...latest.values()].sort((a, b) => (a.first < b.first ? -1 : 1)).map(({ from, picks, ts }) => ({ from, picks, ts }))
}

/** the lock-in wait of a checkbox form: 45 s per question in it */
export function lockSeconds(questions) {
  return LOCK_SECONDS_PER_QUESTION * Math.max(1, Number(questions) || 1)
}
