<!-- "Message order", "Omnibox position" (topic c6994436) and "Close
     buttons" (SPL-1133: Mac style top left | Windows style top right) (Settings →
     Behaviour): newest at the top or at the bottom of every message feed and
     thread, and the Omnibox in the top bar or docked at the bottom on tablets
     and computers. The hub keeps each per human (humans.message_order /
     composer_position, PUT /api/v1/auth/preferences) and answers them as
     session claims, which the panes read through useViewPrefs. Optimistic
     like "Text fields": the claim flips as the radio is clicked and flips
     back with a status line when the hub refuses the save. -->
<template>
  <div v-if="signedIn" class="view-prefs" data-test="view-prefs-setting">
    <div v-for="g in groups" :key="g.key" class="view-prefs__group" :data-test="`view-pref-${g.key}`">
      <span :id="`${uid}-${g.key}-label`" class="view-prefs__label">{{ t(`settings.${g.key}.label`) }}</span>
      <div
        class="view-prefs__opts"
        role="radiogroup"
        :aria-labelledby="`${uid}-${g.key}-label`"
        :aria-describedby="`${uid}-${g.key}-hint`"
      >
        <label
          v-for="v in g.values"
          :key="v"
          class="view-prefs__opt"
          :class="{ 'view-prefs__opt--on': g.current === v }"
        >
          <input
            type="radio"
            :name="`view-pref-${g.key}`"
            :value="v"
            :checked="g.current === v"
            :disabled="saving"
            :data-test="`${g.key}-${v}`"
            @change="pick(g.key, v)"
          />
          <span>{{ t(`settings.${g.key}.${v.replace('-', '_')}`) }}</span>
        </label>
      </div>
      <p :id="`${uid}-${g.key}-hint`" class="muted view-prefs__hint">{{ t(`settings.${g.key}.hint`) }}</p>
      <p v-if="status[g.key]" class="view-prefs__status" role="status" aria-live="polite" :data-test="`${g.key}-status`">{{ status[g.key] }}</p>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useAuthCopy } from '~/composables/useAuthCopy'
import { useViewPrefs } from '~/composables/useViewPrefs'
import { CLOSE_BUTTONS, COMPOSER_POSITIONS, MESSAGE_ORDERS, type ViewPrefKey } from '~/utils/view-prefs.mjs'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const copy = useAuthCopy()
const prefs = useViewPrefs()

const uid = useId()
const signedIn = computed(() => session.state === 'in')
const saving = ref(false)
const status = reactive<Record<ViewPrefKey, string>>({ message_order: '', composer_position: '', issues_view: '', close_buttons: '' })

const groups = computed(() => [
  { key: 'message_order' as const, values: MESSAGE_ORDERS as readonly string[], current: prefs.messageOrder.value as string },
  { key: 'composer_position' as const, values: COMPOSER_POSITIONS as readonly string[], current: prefs.composerPosition.value as string },
  /* SPL-1133: Mac style (top left, the default) | Windows style (top right) */
  { key: 'close_buttons' as const, values: CLOSE_BUTTONS as readonly string[], current: prefs.closeButtons.value as string },
])

async function pick(key: ViewPrefKey, want: string) {
  if (!signedIn.value || saving.value) return
  saving.value = true
  status[key] = ''
  let res: Awaited<ReturnType<typeof prefs.save>>
  try {
    res = await prefs.save(key, want)
  } finally {
    saving.value = false
  }
  if (!res.ok) {
    status[key] = copy.nativeError(((res as { out?: unknown }).out ?? null) as Parameters<typeof copy.nativeError>[0]) || t('settings.language.failed')
  }
}

// The settings page can mount before the app's session probe has run; start it here.
onMounted(() => { if (session.state === 'loading') void session.probe() })
</script>

<style scoped>
.view-prefs {
  display: grid;
  gap: 16px;
  min-width: 0;
  max-width: 100%;
}
.view-prefs__group {
  display: grid;
  gap: 6px;
  min-width: 0;
}
.view-prefs__label {
  font-weight: 600;
}
.view-prefs__opts {
  display: grid;
  gap: 2px;
}
.view-prefs__opt {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: var(--tap, 44px);
  cursor: pointer;
  overflow-wrap: anywhere;
}
.view-prefs__opt--on { color: var(--color-accent); }
.view-prefs__hint,
.view-prefs__status {
  margin: 0;
  overflow-wrap: anywhere;
}
.view-prefs__status {
  color: var(--color-error);
}
</style>
