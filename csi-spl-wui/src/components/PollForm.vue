<template>
  <form
    ref="formEl"
    class="poll"
    :class="{ 'poll--multi': form.multi }"
    data-testid="poll-form"
    :data-poll-kind="form.multi ? 'checkbox' : 'radio'"
    :data-poll-id="msgId || undefined"
    @submit.prevent="lockIn"
    @click.stop
    @dblclick.stop
    @pointerdown.stop
    @keydown.stop
  >
    <fieldset v-for="(q, qi) in form.questions" :key="qi" class="poll-q" :disabled="!canAnswer" data-testid="poll-question">
      <legend v-if="q.text" class="poll-q__text">{{ q.text }}</legend>
      <!-- SPL-1654 (owner d16ba428, 28af126d): a one-option radio question is
           a Go button, the omnibox Go a bit smaller, green with a black play
           icon; one click posts the answer as a radio click does -->
      <div v-if="q.kind === 'button'" class="poll-go-row">
        <button
          type="button"
          class="btn poll-go"
          data-testid="poll-go-button"
          :data-poll-key="q.options[0].key"
          :aria-pressed="goDone(qi) ? 'true' : 'false'"
          @click="onGo(qi, q.options[0].key)"
        >
          <UiIcon name="go" :size="16" />
          <span class="poll-go__text">{{ q.options[0].text }}</span>
          <UiIcon v-if="goDone(qi)" name="check" :size="14" data-testid="poll-go-done" />
        </button>
        <button type="button" class="poll-chat-link" data-testid="poll-chat" @click="onChat(qi)">{{ t('poll.chat') }}</button>
      </div>
      <template v-else>
        <!-- SPL-1769: data-poll-key, never data-key: the feed's scroll anchor
             reads [data-key] as its row ids and held the page on an option -->
        <label v-for="o in q.options" :key="o.key" class="poll-opt" data-testid="poll-option" :data-poll-key="o.key">
          <input
            :type="form.multi ? 'checkbox' : 'radio'"
            class="poll-opt__input"
            :name="`${uid}-${qi}`"
            :value="o.key"
            :checked="(picks[qi] || []).includes(o.key)"
            @change="onPick(qi, o.key, ($event.target as HTMLInputElement).checked)"
          >
          <span class="poll-opt__key">{{ o.key }}</span>
          <span class="poll-opt__text">{{ o.text }}</span>
        </label>
        <!-- owner 6cd5873a: every question ALWAYS ends with "Chat about this";
             picking it is not an answer, it opens the reply box -->
        <label class="poll-opt poll-opt--chat" data-testid="poll-chat">
          <input
            :type="form.multi ? 'checkbox' : 'radio'"
            class="poll-opt__input"
            :name="`${uid}-${qi}`"
            value=""
            :checked="chatPicks[qi] || false"
            @change="onChat(qi, $event.target as HTMLInputElement)"
          >
          <span class="poll-opt__text">{{ t('poll.chat') }}</span>
        </label>
      </template>
    </fieldset>
    <div class="poll-foot">
      <!-- owner 8f0da7ca: a checkbox form also has a Send; a radio form never -->
      <button v-if="form.multi && canAnswer" type="submit" class="poll-send btn ghost" data-testid="poll-send" :disabled="!pending">{{ t('poll.send') }}</button>
      <span v-if="pending && left > 0" class="poll-lock" data-testid="poll-lock" role="timer">{{ t('poll.lock_in', { s: left }) }}</span>
      <span class="poll-state" role="status" data-testid="poll-state" :data-state="state || undefined">{{ state === 'sent' ? t('poll.sent') : state === 'failed' ? t('poll.failed') : '' }}</span>
    </div>
    <p v-if="answers.length" class="poll-answers" data-testid="poll-answers">
      <span class="poll-answers__label">{{ t('poll.answers') }}</span>
      <span v-for="a in answers" :key="a.from" class="poll-answer" data-testid="poll-answer" :data-from="a.from">{{ whoOf(a.from) }} — {{ picksText(a.picks) }}</span>
    </p>
  </form>
</template>

<script setup lang="ts">
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'
import { useLive } from '~/composables/useLive'
import { useHumanNames } from '~/composables/useHumanNames'
import { dmPeerOf, shownPerson } from '~/utils/channel-feed.mjs'
import { COMPOSER_FOCUS_EVENT } from '~/utils/touch-ui.mjs'
import { POLL_HOST, POLL_ROWS } from '~/utils/poll-fence.mjs'
import { answerBody, chatBody, lockSeconds, pollAnswers } from '~/utils/poll.mjs'
import { scrollerOf } from '~/utils/scroll-anchor.mjs'
import type { PollShape } from '~/components/PollBody.vue'
import type { SpoolMessage } from '~/types/spool'

const chatPicks = ref<Record<number, boolean>>({})

/* SPL-1637 poll-control (owner HUM-10, t1 aab3d88b). One form per message.
   A radio click posts the answer at once, fire and forget (owner 87b56449);
   a checkbox form locks in 45 s per question after its first click, or on
   its Send (owner 8f0da7ca). The answer is a plain reply in the form's topic
   whose marker agents parse (utils/poll.mjs); it carries the sender's whole
   current form, so re-answering replaces. Native inputs at text size (owner
   f20e1dc1: not too big), labels the click target, Tab / arrows / Space as
   the browser gives them. */
const props = defineProps<{ form: PollShape }>()
const formEl = ref<HTMLFormElement | null>(null)
const { t } = useI18n({ useScope: 'global' })
const uid = `poll-${useId()}`

type Host = { msg: () => SpoolMessage | null, open?: () => void }
const host = inject<Host | null>(POLL_HOST, null)
const paneRows = inject<(() => SpoolMessage[]) | null>(POLL_ROWS, null)
const msg = computed(() => host?.msg() || null)
const msgId = computed(() => String(msg.value?.msg_id || ''))
const canAnswer = computed(() => Boolean(msgId.value && msg.value?.task_id))

const channel = useChannelStore()
const pane = useLiveFeed('pane')
const access = useAccessStore()
const roster = useRosterStore()
const live = useLive()
const me = computed(() => String(access.me?.humanId || live.identity.value || roster.me?.id || ''))

const rows = computed(() => {
  const seen = new Set<string>()
  const out: SpoolMessage[] = []
  for (const r of [...(paneRows?.() || []), ...(channel.messages as SpoolMessage[]), ...(pane.messages as SpoolMessage[])]) {
    const id = String(r?.msg_id || '')
    if (id && seen.has(id)) continue
    seen.add(id)
    out.push(r)
  }
  return out
})
const answers = computed(() => (msgId.value ? pollAnswers(rows.value, msgId.value) : []) as Array<{ from: string, picks: Record<number, string[]>, ts: string }>)

/* the reader's picks: their newest posted answer until they click */
const picks = ref<string[][]>(props.form.questions.map(() => []))
const dirty = ref(false)
watch(answers, (list) => {
  if (dirty.value) return
  const mine = list.find((a) => a.from === me.value)
  if (mine) {
    picks.value = props.form.questions.map((_, i) => (mine.picks[i + 1] || []).slice())
  }
  // Always check for a chat reply, regardless of whether an answer exists
  // Recognize both leading and trailing markers for backward compatibility
  const chatReply = rows.value.find((r) => r.from === me.value && String(r.body || '').includes(`Poll: ${msgId.value}`) && /(^|\n)Chat: wants to discuss/i.test(String(r.body || '')))
  if (chatReply) {
    chatPicks.value = props.form.questions.reduce((acc, _, i) => {
      acc[i] = true
      return acc
    }, {} as Record<number, boolean>)
  } else {
    chatPicks.value = {}
  }
}, { immediate: true })

const state = ref<'' | 'sent' | 'failed'>('')
async function post(qi = -1) {
  const m = msg.value
  if (!m || !canAnswer.value) return
  const text = answerBody(props.form, picks.value, msgId.value)
  state.value = ''
  const release = holdPlace(qi)
  try {
    await channel.send(text, String(m.task_id), [], m.channel ? String(m.channel) : undefined, 0, m.channel ? undefined : (dmPeerOf(m, me.value) || undefined))
    state.value = 'sent'
  } catch {
    state.value = 'failed'
  } finally {
    release()
  }
}

/* SPL-1769 (owner 92149f81, 4778f585, e0e4a5ac): an answer must not throw
   the reader around, on the phone or on desktop. The answer reply lands in
   the feed around the form: above it in a newest-first thread (which anchors
   nothing), or as our own row the feed follows to its newest end. Until the
   reply has settled, every frame puts the form where the reader wants it:
   after a radio answer with a question below it, that next question's start
   glides to the top of the pane ("it will scroll till the next question's
   beginning"); after the last question or a checkbox Send, the form stays
   where it was on screen. A touch, wheel or key of the reader's own ends the
   hold at once; so does a form that was off screen (the reader is elsewhere). */
const HOLD_SETTLE_MS = 1200
const HOLD_MAX_MS = 15000
const NEXT_GAP_PX = 8
const GLIDE = 0.25
function holdPlace(qi = -1) {
  const el = formEl.value
  if (!el || typeof window === 'undefined' || !el.isConnected) return () => {}
  const s = scrollerOf(el) as HTMLElement
  const { top, bottom } = el.getBoundingClientRect()
  if (bottom < 0 || top > window.innerHeight) return () => {}
  const next = qi >= 0 ? el.querySelectorAll<HTMLElement>('[data-testid=poll-question]')[qi + 1] : undefined
  const anchor = next || el
  const paneTop = () => (s === document.scrollingElement || s === document.documentElement ? 0 : s.getBoundingClientRect().top)
  const at = next ? () => paneTop() + NEXT_GAP_PX : () => top
  const glide = next && !window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ? GLIDE : 1
  let until = performance.now() + HOLD_MAX_MS
  let frame = 0
  const inputs = ['touchstart', 'wheel', 'keydown'] as const
  const stop = () => {
    if (frame) cancelAnimationFrame(frame)
    frame = 0
    for (const ev of inputs) window.removeEventListener(ev, stop, true)
  }
  const tick = () => {
    frame = 0
    if (!el.isConnected || !anchor.isConnected) return stop()
    const shift = anchor.getBoundingClientRect().top - at()
    if (Math.abs(shift) >= 1) s.scrollTop += Math.abs(shift) <= 2 ? shift : Math.round(shift * glide) || Math.sign(shift)
    if (performance.now() < until) frame = requestAnimationFrame(tick)
    else stop()
  }
  for (const ev of inputs) window.addEventListener(ev, stop, { capture: true, passive: true })
  frame = requestAnimationFrame(tick)
  /* the send is done: hold a little longer for the echo and late heights */
  return () => { until = Math.min(until, performance.now() + HOLD_SETTLE_MS) }
}

/* checkbox lock-in: one deadline for the whole form, from its first click */
const deadline = ref(0)
const now = ref(Date.now())
const pending = computed(() => deadline.value > 0)
const left = computed(() => Math.max(0, Math.ceil((deadline.value - now.value) / 1000)))
let timer: ReturnType<typeof setInterval> | null = null
function stopTimer() {
  if (timer) clearInterval(timer)
  timer = null
  deadline.value = 0
}
function lockIn() {
  if (!pending.value) return
  stopTimer()
  void post()
}
function arm() {
  if (pending.value) return
  now.value = Date.now()
  deadline.value = now.value + lockSeconds(props.form.questions.length) * 1000
  timer = setInterval(() => {
    now.value = Date.now()
    if (now.value >= deadline.value) lockIn()
  }, 1000)
}
/* a card that leaves the screen with picks waiting still sends them */
onBeforeUnmount(lockIn)

/* a Go button is done once the reader's answer holds its key; a second
   click posts nothing new */
function goDone(qi: number) {
  return (picks.value[qi] || []).length > 0
}
function onGo(qi: number, key: string) {
  if (!goDone(qi)) onPick(qi, key, true)
}

function onPick(qi: number, key: string, on: boolean) {
  dirty.value = true
  const next = picks.value.map((p) => p.slice())
  if (props.form.multi) next[qi] = on ? [...new Set([...next[qi], key])].sort() : next[qi].filter((k) => k !== key)
  else next[qi] = [key]
  picks.value = next
  state.value = ''
  if (props.form.multi) arm()
  else void post(qi)
}

/* "Chat about this": the topic opens, the reply box takes the caret with the
   marker and the question quoted; the reader's picks stay as they were */
function onChat(qi: number, input?: HTMLInputElement) {
  if (input) input.checked = false
  for (const el of formEl.value?.querySelectorAll<HTMLInputElement>(`input[name="${uid}-${qi}"]`) || []) {
    el.checked = Boolean(el.value) && (picks.value[qi] || []).includes(el.value)
  }
  if (!canAnswer.value) return
  host?.open?.()
  const text = chatBody(props.form, msgId.value, qi)
  void nextTick(() => window.dispatchEvent(new CustomEvent(COMPOSER_FOCUS_EVENT, { detail: { text } })))
}

const people = useHumanNames()
function whoOf(id: string) {
  return id === me.value ? t('poll.you') : shownPerson(id, '', people.names.value)
}
function picksText(p: Record<number, string[]>) {
  const one = (k: string[] | undefined) => (k && k.length ? k.join(',') : t('poll.none'))
  if (props.form.questions.length === 1) return one(p[1])
  return props.form.questions.map((_, i) => `${i + 1}: ${one(p[i + 1])}`).join(' · ')
}
</script>

<style scoped>
.poll {
  margin: 4px 0;
  padding: 6px 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  font-size: 0.875rem;
  max-width: 100%;
  min-width: 0;
}
.poll-q {
  margin: 0;
  padding: 0;
  border: 0;
  min-width: 0;
}
.poll-q + .poll-q { margin-top: 6px; }
.poll-q__text {
  padding: 0;
  margin-bottom: 2px;
  font-weight: 600;
  overflow-wrap: anywhere;
}
.poll-opt {
  display: flex;
  align-items: baseline;
  gap: 6px;
  padding: 2px 0;
  cursor: pointer;
  overflow-wrap: anywhere;
}
.poll-q:disabled .poll-opt { cursor: default; }
/* native controls at text size: not too big (owner f20e1dc1) */
.poll-opt__input {
  flex: none;
  width: 14px;
  height: 14px;
  margin: 0;
  align-self: center;
  accent-color: var(--color-accent);
}
.poll-opt__key {
  flex: none;
  font-weight: 600;
  min-width: 1.2em;
}
.poll-opt__text { min-width: 0; }
.poll-opt--chat { color: var(--color-muted); font-style: italic; }
.poll-foot {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.poll-foot:has(> :not(:empty)) { margin-top: 4px; }
.poll-send { padding: 2px 10px; font-size: 0.8125rem; }
.poll-lock, .poll-state { font-size: 0.75rem; color: var(--color-muted); }
.poll-state:empty { display: none; }
.poll-answers {
  margin: 4px 0 0;
  display: flex;
  flex-wrap: wrap;
  gap: 2px 10px;
  font-size: 0.75rem;
  color: var(--color-muted);
  overflow-wrap: anywhere;
}
.poll-answers__label { font-weight: 600; }
/* SPL-1654: the Go button is the shared .btn (the omnibox Go's fill, shape
   and icon placement), a step smaller; green with a black play icon (owner
   28af126d). Focus keeps the one global ring. */
.poll-go-row {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 2px;
  margin-top: 2px;
}
.poll-go.btn {
  display: inline-flex;
  align-items: center;
  gap: 0.375rem;
  min-height: 0;
  padding: 0.25rem 0.75rem 0.25rem 0.5rem;
  font-size: 0.8125rem;
  background: var(--color-ok);
  /* owner 28af126d: a BLACK play icon (and text) in every theme */
  color: black;
}
.poll-go.btn[aria-pressed='false']:not(:disabled):hover,
.poll-go.btn[aria-pressed='false']:active { background: var(--color-ok); filter: brightness(1.12); }
/* done: pressed in, with the check mark */
.poll-go.btn[aria-pressed='true'] {
  background: var(--color-ok);
  box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.4);
  cursor: default;
}
.poll-q:disabled .poll-go.btn { opacity: 0.55; cursor: default; }
.poll-chat-link {
  padding: 0;
  border: 0;
  background: none;
  color: var(--color-muted);
  font-size: 0.75rem;
  font-style: italic;
  text-decoration: underline;
}
/* a finger needs a taller row than a mouse */
@media (pointer: coarse) {
  .poll-opt { padding: 6px 0; }
  .poll-opt__input { width: 18px; height: 18px; }
  .poll-go.btn { min-height: 2rem; }
  .poll-chat-link { padding: 0.25rem 0; }
}
</style>
