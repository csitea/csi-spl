<!-- Spec 153 section 3.18 (SPL-4810; owner HUM-10, t1 27162335, msgs
     038fa412, 8dd53bd9 and 3b2ba6f3): one lane in a modal dialog, opened from
     its row on Monitoring -> Lanes, the way an issue opens from the Issues
     sheet (UiDialog: Esc, X, backdrop close, focus handed back). The lane's
     fields (the page renders them, so the words match its columns), and at
     the end the Console button: pressed, the feed shows that lane's tmux
     screen plus its scrollback as the box captured it, masked on the box.
     The feed watches the lane (POST, again every CONSOLE_WATCH_MS) and reads
     the last capture every CONSOLE_POLL_MS while the browser tab is visible;
     Pause stops both, closing the dialog ends them. Follow keeps the bottom
     in view. Save writes exactly the shown lines to a local .txt. Loaded
     lazily by the Lanes page: the dialog is never in the first chunk. -->
<template>
  <UiDialog :open="open" :title="title" size="lg" @update:open="onOpen">
    <div class="ld" data-test="lane-dialog">
      <dl class="ld-fields">
        <template v-for="f in fields" :key="f.test">
          <dt>{{ f.label }}</dt>
          <dd :data-test="'lane-dialog-' + f.test">{{ f.value }}</dd>
        </template>
      </dl>

      <div class="ld-console-bar">
        <button
          v-if="canConsole"
          type="button"
          class="btn"
          :aria-pressed="showing ? 'true' : 'false'"
          :aria-controls="feedId"
          data-test="lane-console-toggle"
          @click="toggle()"
        >
          <UiIcon name="server" class="mh-icon" />{{ showing ? t('monitoring.lanes.console.hide') : t('monitoring.lanes.console.show') }}
        </button>
        <p v-else class="muted" data-test="lane-console-none">{{ t('monitoring.lanes.console.not_live') }}</p>
      </div>

      <section v-if="showing" :id="feedId" class="ld-console" data-test="lane-console">
        <div class="ld-console-tools">
          <span class="ld-status" :data-state="feed.state" role="status" data-test="lane-console-status">{{ statusText }}</span>
          <span v-if="feed.redacted" class="muted" data-test="lane-console-redacted">{{ t('monitoring.lanes.console.redacted', { n: feed.redacted }, feed.redacted) }}</span>
          <label class="ld-check"><input v-model="follow" type="checkbox" data-test="lane-console-follow">{{ t('monitoring.lanes.console.follow') }}</label>
          <button type="button" class="btn ghost" :aria-pressed="paused ? 'true' : 'false'" data-test="lane-console-pause" @click="togglePause()">
            {{ paused ? t('monitoring.lanes.console.resume') : t('monitoring.lanes.console.pause') }}
          </button>
          <button type="button" class="btn" :disabled="!feed.screen" data-test="lane-console-save" @click="save()">
            <UiIcon name="file-text" class="mh-icon" />{{ t('monitoring.lanes.console.save') }}
          </button>
        </div>
        <p v-if="error" class="ld-error" role="alert" data-test="lane-console-error">{{ error }}</p>
        <pre
          ref="screenEl"
          class="ld-screen"
          tabindex="0"
          :aria-label="t('monitoring.lanes.console.label', { lane: title })"
          data-test="lane-console-screen"
          @scroll="onScroll"
        >{{ feed.screen }}</pre>
      </section>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { CONSOLE_POLL_MS, CONSOLE_WATCH_MS, laneConsoleFileName, laneConsoleFileText, laneConsoleOf, laneConsoleSave } from '~/utils/monitoring-lane-console.mjs'

type Field = { label: string, value: string, test: string }
type ConsoleApi = { laneConsole: (q: { own: boolean, watch: boolean, agentId: string, agentBox: string }) => Promise<unknown> }

const props = defineProps<{
  open: boolean
  /** the dialog's title: the lane's <id>@<box> */
  title: string
  agentId: string
  /** '' when the reader's door does not name it */
  agentBox: string
  /** a live lane has a console; a queued one has none */
  live: boolean
  /** the workspace door (the page read /v1/view/lanes) */
  own: boolean
  fields: Field[]
}>()
const emit = defineEmits<{ close: [] }>()
const { t } = useI18n({ useScope: 'global' })

const feedId = useId()
const canConsole = computed(() => props.live)
const showing = ref(false)
const paused = ref(false)
const follow = ref(true)
const feed = ref(laneConsoleOf(null))
const error = ref('')
const screenEl = ref<HTMLElement | null>(null)

const statusText = computed(() => {
  if (feed.value.state === 'live') return t('monitoring.lanes.console.live', { n: feed.value.ageS })
  if (feed.value.state === 'stale') return t('monitoring.lanes.console.stale', { n: feed.value.ageS })
  return t('monitoring.lanes.console.waiting')
})

let pollTimer: ReturnType<typeof setInterval> | null = null
let watchTimer: ReturnType<typeof setInterval> | null = null
let seq = 0

async function read(watch: boolean) {
  const mine = ++seq
  try {
    const api = useSpoolApi() as unknown as ConsoleApi
    const body = await api.laneConsole({ own: props.own, watch, agentId: props.agentId, agentBox: props.agentBox })
    if (mine !== seq || !showing.value) return
    feed.value = laneConsoleOf(body)
    error.value = ''
    if (follow.value) {
      await nextTick()
      if (screenEl.value) screenEl.value.scrollTop = screenEl.value.scrollHeight
    }
  } catch (e) {
    if (mine !== seq) return
    const status = (e as { status?: number })?.status
    if (status === 403) error.value = t('monitoring.lanes.console.forbidden')
    else if (status === 404) error.value = t('monitoring.lanes.console.gone')
    else error.value = t('monitoring.lanes.console.error')
  }
}

function visible() {
  return typeof document === 'undefined' || document.visibilityState === 'visible'
}

function start() {
  stop()
  void read(true)
  pollTimer = setInterval(() => { if (visible()) void read(false) }, CONSOLE_POLL_MS)
  watchTimer = setInterval(() => { if (visible()) void read(true) }, CONSOLE_WATCH_MS)
}

function stop() {
  if (pollTimer) clearInterval(pollTimer)
  if (watchTimer) clearInterval(watchTimer)
  pollTimer = watchTimer = null
  seq++
}

function toggle() {
  showing.value = !showing.value
  paused.value = false
  if (showing.value) start()
  else stop()
}

function togglePause() {
  paused.value = !paused.value
  if (paused.value) stop()
  else start()
}

/* scrolling up turns Follow off; back at the bottom turns it on */
function onScroll() {
  const el = screenEl.value
  if (!el) return
  follow.value = el.scrollHeight - el.scrollTop - el.clientHeight < 8
}

function save() {
  laneConsoleSave(laneConsoleFileName(props.agentId, props.agentBox), laneConsoleFileText(feed.value.screen))
}

function reset() {
  stop()
  showing.value = paused.value = false
  follow.value = true
  feed.value = laneConsoleOf(null)
  error.value = ''
}

function onOpen(v: boolean) {
  if (!v) {
    reset()
    emit('close')
  }
}

watch(() => [props.open, props.agentId, props.agentBox], () => reset())
onBeforeUnmount(stop)
</script>

<style scoped>
.ld { display: flex; flex-direction: column; gap: 14px; min-width: 0; padding: 12px 16px 16px; }
.ld-fields { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 6px 16px; margin: 0; font-size: 0.875rem; }
.ld-fields dt { color: var(--color-muted); }
.ld-fields dd { margin: 0; overflow-wrap: anywhere; }
.ld-console-bar { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.ld-console { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.ld-console-tools { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; font-size: 0.875rem; }
.ld-status[data-state="stale"] { color: var(--color-warn); }
.ld-status[data-state="waiting"] { color: var(--color-muted); }
.ld-check { display: inline-flex; align-items: center; gap: 4px; }
.ld-error { color: var(--color-danger); margin: 0; }
/* the screen as the terminal shows it: monospace, the box's line breaks kept, a
   long line wrapped inside the dialog, never a page scroll */
.ld-screen {
  margin: 0;
  padding: 8px 10px;
  max-height: 60vh;
  overflow: auto;
  font-family: var(--font-mono);
  font-size: 0.8125rem;
  line-height: 1.35;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm, 6px);
  background: var(--color-surface-hover);
}
</style>
