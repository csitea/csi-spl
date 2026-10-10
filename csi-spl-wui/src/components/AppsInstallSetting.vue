<!-- "Apps on this phone" (Settings → Appearance; t1 HUM-10 msg 44200ea2,
     owner pick C+ msg 19bde28c): one row per workspace the signed-in person
     belongs to. Each workspace is its own origin (SPL-959), so each installs
     as its own app, and a browser only installs the origin it shows:
       - this workspace: Install calls the browser's kept install event
         (utils/pwa-install.mjs); "Installed" once it runs as the app;
         without the event (iPhone Safari, Firefox) the manual step instead
       - another workspace: Install opens that workspace's host on this
         section (?settings=appearance&install=1), where its own row installs;
         with tenant hosts off every workspace is this one app. -->
<template>
  <SettingsSection id="settings-apps" :title="t('settings.apps.title')" data-test="settings-apps">
    <p class="muted apps__hint">{{ t('settings.apps.hint') }}</p>
    <ul class="apps__list">
      <li
        v-for="row in rows"
        :key="row.id"
        class="apps__row"
        :data-test="'settings-apps-row-' + row.id"
        :data-current="row.current ? '1' : '0'"
      >
        <span class="apps__name">
          {{ row.label }}<span v-if="row.current" class="muted"> ({{ t('settings.apps.this_one') }})</span>
        </span>
        <template v-if="row.current">
          <span v-if="state.installed" class="apps__done" role="status" data-test="settings-apps-installed">{{ t('settings.apps.installed') }}</span>
          <button
            v-else-if="state.canPrompt"
            ref="installBtn"
            type="button"
            class="btn apps__btn"
            data-test="settings-apps-install"
            @click="install"
          >{{ t('settings.apps.install') }}</button>
          <span v-else class="muted apps__manual" data-test="settings-apps-manual">{{ t('settings.apps.manual') }}</span>
        </template>
        <template v-else>
          <a
            v-if="hrefs[row.id]"
            :href="hrefs[row.id]"
            target="_blank"
            rel="noopener"
            class="btn apps__btn"
            :data-test="'settings-apps-open-' + row.id"
          >{{ t('settings.apps.install') }}</a>
          <span v-else class="muted apps__manual" :data-test="'settings-apps-same-' + row.id">{{ t('settings.apps.same_app') }}</span>
        </template>
      </li>
    </ul>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import { useSessionStore } from '~/stores/session'
import { tenantHostUrl } from '~/composables/useSpoolApi'
import { fixedTenantOption, tenantSwitchOptions } from '~/utils/tenant-switcher.mjs'
import { onPwaInstallChange, promptPwaInstall, pwaInstallState } from '~/utils/pwa-install.mjs'

/** The path another workspace's host opens: this section, install step shown. */
const INSTALL_PATH = '/lobby?settings=appearance&install=1'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const api = useSpoolApi()
const route = useRoute()

const state = ref(pwaInstallState())
const hrefs = ref<Record<string, string>>({})
const installBtn = ref<HTMLButtonElement[] | HTMLButtonElement | null>(null)

const rows = computed(() => {
  const here = fixedTenantOption(session.claims, api.tenant).id
  const opts = tenantSwitchOptions(session.claims, api.tenant).options
    .filter((o: { id: string }) => o.id)
  return opts.map((o: { id: string, label: string }) => ({ ...o, current: o.id === here }))
    .sort((a: { current: boolean }, b: { current: boolean }) => Number(b.current) - Number(a.current))
})

async function install() {
  await promptPwaInstall()
}

let off: (() => void) | null = null
onMounted(async () => {
  state.value = pwaInstallState()
  off = onPwaInstallChange((s: { canPrompt: boolean, installed: boolean }) => { state.value = s })
  const found: Record<string, string> = {}
  for (const r of rows.value) {
    if (r.current) continue
    found[r.id] = await tenantHostUrl(r.id, INSTALL_PATH)
  }
  hrefs.value = found
  /* arrived from another workspace's Install: bring this row into view */
  if (route.query.install === '1') {
    await nextTick()
    document.getElementById('settings-apps-h')?.scrollIntoView({ block: 'center' })
    const btn = Array.isArray(installBtn.value) ? installBtn.value[0] : installBtn.value
    btn?.focus()
  }
})
onBeforeUnmount(() => { off?.() })
</script>

<style scoped>
.apps__hint { margin: 0 0 8px; overflow-wrap: anywhere; }
.apps__list { list-style: none; margin: 0; padding: 0; display: grid; gap: 4px; }
.apps__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  min-height: var(--tap, 44px);
  min-width: 0;
}
.apps__name { font-weight: 600; overflow-wrap: anywhere; min-width: 0; }
.apps__btn { min-height: var(--tap, 44px); display: inline-flex; align-items: center; text-decoration: none; }
.apps__manual { overflow-wrap: anywhere; max-width: 100%; }
.apps__done { color: var(--color-accent); font-weight: 600; }
</style>
