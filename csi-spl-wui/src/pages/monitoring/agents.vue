<!-- SPL-1991: Monitoring -> Agents (v1). A thin list over the roster, each
     row opening the agent's card at /monitoring/agents/<id@box> (SPL-2075:
     the old Agents section's card, moved here).

     SPL-3399 (owner HUM-10, t1 fb9b6e4b, msgs 4a41a8ce + eaf140eb: "when I
     click on an agent in this view ... I should be able to see on the right
     sight of the same panel this view"): the tab is list + detail. This page
     is the parent route of agents/index.vue (no agent: an empty right pane)
     and agents/[id].vue (the card), so the URL still names the agent and a
     link opens the same state; the clicked row stays selected. A phone
     (<= 820 px) keeps the full-page card: the list hides while one is open,
     Back (the header's chevron) returns to it. -->
<template>
  <div class="agents-split" :class="{ 'agents-split--open': selected !== '' }" data-test="monitoring-agents-split">
    <div class="monitoring-list agents-split__list" data-test="monitoring-agents">
      <p v-if="rows.length === 0" class="muted monitoring-empty" data-test="monitoring-agents-empty">{{ t('agents.none') }}</p>
      <div v-for="a in rows" :key="a.label" class="nav-row">
        <NuxtLink
          class="nav-item"
          :class="{ active: a.label === selected }"
          :aria-current="a.label === selected ? 'true' : undefined"
          :data-key="a.label"
          :data-online="a.online ? '1' : '0'"
          :to="localePath('/monitoring/agents/' + encodeURIComponent(a.label))"
        >
          <UiIcon name="bot" :size="20" />
          <span class="dot" :class="{ on: a.online }" />
          <HumanName class="label" :id="a.id" :box="a.box" stacked />
          <span class="muted monitoring-kind">{{ t(a.kindKey) }}</span>
        </NuxtLink>
      </div>
    </div>
    <div class="agents-split__detail" data-test="monitoring-agent-detail">
      <NuxtPage />
    </div>
  </div>
</template>

<script setup lang="ts">
import { useRosterStore } from '~/stores/roster'
import { agentKindLabelKey, isAgentId } from '~/utils/agent-kind.mjs'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const roster = useRosterStore()
const rows = computed(() => roster.people
  .filter((p) => isAgentId(p.id))
  .map((p) => ({ ...p, kindKey: agentKindLabelKey(p.id) })))
/* the open card's roster label id@box ('' on /monitoring/agents) */
const selected = computed(() => decodeURIComponent(String(route.params.id || '')))
</script>

<style scoped>
.agents-split {
  display: grid;
  grid-template-columns: minmax(220px, 340px) minmax(0, 1fr);
  align-items: start;
  min-width: 0;
}
.agents-split__list { min-width: 0; border-right: 1px solid var(--color-border); }
.agents-split__detail { min-width: 0; }
@media (max-width: 820px) {
  .agents-split { grid-template-columns: minmax(0, 1fr); }
  .agents-split__list { border-right: 0; }
  .agents-split--open .agents-split__list { display: none; }
  .agents-split:not(.agents-split--open) .agents-split__detail { display: none; }
}
</style>
