<!-- "Connect an agent" (W12, spec 047, SPL-1166), in Tenant settings ->
     Agents: the one block to paste on the machine where the agent runs
     (build spool, seat the box with the tenant root key, keep it connected,
     give Claude Code the spool tools), the Cursor mcp.json, and the first
     thing to tell the agent. The lines come from utils/connect-agent.mjs;
     the walk-through is /help/connect-an-agent. Open while no agent is
     seated, a closed "Connect another agent" once one is. B2 (join tokens)
     replaces the root key step later. -->
<template>
  <details class="ca" :open="open" data-test="connect-agent">
    <summary class="ca__summary" data-test="connect-agent-summary">{{ open ? t('connect_agent.title') : t('connect_agent.title_more') }}</summary>
    <p class="muted ca__intro">{{ t('connect_agent.intro') }}</p>
    <div class="ca__fields">
      <label class="ca__field">
        <span>{{ t('connect_agent.agent_id') }}</span>
        <input v-model="agent" type="text" maxlength="12" autocomplete="off" spellcheck="false" data-test="connect-agent-id">
      </label>
      <label class="ca__field">
        <span>{{ t('connect_agent.box_id') }}</span>
        <input v-model="box" type="text" maxlength="32" autocomplete="off" spellcheck="false" data-test="connect-agent-box">
      </label>
      <label class="ca__field ca__field--wide">
        <span>{{ t('connect_agent.key_file') }}</span>
        <input v-model="keyFile" type="text" maxlength="200" autocomplete="off" spellcheck="false" data-test="connect-agent-key">
      </label>
    </div>
    <p v-if="!valid" class="ca__error" role="alert" data-test="connect-agent-invalid">{{ t('connect_agent.invalid') }}</p>
    <ol v-else class="ca__steps">
      <li>
        <p>{{ t('connect_agent.step_paste') }}</p>
        <div v-if="script" data-test="connect-agent-script"><CodeBlock :text="script" lang="bash" /></div>
        <p class="muted ca__small">{{ t('connect_agent.key_hint') }}</p>
      </li>
      <li>
        <p>{{ t('connect_agent.step_lobby', { agent }) }}</p>
      </li>
      <li>
        <p>{{ t('connect_agent.step_prompt') }}</p>
        <div data-test="connect-agent-prompt"><CodeBlock :text="prompt" lang="text" /></div>
      </li>
    </ol>
    <details v-if="valid" class="ca__cursor" data-test="connect-agent-cursor">
      <summary>{{ t('connect_agent.cursor') }}</summary>
      <p class="muted ca__small">{{ t('connect_agent.cursor_hint') }}</p>
      <CodeBlock :text="cursor" lang="json" />
    </details>
    <p class="ca__small">
      <NuxtLink :to="localePath('/help/connect-an-agent')" data-test="connect-agent-help">{{ t('connect_agent.help_link') }}</NuxtLink>
    </p>
  </details>
</template>

<script setup lang="ts">
import CodeBlock from '~/components/CodeBlock.vue'
import { connectAgentScript, cursorMcpJson, firstPrompt, validAgentId, validBoxId } from '~/utils/connect-agent.mjs'
import { normalizeId } from '~/utils/agent-id.mjs'

const props = defineProps<{ tenant: string, hubUrl: string, open: boolean }>()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()

const agent = ref('c-001')
const box = ref('box-laptop')
const keyFile = ref('')
watch(() => props.tenant, (tn) => { if (!keyFile.value) keyFile.value = `~/Downloads/${tn || 'tenant'}.root.key` }, { immediate: true })

/* spec 061: c-004 stays lower case, a legacy id is upper-cased */
const agentId = computed(() => normalizeId(agent.value) || agent.value.trim().toUpperCase())
const boxId = computed(() => box.value.trim().toLowerCase())
const valid = computed(() => validAgentId(agentId.value) && validBoxId(boxId.value) && Boolean(keyFile.value.trim()) && Boolean(props.hubUrl) && Boolean(props.tenant))
/* cnf env.wui.repo_clone_url via /config.json; unset = no block (no fallback repo) */
const repo = String(useRuntimeConfig().public.repoCloneUrl || '')
const script = computed(() => connectAgentScript({ hubUrl: props.hubUrl, tenant: props.tenant, box: boxId.value, agent: agentId.value, keyFile: keyFile.value.trim(), repo }))
const cursor = computed(() => cursorMcpJson({ agent: agentId.value }))
const prompt = computed(() => firstPrompt(agentId.value))
</script>

<style scoped>
.ca { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.ca__summary { cursor: pointer; font-weight: 600; margin-bottom: 8px; }
.ca__intro, .ca__steps p { margin: 0 0 8px; }
.ca__fields { display: flex; flex-wrap: wrap; gap: 10px 14px; margin: 0 0 12px; }
.ca__field { display: flex; flex-direction: column; gap: 4px; min-width: 0; flex: 0 1 160px; }
.ca__field--wide { flex: 1 1 260px; }
.ca__field input {
  min-width: 0;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
  font-family: var(--font-mono, monospace);
}
.ca__steps { margin: 0; padding-inline-start: 1.4em; display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.ca__steps li { min-width: 0; }
.ca__small { font-size: 0.8125rem; margin: 6px 0 0; }
.ca__cursor { margin-top: 12px; }
.ca__cursor summary { cursor: pointer; }
.ca__error { margin: 0; color: var(--color-danger); }
@media (max-width: 820px) {
  .ca__field input { min-height: var(--tap, 44px); }
  .ca__summary { min-height: var(--tap, 44px); display: flex; align-items: center; }
}
</style>
