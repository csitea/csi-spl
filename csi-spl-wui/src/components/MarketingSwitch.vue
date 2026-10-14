<!-- The workspace's marketing switch (spec 090 §15; owner HUM-10, t1
     f0c3927e msg 37bcb88b item 4), inside Tenant settings -> General.
     Shown to an admin of a workspace on the cnf allow-list. Outside it the
     hub answers 404 and the section says so in one line (SPL-1856, owner
     msg d657f49d: a silent gap read as "do I have the wrong role"); a 403
     (a non-admin) still hides it.
     It starts off (owner msg 5cd2e544): nothing is posted until an admin
     turns it on. -->
<template>
  <div v-if="why" class="mk" data-test="tenant-marketing-unavailable">
    <h4 class="mk-title">{{ t('tenant_settings.marketing_title') }}</h4>
    <p class="muted mk-why">{{ t('tenant_settings.marketing_not_available') }}</p>
  </div>
  <div v-else-if="shown" class="mk" data-test="tenant-settings-marketing">
    <h4 class="mk-title">{{ t('tenant_settings.marketing_title') }}</h4>
    <label class="mk-row">
      <input
        type="checkbox"
        :checked="enabled"
        :disabled="busy"
        data-test="tenant-marketing-toggle"
        @change="flip(($event.target as HTMLInputElement).checked)"
      >
      <span>{{ t('tenant_settings.marketing_on') }}</span>
    </label>
    <small class="muted">{{ t('tenant_settings.marketing_hint') }}</small>
    <p v-if="error" class="mk-error" role="alert" data-test="tenant-marketing-error">{{ error }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { marketingSaysWhy, tenantSettingsErrorKey } from '~/utils/tenant-settings.mjs'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
// changed: the switch flipped, so the owner's Publish list re-reads (SPL-1698)
const emit = defineEmits<{ changed: [] }>()

const shown = ref(false)
// SPL-1856: the hub refused with 404, so one line says why there is no switch
const why = ref(false)
const enabled = ref(false)
const busy = ref(false)
const error = ref('')

async function flip(on: boolean) {
  if (busy.value) return
  busy.value = true
  error.value = ''
  try {
    const s = await api.patchMarketingSwitch(on)
    enabled.value = s?.enabled === true
    emit('changed')
  } catch (e) {
    enabled.value = !on
    error.value = t(tenantSettingsErrorKey(e))
  } finally {
    busy.value = false
  }
}

onMounted(async () => {
  try {
    const s = await api.getMarketingSwitch()
    enabled.value = s?.enabled === true
    shown.value = true
  } catch (e) {
    shown.value = false
    why.value = marketingSaysWhy('switch', e)
  }
})
</script>

<style scoped>
.mk { display: flex; flex-direction: column; gap: 4px; margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--color-border); }
.mk-title { margin: 0 0 4px; font-size: 0.875rem; }
.mk-why { margin: 0; }
.mk-row { display: flex; align-items: center; gap: 8px; min-height: var(--tap, 44px); }
.mk-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
</style>
