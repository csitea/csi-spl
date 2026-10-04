<!-- "Keyboard shortcuts" (Settings → Behaviour, HUM-10 topic ae2e5093): the
     signed-in human's switch for the message Shift + letter keys and their
     hints in the right-click menu (composables/useMsgShortcuts.ts). The hub
     keeps it per workspace (PUT /api/v1/auth/preferences keyboard_shortcuts)
     and answers it as the `keyboard_shortcuts` session claim; never picked =
     on. Optimistic like the Debug pane: the claim flips as the box is clicked
     and flips back with a status line when the hub refuses the save. -->
<template>
  <div v-if="signedIn" class="kbd-setting" data-test="keyboard-shortcuts-setting">
    <label class="kbd-setting__row">
      <input
        type="checkbox"
        data-testid="settings-keyboard-shortcuts"
        :aria-describedby="hintId"
        :checked="on"
        :disabled="saving"
        @change="toggle(($event.target as HTMLInputElement).checked)"
      />
      <span class="kbd-setting__label">{{ t('settings.keyboard_shortcuts.label') }}</span>
    </label>
    <p :id="hintId" class="muted kbd-setting__hint">{{ t('settings.keyboard_shortcuts.hint') }}</p>
    <p v-if="status" class="kbd-setting__status" role="status" aria-live="polite" data-testid="settings-keyboard-shortcuts-status">{{ status }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { useSettingSave } from '~/composables/useSettingSave'
import { applyDebugPaneSetting } from '~/utils/debug-pane.mjs'
import { shortcutsOn } from '~/utils/msg-shortcuts.mjs'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const auth = useAuthClient()

const hintId = useId()
const signedIn = computed(() => session.state === 'in')
const on = computed(() => shortcutsOn(session.claims?.keyboard_shortcuts))
const { saving, status, run } = useSettingSave()

/* the Debug pane's optimistic boolean save, unchanged: flip, save, revert on a refusal */
function toggle(want: boolean) {
  return run(() => applyDebugPaneSetting(want, {
    current: on.value,
    apply: (v: boolean) => session.setKeyboardShortcuts(v),
    save: (v: boolean) => auth.saveKeyboardShortcuts(v),
  }))
}

onMounted(() => { if (session.state === 'loading') void session.probe() })
</script>

<style scoped>
.kbd-setting {
  display: grid;
  gap: 4px;
  min-width: 0;
  max-width: 100%;
}
.kbd-setting__row {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: var(--tap, 44px);
  cursor: pointer;
}
.kbd-setting__label {
  font-weight: 600;
}
.kbd-setting__hint,
.kbd-setting__status {
  margin: 0;
  overflow-wrap: anywhere;
}
.kbd-setting__status {
  color: var(--color-error);
}
</style>
