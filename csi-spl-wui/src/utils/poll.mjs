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
 *   Chat: wants to discuss        "Chat about this" (owner msg 6cd5873a): leads, the
 *   > <question>                  question quoted, the reader's text after it
 *
 * Each answer reply carries the sender's whole current form; the newest one
 * of a sender is that sender's answer (re-answer replaces). A chat reply
 * newer than it shows "Chat about this" picked on the question it quotes
 * (SPL-1851). The one rule for writers: csi-spl-doc/doc/help/how-to-post.md.
 */

/** owner msg 8f0da7ca: checkbox picks lock in 45 s per question after the first click */
export const LOCK_SECONDS_PER_QUESTION = 45

const OPEN_RE = /^(`{3,})poll[ \t]*$/
const FENCE_RE = /^(`{3,})/
const CLOSE_RE = /^(`{3,})[ \t]*$/
/* SPL-3062 (owner HUM-10, msg fb2b4cdf): a markdown task-list marker `[ ]` / `[x]`
   before an option is dropped, so `- [ ] (A) text` is option A, not a code
   block; only when an option follows, so `[x] text` stays checkbox X */
const OPTION_RE = /^(?:[-*][ \t]+)?(?:\[[ xX]?\][ \t]+(?=[([][ \t]*[A-Za-z0-9]{1,3}[ \t]*[)\]][ \t]+\S))?([([])[ \t]*([A-Za-z0-9]{1,3})[ \t]*([)\]])[ \t]+(\S.*)$/
const CHAT_RE = /^chat about this\.?$/i
/* a line that tries to be an option but is none (`A) x`, `(A] x`, `A. x`): named in pollProblems' reason */
const NEAR_OPTION_RE = /^(?:[-*][ \t]+)?(?:\[[ xX]?\][ \t]+)?[([]?[ \t]*[A-Za-z0-9]{1,3}[ \t]*[)\].:][ \t]+\S/
const KEYS_SRC = String.raw`([A-Za-z0-9]{1,3}(?:[ \t]*,[ \t]*[A-Za-z0-9]{1,3})*|none)\b`
const MARKER_ANSWER_RE = new RegExp(String.raw`^Answer(?:[ \t]+(\d+))?:[ \t]*${KEYS_SRC}`, 'gim')
/* SPL-1851: anywhere, not only leading: a reply sent while the caret sat
   before the marker (t1 d64c762a msg b09c5a8c) still counts as the chat */
const MARKER_CHAT_RE = /Chat:[ \t]*wants to discuss\b/i
const MARKER_QUOTE_RE = /^>[ \t]?(.*\S)[ \t]*$/m
const MARKER_POLL_RE = /^Poll:[ \t]*([0-9A-Za-z-]{8,})[ \t]*$/im

export { mayHavePoll } from './poll-fence.mjs'

/**
 * One form fence's text -> { multi, questions: [{ text, kind, options: [{ key, text }] }] },
 * kind 'radio' | 'check' | 'button' (a radio question with one option),
 * or null when it is not a form (a question with no option, an option before
 * any question is fine, radios and checkboxes mixed, a key twice in one
 * question). An author's own "Chat about this" option is dropped: the
 * renderer always adds it.
 */
export function parsePoll(text) {
  return readPoll(text).poll
}

/* parsePoll with the reason a fence is no form: { poll } or { poll: null, why } */
function readPoll(text) {
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
      if (NEAR_OPTION_RE.test(line)) (q.near ||= []).push(line)
      continue
    }
    const kind = m[1] === '(' ? 'radio' : 'check'
    if (shape && shape !== kind) return { poll: null, why: `radios \`(A)\` and checkboxes \`[A]\` are mixed ("${line}")` }
    shape = kind
    if (!q) questions.push(q = { text: '', options: [] })
    if (CHAT_RE.test(m[4].trim())) { q.chat = true; continue }
    const key = m[2].toUpperCase()
    if (q.options.some((o) => o.key === key)) return { poll: null, why: `key ${key} twice in question "${q.text}"` }
    q.options.push({ key, text: m[4].trim() })
  }
  const bare = questions.find((x) => !x.options.length)
  if (bare) {
    const near = bare.near ? `; not an option line: "${bare.near[0]}"` : ''
    return { poll: null, why: `question "${bare.text}" has no option line${near}` }
  }
  if (!questions.length) return { poll: null, why: 'the fence is empty' }
  /* SPL-1654 (owner d16ba428): a radio question with ONE option is a Go
     button; a checkbox question keeps its box (an opt-in, not a go) */
  const kindOf = (options) => (shape === 'check' ? 'check' : options.length === 1 ? 'button' : 'radio')
  return { poll: { multi: shape === 'check', questions: questions.map(({ text, options }) => ({ text, kind: kindOf(options), options })) } }
}

/**
 * SPL-3062 (owner HUM-10, msg fb2b4cdf): why a body's ```poll fences would
 * not render as a form, one line per problem ([] when they would, or when
 * there is none): a fence that does not parse, is not closed, or is the
 * second one. A ```poll inside another fence is that fence's content. The
 * send actions (csi-spl-orc spl_desk_poll_check) refuse a post on any line.
 */
export function pollProblems(body) {
  const lines = String(body || '').replace(/\r\n?/g, '\n').split('\n')
  const out = []
  let forms = 0
  for (let i = 0; i < lines.length; i++) {
    const open = OPEN_RE.exec(lines[i])
    const fence = open || FENCE_RE.exec(lines[i])
    if (!fence) continue
    const n = fence[1].length
    let close = -1
    for (let j = i + 1; j < lines.length; j++) {
      const c = CLOSE_RE.exec(lines[j])
      if (c && c[1].length >= n) { close = j; break }
    }
    if (open) {
      forms++
      if (forms > 1) out.push(`a second \`\`\`poll fence (line ${i + 1}): one form per message`)
      else if (close < 0) out.push(`the \`\`\`poll fence of line ${i + 1} is never closed`)
      else {
        const { why } = readPoll(lines.slice(i + 1, close).join('\n'))
        if (why) out.push(`the \`\`\`poll fence of line ${i + 1} is no form: ${why}`)
      }
    }
    if (close < 0) break
    i = close
  }
  return out
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
 * question number (1-based) to its keys ([] for `none`). A chat also
 * carries `quote`, the question it quotes ('' when none).
 */
export function parseAnswer(body) {
  const s = String(body || '')
  const p = MARKER_POLL_RE.exec(s)
  if (!p) return null
  if (MARKER_CHAT_RE.test(s)) {
    const q = MARKER_QUOTE_RE.exec(s.slice(p.index))
    return { msgId: p[1], chat: true, picks: {}, quote: q ? q[1] : '' }
  }
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

/**
 * SPL-1851: per question of `poll`, the ts of `from`'s chat reply when it is
 * newer than their newest answer ('' otherwise): the form shows "Chat about
 * this" picked there. A chat names its question by the quote chatBody wrote
 * (the first question when it quotes none); a row with no ts yet is the
 * newest (our own reply on its way).
 */
export function chatPicks(poll, rows, msgId, from) {
  let answered = ''
  const chats = poll.questions.map(() => '')
  for (const r of rows || []) {
    const a = r && String(r.from || '') === String(from) ? parseAnswer(r.body) : null
    if (!a || a.msgId !== String(msgId)) continue
    const ts = String(r.ts || '~')
    if (!a.chat) {
      if (ts > answered) answered = ts
      continue
    }
    const i = Math.max(0, poll.questions.findIndex((q) => q.text && q.text === a.quote))
    if (ts > chats[i]) chats[i] = ts
  }
  return chats.map((ts) => (ts > answered ? ts : ''))
}

/** the lock-in wait of a checkbox form: 45 s per question in it */
export function lockSeconds(questions) {
  return LOCK_SECONDS_PER_QUESTION * Math.max(1, Number(questions) || 1)
}
