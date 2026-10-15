<!-- SPL-1991: Monitoring -> Agents (v1). A thin list over the roster the
     sidebar's Agents section reads, each row opening today's card at
     /agents/<id@box>. The AgentCard extraction is the next lane's. -->
<template>
  <div class="monitoring-list" data-test="monitoring-agents">
    <p v-if="rows.length === 0" class="muted monitoring-empty" data-test="monitoring-agents-empty">{{ t('agents.none') }}</p>
    <div v-for="a in rows" :key="a.label" class="nav-row">
      <NuxtLink
        class="nav-item"
        :data-key="a.label"
        :data-online="a.online ? '1' : '0'"
        :to="localePath('/agents/' + encodeURIComponent(a.label))"
      >
        <UiIcon name="bot" :size="20" />
        <span class="dot" :class="{ on: a.online }" />
        <HumanName class="label" :id="a.id" :box="a.box" stacked />
        <span class="muted monitoring-kind">{{ t(a.kindKey) }}</span>
      </NuxtLink>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useRosterStore } from '~/stores/roster'
import { agentKindLabelKey, isAgentId } from '~/utils/agent-kind.mjs'

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const roster = useRosterStore()
const rows = computed(() => roster.people
  .filter((p) => isAgentId(p.id))
  .map((p) => ({ ...p, kindKey: agentKindLabelKey(p.id) })))
</script>

