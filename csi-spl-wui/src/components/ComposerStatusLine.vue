<!-- Spec 096 §5.1: the composer's one inline line when the DM peer or a
     member the draft @mentions has set Busy or Unavailable. Read before
     sending; never a dialog, never blocks the send, nothing is auto-replied
     (Q4). Busy is the softer colour (Q3). -->
<template>
  <ul v-if="i18nReady && rows.length" class="composer-status-line" data-testid="composer-status-line" role="status">
    <li
      v-for="row in rows"
      :key="row.id"
      class="composer-status-line__row"
      :data-state="row.state"
      data-testid="composer-status-row"
    >
      <span class="dot" :class="'dot--' + row.state" aria-hidden="true" />
      <span class="composer-status-line__text"><strong>{{ row.head }}</strong><template v-if="row.note"> · {{ row.note }}</template></span>
    </li>
  </ul>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useHumanNames } from '~/composables/useHumanNames'
import { useRosterStore } from '~/stores/roster'
import { useHumanStatusStore } from '~/stores/human-status'
import { composerStatusTargets, draftMentionIds, liveStatus, statusUntilLabel } from '~/utils/human-status.mjs'

/* dmPeer: the DM this box sends to ('' when none); text: the draft */
const props = defineProps<{ dmPeer: string, text: string }>()
const { t, te } = useI18n({ useScope: 'global' })
/* its words are in the second catalogue (i18n-first-screen ON_DEMAND_COMPONENTS),
   merged when the browser is first idle (plugins/i18n-more.client.ts): shown once there */
const i18nReady = computed(() => te('status_edit.line_busy'))
const names = useHumanNames()
const roster = useRosterStore()
const status = useHumanStatusStore()

/* whom the line names: the DM peer, then every member the draft @mentions */
const targets = computed(() => {
  const people = props.text.includes('@')
    ? roster.peers.filter((p) => /^HUM-/.test(p.id)).map((p) => ({ id: p.id, name: names.label(p.id, p.box) }))
    : []
  return composerStatusTargets({ dmPeer: props.dmPeer, mentionIds: draftMentionIds(props.text, people), selfId: roster.self?.id || '', statusOf: (id: string) => liveStatus(status.statusByPeer[id] || null) })
})

const rows = computed(() => targets.value.map(({ id, status }) => {
  const when = statusUntilLabel(status.until)
  const name = names.label(id)
  return {
    id,
    state: status.state,
    note: status.note,
    head: t(`status_edit.line_${status.state}${when ? '_until' : ''}`, when ? { name, when } : { name }),
  }
}))
</script>

<style scoped>
.composer-status-line {
  list-style: none;
  margin: 0 0 6px;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
  max-width: 100%;
  font-size: 0.8125rem;
}
.composer-status-line__row {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
  padding: 2px 8px;
  border-radius: var(--radius-sm);
  border-inline-start: 3px solid var(--color-danger);
  color: var(--color-fg);
}
/* Q3: Busy reads softer than Unavailable */
.composer-status-line__row[data-state=busy] {
  border-inline-start-color: var(--color-warn);
  color: var(--color-muted);
}
.composer-status-line__row .dot { background: transparent; }
.composer-status-line__text {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>
