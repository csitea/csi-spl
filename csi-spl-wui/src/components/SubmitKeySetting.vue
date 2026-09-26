<!-- "Text fields" (SPL-976, Settings → Behaviour): Enter sends, or Enter adds
     a line and Ctrl/Cmd+Enter sends. The hub keeps it per human
     (humans.submit_key, PUT /api/v1/auth/preferences) and answers it as the
     `submit_key` session claim, which every field reads through useSubmitKey.
     Optimistic like the Debug pane: the claim flips as the radio is clicked
     and flips back with a status line when the hub refuses the save. -->
<template>
  <div v-if="signedIn" class="submit-key" data-test="submit-key-setting">
    <span :id="labelId" class="submit-key__label">{{ t('settings.submit_key.label') }}</span>
    <div class="submit-key__opts" role="radiogroup" :aria-labelledby="labelId" :aria-describedby="hintId">
      <label v-for="k in SUBMIT_KEYS" :key="k" class="submit-key__opt" :class="{ 'submit-key__opt--on': mode === k }">
        <input
          type="radio"
          name="submit-key"
          :value="k"
          :checked="mode === k"
          :disabled="saving"
          :data-test="`submit-key-${k}`"
          @change="pick(k)"
        />
        <span>{{ t(k === 'enter' ? 'settings.submit_key.enter' : 'settings.submit_key.ctrl_enter') }}</span>
      </label>
    </div>
    <p :id="hintId" class="muted submit-key__hint">{{ t('settings.submit_key.hint') }}</p>
    <p v-if="status" class="submit-key__status" role="status" aria-live="polite" data-test="submit-key-status">{{ status }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { useAuthCopy } from '~/composables/useAuthCopy'
import { useSubmitKey } from '~/composables/useSubmitKey'
import { SUBMIT_KEYS, applySubmitKeySetting, type SubmitKey } from '~/utils/submit-key.mjs'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const auth = useAuthClient()
const copy = useAuthCopy()
const { mode } = useSubmitKey()

const labelId = useId()
const hintId = useId()
const signedIn = computed(() => session.state === 'in')
const saving = ref(false)
const status = ref('')

async function pick(want: SubmitKey) {
  if (!signedIn.value || saving.value) return
  saving.value = true
  status.value = ''
  const res = await applySubmitKeySetting(want, {
    current: session.claims?.submit_key,
    apply: (k: string) => session.setSubmitKey(k),
    save: (k: string) => auth.saveSubmitKey(k),
  })
  saving.value = false
  if (!res.ok) {
    status.value = copy.nativeError((res.out ?? null) as Parameters<typeof copy.nativeError>[0]) || t('settings.language.failed')
  }
}

onMounted(() => { if (session.state === 'loading') void session.probe() })
</script>

<style scoped>
.submit-key {
  display: grid;
  gap: 6px;
  min-width: 0;
  max-width: 100%;
}
.submit-key__label {
  font-weight: 600;
}
.submit-key__opts {
  display: grid;
  gap: 2px;
}
.submit-key__opt {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: var(--tap, 44px);
  cursor: pointer;
  overflow-wrap: anywhere;
}
.submit-key__opt--on { color: var(--color-accent); }
.submit-key__hint,
.submit-key__status {
  margin: 0;
  overflow-wrap: anywhere;
}
.submit-key__status {
  color: var(--color-error);
}
</style>
