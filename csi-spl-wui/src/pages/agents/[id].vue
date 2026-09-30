<!-- CLE-77794 (owner 2026-09-30, topic 1fc29f99: "for the agents it should be
     clear are they antigravity, claude, grok etc."): an agent's card. Its kind
     (from the id prefix), the box it runs on, its liveness and the box's last
     hello, read from /v1/view/roster. A Message button opens the DM. The hub
     roster carries no model field, so no model line is shown. -->
<template>
  <div class="feed-col" data-test="agent-page">
    <header class="feed-header">
      <MobileBack />
      <h2 class="agent-head">
        <UiIcon name="bot" :size="22" />
        <span>{{ agentId }}</span>
      </h2>
    </header>
    <div class="feed-body">
      <div class="agent-card" data-test="agent-card">
        <div class="agent-card__hero">
          <span class="agent-card__glyph" aria-hidden="true"><UiIcon name="bot" :size="34" /></span>
          <div class="agent-card__heroText">
            <p class="agent-card__name">{{ agentId }}</p>
            <p class="agent-card__kind" data-test="agent-kind">{{ t(kindKey) }}</p>
            <p class="agent-card__status" data-test="agent-status">
              <span class="status-dot" :class="{ on: online }" aria-hidden="true" />
              {{ online ? t('people.online') : t('people.offline') }}
            </p>
          </div>
        </div>
        <dl class="agent-card__facts">
          <dt>{{ t('agents.kind') }}</dt>
          <dd>{{ t(kindKey) }}</dd>
          <dt>{{ t('agents.box') }}</dt>
          <dd data-test="agent-box"><code>{{ box }}</code></dd>
          <dt>{{ t('people.last_seen') }}</dt>
          <dd data-test="agent-last-seen">{{ lastHello }}</dd>
        </dl>
        <div class="agent-card__actions">
          <button type="button" class="btn" data-test="agent-message" @click="message">{{ t('people.message') }}</button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useRosterStore } from '~/stores/roster'
import { agentKindLabelKey } from '~/utils/agent-kind.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'

const route = useRoute()
const roster = useRosterStore()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })

/* the route key is the agent's roster label id@box (a given CLI can run on more
   than one box, so the box is part of the identity). */
const label = computed(() => decodeURIComponent(String(route.params.id || '')))
const agentId = computed(() => label.value.split('@')[0] || label.value)
const box = computed(() => label.value.split('@')[1] || '')
const kindKey = computed(() => agentKindLabelKey(agentId.value))
const online = computed(() => roster.isOnline(agentId.value, box.value))
const boxDetail = computed(() => roster.boxes[box.value] || { online: false, last_hello_at: '' })
const lastHello = computed(() => (boxDetail.value.last_hello_at ? isoDateTime(boxDetail.value.last_hello_at) : t('people.never_seen')))

onMounted(() => { if (!roster.boxes[box.value]) void roster.refresh() })

function message() {
  void navigateTo(localePath('/dm/' + encodeURIComponent(label.value)))
}
</script>

<style scoped>
.agent-head { display: flex; align-items: center; gap: 8px; min-width: 0; }
.agent-card { padding: 16px; max-width: 640px; display: flex; flex-direction: column; gap: 18px; min-width: 0; }
.agent-card__hero { display: flex; align-items: center; gap: 14px; min-width: 0; }
.agent-card__glyph {
  display: inline-flex; align-items: center; justify-content: center;
  width: 56px; height: 56px; border-radius: var(--radius-md); flex-shrink: 0;
  background: color-mix(in srgb, var(--color-accent) 14%, var(--color-surface));
  color: var(--color-accent);
}
.agent-card__heroText { min-width: 0; }
.agent-card__name { margin: 0; font-size: 1.1rem; font-weight: 700; overflow-wrap: anywhere; }
.agent-card__kind { margin: 2px 0 0; font-weight: 600; color: var(--color-accent); }
.agent-card__status { margin: 4px 0 0; display: flex; align-items: center; gap: 6px; color: var(--color-muted); font-size: 0.85rem; }
.status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--color-muted); flex-shrink: 0; }
.status-dot.on { background: var(--color-ok); }
.agent-card__facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 6px 14px; margin: 0; }
.agent-card__facts dt { color: var(--color-muted); font-size: 0.8125rem; }
.agent-card__facts dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
.agent-card__actions { display: flex; gap: 8px; }
@media (max-width: 480px) {
  .agent-card__facts { grid-template-columns: minmax(0, 1fr); gap: 0; }
  .agent-card__facts dd + dt { margin-top: 8px; }
}
</style>
