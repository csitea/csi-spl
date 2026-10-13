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
      <div v-if="q.kind === 'button'" class="poll-opt-button">
        <button
          type="button"
          class="poll-go composer-go"
          data-testid="poll-go-button"
          :data-key="q.options[0].key"
          :class="{ 'poll-go--sent': (picks[qi] || []).includes(q.options[0].key) }"
          @click="onPick(qi, q.options[0].key, true)"
        >
          <UiIcon name="go" :size="20" />
          <span class="poll-go__text">{{ q.options[0].text }}</span>
        </button>
      </div>
      <template v-else>
        <label v-for="o in q.options" :key="o.key" class="poll-opt" data-testid="poll-option" :data-key="o.key">
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
            :checked="false"
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
import type { PollShape } from '~/components/PollBody.vue'
import type { SpoolMessage } from '~/types/spool'

/* SPL-1637 poll-control (owner HUM-10, t1 aab3d88b). One form per message.
   A radio click posts the answer at once, fire and forget (owner 87b56449);
   a checkbox form locks in 45 s per question after its first click, or on
   its Send (owner 8f0da7ca). The answer is a plain reply in the form's topic
   whose marker agents parse (utils/poll.mjs); it carries the sender's whole
   current form, so re-answering replaces. Native inputs at text size (owner
   f20e1dc1: not too big), labels the click target, Tab / arrows / Space as
   the browser gives them. */
const props = defineProps<{ form: PollShape }>()
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
  if (mine) picks.value = props.form.questions.map((_, i) => (mine.picks[i + 1] || []).slice())
}, { immediate: true })

const state = ref<'' | 'sent' | 'failed'>('')
async function post() {
  const m = msg.value
  if (!m || !canAnswer.value) return
  const text = answerBody(props.form, picks.value, msgId.value)
  state.value = ''
  try {
    await channel.send(text, String(m.task_id), [], m.channel ? String(m.channel) : undefined, 0, m.channel ? undefined : (dmPeerOf(m, me.value) || undefined))
    state.value = 'sent'
  } catch {
    state.value = 'failed'
  }
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

function onPick(qi: number, key: string, on: boolean) {
  dirty.value = true
  const next = picks.value.map((p) => p.slice())
  if (props.form.multi) next[qi] = on ? [...new Set([...next[qi], key])].sort() : next[qi].filter((k) => k !== key)
  else next[qi] = [key]
  picks.value = next
  state.value = ''
  if (props.form.multi) arm()
  else void post()
}

const formEl = ref<HTMLFormElement | null>(null)
/* "Chat about this": the topic opens, the reply box takes the caret with the
   marker and the question quoted; the reader's picks stay as they were */
function onChat(qi: number, input: HTMLInputElement) {
  input.checked = false
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
  color: var(--color-fg-muted);
  overflow-wrap: anywhere;
}
.poll-answers__label { font-weight: 600; }
/* Go button: reuse omnibox Go button styles, smaller, greenish, black play icon */
.poll-go {
  background: var(--color-accent);
  color: var(--color-accent-fg);
  border: 0;
  border-radius: var(--radius-sm);
  padding: 6px 12px;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 0.875rem;
  font-weight: 600;
  cursor: pointer;
  margin: 2px 0;
}
.poll-go:hover:not(:disabled),
.poll-go:focus-visible:not(:disabled) {
  background: color-mix(in srgb, var(--color-accent) 82%, #000);
  color: var(--color-accent-fg);
}
.poll-go:active:not(:disabled) {
  background: var(--color-accent-pressed);
  color: var(--color-fg);
}
.poll-go--sent {
  background: var(--color-selected);
  color: var(--color-fg);
}
.poll-go__text {
  margin-top: 1px;
}

/* a finger needs a taller row than a mouse */
@media (pointer: coarse) {
  .poll-opt { padding: 6px 0; }
  .poll-opt__input { width: 18px; height: 18px; }
}
</style>
