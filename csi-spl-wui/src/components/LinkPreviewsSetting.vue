<!-- "Link previews" (Settings -> Behaviour, owner prd t1 topic e1f8f797): the
     signed-in person's OWN switch for the small card under a message that
     links a topic or a message of the workspace (LinkPreviews.vue). It
     affects only this person; it is not a workspace setting. The hub keeps
     it on the account (PUT /api/v1/auth/preferences link_previews, rdb 0120,
     per workspace when set there) and answers it as the `link_previews`
     session claim; never picked = on. Optimistic like the Keyboard shortcuts
     box: the claim flips as the box is clicked and flips back with a status
     line when the hub refuses the save. -->
<template>
  <div v-if="signedIn" class="lp-setting" data-test="link-previews-setting">
    <label class="lp-setting__row">
      <input
        type="checkbox"
        data-testid="settings-link-previews"
        :aria-describedby="hintId"
        :checked="on"
        :disabled="saving"
        @change="toggle(($event.target as HTMLInputElement).checked)"
      />
      <span class="lp-setting__label">{{ t('settings.link_previews.label') }}</span>
    </label>
    <p :id="hintId" class="muted lp-setting__hint">{{ t('settings.link_previews.hint') }}</p>
    <p v-if="status" class="lp-setting__status" role="status" aria-live="polite" data-testid="settings-link-previews-status">{{ status }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { useSettingSave } from '~/composables/useSettingSave'
import { applyDebugPaneSetting } from '~/utils/debug-pane.mjs'
import { parseLinkPreviews } from '~/utils/link-preview.mjs'

/* saveViewPref's key list is typed in mjs-shims.d.ts; the PUT itself takes any key */
type SaveViewPref = (key: string, value: string | null) => Promise<{ ok: boolean, out?: unknown }>

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const auth = useAuthClient()
const save = auth.saveViewPref as unknown as SaveViewPref

const hintId = useId()
const signedIn = computed(() => session.state === 'in')
const on = computed(() => parseLinkPreviews(session.claims?.link_previews) === 'on')
const { saving, status, run } = useSettingSave()

function toggle(want: boolean) {
  return run(() => applyDebugPaneSetting(want, {
    current: on.value,
    apply: (v: boolean) => session.setViewPref('link_previews', v ? 'on' : 'off'),
    save: (v: boolean) => save('link_previews', v ? 'on' : 'off'),
  }))
}

onMounted(() => { if (session.state === 'loading') void session.probe() })
</script>

<style scoped>
.lp-setting {
  display: grid;
  gap: 4px;
  min-width: 0;
  max-width: 100%;
}
.lp-setting__row {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: var(--tap, 44px);
  cursor: pointer;
}
.lp-setting__label {
  font-weight: 600;
}
.lp-setting__hint,
.lp-setting__status {
  margin: 0;
  overflow-wrap: anywhere;
}
.lp-setting__status {
  color: var(--color-error);
}
</style>
