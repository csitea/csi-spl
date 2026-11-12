<!-- Spec 150 row B7 (owner HUM-10, t1 0344254d msg f5ed1396: "some kind of
     small row of 1..5 radio buttons whith default 3 and one would have to
     click on 1 to make the prio 1"): the open topic's priority, one row of
     native radios in one named group (Tab lands on the group, the arrows
     move), the current value checked. A click saves at once; a failed save
     puts the old value back and says why. The value comes from the client
     (topicPriorityOf: the pane's own topic read, a set, a `topic_priority`
     frame), so the chooser does no read of its own.
     SPL-5349 (owner HUM-10, t1 2fafde5c, option A of the mocks): the bar sits
     on the topic header's second row, left, at the card-size control's size;
     a saved pick is a short "✓ N" right of the bar that fades out in under
     1 s and takes no room; screen readers hear the whole sentence. A failed
     save keeps its line, so the reason stays readable. -->
<template>
  <div class="topic-prio" data-testid="topic-priority" :data-priority="value" :title="t('topic.priority.hint')">
    <span :id="labelId" class="topic-prio__label">{{ t('topic.priority.short') }}</span>
    <div class="topic-prio__group" role="radiogroup" :aria-labelledby="labelId">
      <label
        v-for="n in LEVELS"
        :key="n"
        class="topic-prio__opt"
        :class="{ 'topic-prio__opt--on': value === n }"
      >
        <input
          type="radio"
          :name="name"
          :value="n"
          :checked="value === n"
          :disabled="saving"
          :data-testid="`topic-priority-${n}`"
          @change="choose(n)"
        />
        <span>{{ n }}</span>
      </label>
    </div>
    <span v-if="okShown" class="topic-prio__ok" aria-hidden="true" data-testid="topic-priority-ok">{{ okValue }}</span>
    <span class="topic-prio__note" :class="{ 'topic-prio__note--err': failed, 'sr-only': !failed }" role="status" data-testid="topic-priority-note">{{ note }}</span>
  </div>
</template>

<script setup lang="ts">
import { TOPIC_PRIORITY_DEFAULT, topicPriority } from '~/utils/topic-list-order.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'

const LEVELS = [1, 2, 3, 4, 5]

const props = defineProps<{ taskId: string }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
/* one radio group per control on the page */
const name = `topic-prio-${useId()}`
const labelId = `${name}-label`
const value = ref<number>(TOPIC_PRIORITY_DEFAULT)
const saving = ref(false)
const failed = ref(false)
const note = ref('')
/* the visible "✓ N": shown on a saved pick, gone under 1 s (CSS fades it) */
const OK_MS = 800
const okShown = ref(false)
const okValue = ref(0)
let okTimer: ReturnType<typeof setTimeout> | undefined
function flashOk(n: number) {
  clearTimeout(okTimer)
  okValue.value = n
  okShown.value = false
  nextTick(() => {
    okShown.value = true
    okTimer = setTimeout(() => { okShown.value = false }, OK_MS)
  })
}
onUnmounted(() => clearTimeout(okTimer))

watch(() => props.taskId, (id) => {
  value.value = topicPriority(api.topicPriorityOf(id))
  note.value = ''
  failed.value = false
  okShown.value = false
}, { immediate: true })

/* the pane's read, this tab's set, another tab's frame */
const offNoted = api.onTopicPriority((id, p) => {
  if (id === props.taskId && !saving.value) value.value = p
})
onUnmounted(offNoted)
if (import.meta.client && !api.mock) {
  const offFrame = useLive().onTopic((f) => {
    if (f.type === 'topic_priority') api.noteTopicPriority(String(f.task_id || ''), f.priority)
  })
  onUnmounted(offFrame)
}

async function choose(n: number) {
  const old = value.value
  if (n === old || saving.value) return
  value.value = n
  saving.value = true
  try {
    await api.setTopicPriority(props.taskId, n)
    failed.value = false
    note.value = t('topic.priority.saved', { n })
    flashOk(n)
  } catch (e) {
    value.value = old
    failed.value = true
    okShown.value = false
    note.value = t('topic.priority.failed', { token: String((e as { token?: string })?.token || (e as { status?: number })?.status || '') })
  } finally {
    saving.value = false
  }
}
</script>

<style scoped>
/* SPL-5349: the size of the card-size control (CardClipControl), cells
   26 x 16 px on the desktop and 35 x 30 on a phone */
.topic-prio {
  position: relative;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px 6px;
  font-size: 0.75rem;
  /* the label no taller than the bar: the header row keeps its height
     when the lazy chooser mounts */
  line-height: 1;
  color: var(--color-muted);
}
.topic-prio__group {
  display: inline-flex;
  font-size: 0.75rem;
  line-height: 1;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
}
.topic-prio__opt {
  position: relative;
  box-sizing: border-box;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 26px;
  height: 16px;
  cursor: pointer;
}
.topic-prio__opt:first-child { border-start-start-radius: var(--radius-pill); border-end-start-radius: var(--radius-pill); }
.topic-prio__opt:last-child { border-start-end-radius: var(--radius-pill); border-end-end-radius: var(--radius-pill); }
.topic-prio__opt + .topic-prio__opt { border-inline-start: 1px solid var(--color-border); }
.topic-prio__opt--on {
  background: var(--color-selected);
  color: var(--color-fg);
  font-weight: 600;
}
/* the radio stays in the tab order and the accessibility tree, drawn by its label */
.topic-prio__opt input {
  position: absolute;
  inset: 0;
  margin: 0;
  opacity: 0;
  cursor: pointer;
}
.topic-prio__opt:has(input:focus-visible) {
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: calc(-1 * var(--focus-ring-w));
}
/* right of the bar, out of the flow: no row height, nothing jumps */
.topic-prio__ok {
  position: absolute;
  inset-inline-start: 100%;
  margin-inline-start: 6px;
  font-weight: 600;
  white-space: nowrap;
  color: var(--color-ok);
  animation: topic-prio-ok 750ms ease-in forwards;
}
.topic-prio__ok::before { content: '\2713\00a0'; }
@keyframes topic-prio-ok {
  0%, 55% { opacity: 1; }
  100% { opacity: 0; }
}
@media (prefers-reduced-motion: reduce) {
  .topic-prio__ok { animation: none; }
}
.topic-prio__note--err { flex-basis: 100%; color: var(--color-danger); }
/* on a phone each value keeps a 44 px tall target: its radio, invisible,
   stands out of the drawn cell */
@media (max-width: 820px) {
  .topic-prio { font-size: 0.8125rem; }
  .topic-prio__group { font-size: 0.875rem; }
  .topic-prio__opt { width: 35px; height: 30px; }
  /* near-square: a 50% round radio is hit-tested as an ellipse, 4-6 px wide
     near its top and bottom (R7 c-611, W1); the smallest token radius */
  .topic-prio__opt input {
    inset: 50% 0 auto;
    height: var(--tap);
    transform: translateY(-50%);
    appearance: none;
    border-radius: var(--radius-xs);
  }
}
</style>
