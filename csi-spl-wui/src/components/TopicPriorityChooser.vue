<!-- Spec 150 row B7 (owner HUM-10, t1 0344254d msg f5ed1396: "some kind of
     small row of 1..5 radio buttons whith default 3 and one would have to
     click on 1 to make the prio 1"): the open topic's priority, one row of
     native radios in one named group (Tab lands on the group, the arrows
     move), the current value checked. A click saves at once; a failed save
     puts the old value back and says why. The value comes from the client
     (topicPriorityOf: the pane's own topic read, a set, a `topic_priority`
     frame), so the chooser does no read of its own. -->
<template>
  <div class="topic-prio" data-testid="topic-priority" :data-priority="value" :title="t('topic.priority.hint')">
    <span :id="labelId" class="topic-prio__label">{{ t('topic.priority.label') }}</span>
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
    <span v-if="note" class="topic-prio__note" :class="{ 'topic-prio__note--err': failed }" role="status" data-testid="topic-priority-note">{{ note }}</span>
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

watch(() => props.taskId, (id) => {
  value.value = topicPriority(api.topicPriorityOf(id))
  note.value = ''
  failed.value = false
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
  } catch (e) {
    value.value = old
    failed.value = true
    note.value = t('topic.priority.failed', { token: String((e as { token?: string })?.token || (e as { status?: number })?.status || '') })
  } finally {
    saving.value = false
  }
}
</script>

<style scoped>
.topic-prio {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px 8px;
  padding: 4px 12px;
  font-size: 0.875rem;
  color: var(--color-muted);
}
.topic-prio__group {
  display: inline-flex;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  overflow: hidden;
}
.topic-prio__opt {
  position: relative;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 2em;
  padding: 2px 6px;
  cursor: pointer;
}
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
.topic-prio__note--err { color: var(--color-danger); }
/* on a phone each value is a 44 px target */
@media (max-width: 820px) {
  .topic-prio__opt { min-width: var(--tap); min-height: var(--tap); }
}
</style>
