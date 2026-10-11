<!-- Shift + ? (HUM-10 topic ae2e5093): every message keyboard shortcut in one
     small list. The keys come from utils/msg-shortcuts.mjs, the one map the
     listener reads too, so the list cannot drift from what the keys do. -->
<template>
  <UiDialog v-model:open="open" :title="t('feed.shortcuts.title')" size="sm">
    <dl class="kbd-help" data-testid="msg-shortcuts-help">
      <template v-for="s in MSG_SHORTCUTS" :key="s.key">
        <dt><kbd>⇧</kbd> <kbd>{{ s.key }}</kbd></dt>
        <dd :data-testid="'msg-shortcuts-help-' + s.key">{{ t(s.labelKey) }}</dd>
      </template>
      <template v-for="n in NAV_SHORTCUTS" :key="n.labelKey">
        <dt><template v-for="(k, i) in n.keys" :key="k"><span v-if="i"> </span><kbd>{{ k }}</kbd></template></dt>
        <dd>{{ t(n.labelKey) }}</dd>
      </template>
    </dl>
    <!-- HUM-10 (t1 aedca86a): the selected issue row takes the same keys -->
    <h3 class="kbd-help__h">{{ t('feed.shortcuts.issue_rows') }}</h3>
    <dl class="kbd-help" data-testid="issue-shortcuts-help">
      <template v-for="s in ISSUE_SHORTCUTS" :key="s.key">
        <dt><kbd>⇧</kbd> <kbd>{{ s.key }}</kbd></dt>
        <dd :data-testid="'issue-shortcuts-help-' + s.key">{{ t(s.labelKey) }}</dd>
      </template>
    </dl>
  </UiDialog>
</template>

<script setup lang="ts">
import UiDialog from '~/components/UiDialog.vue'
import { ISSUE_SHORTCUTS, MSG_SHORTCUTS, NAV_SHORTCUTS } from '~/utils/msg-shortcuts.mjs'
import { useMsgShortcutsHelp } from '~/composables/useMsgShortcuts'

const { t } = useI18n({ useScope: 'global' })
const open = useMsgShortcutsHelp()
</script>

<style scoped>
.kbd-help {
  display: grid;
  grid-template-columns: max-content minmax(0, 1fr);
  gap: 6px 16px;
  margin: 0;
  align-items: baseline;
}
.kbd-help dt { white-space: nowrap; }
.kbd-help__h { margin: 16px 0 8px; font-size: 0.8125rem; font-weight: 600; color: var(--color-muted); }
.kbd-help dd { margin: 0; overflow-wrap: anywhere; }
.kbd-help kbd {
  display: inline-block;
  min-width: 1.6em;
  padding: 0 4px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  font-family: inherit;
  font-size: 0.75rem;
  text-align: center;
  color: var(--color-muted);
}
</style>
