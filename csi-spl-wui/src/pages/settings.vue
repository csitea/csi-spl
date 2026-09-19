<!-- /settings (CLE-3402; GitHub-style since specs/023 §3.4) — the user
     dropdown's Settings entry. A left nav of sections, the selected section on
     the right; each section is its own child route (pages/settings/*.vue), so
     /settings/keys and /fi/settings/keys deep-link. /settings itself redirects
     to /settings/profile. Below 720px the nav becomes a wrapping row above the
     content. The signed-out state renders here once, for every section. -->
<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2 id="settings-h">{{ t('settings.title') }}</h2>
    </header>
    <div class="feed-body settings-page" data-test="settings">
      <p v-if="session.state === 'loading'" class="muted">{{ t('common.loading') }}</p>
      <div v-else-if="signedIn" class="settings-layout">
        <nav class="settings-nav" :aria-label="t('settings.nav_label')" data-test="settings-nav">
          <ul>
            <li v-for="s in SETTINGS_SECTIONS" :key="s.id">
              <NuxtLink
                :to="localePath('/settings/' + s.id)"
                class="settings-nav__link"
                :class="{ 'settings-nav__link--active': active === s.id }"
                :aria-current="active === s.id ? 'page' : undefined"
                :data-test="'settings-nav-' + s.id"
              >{{ t(s.label) }}</NuxtLink>
            </li>
          </ul>
        </nav>
        <div class="settings-content" data-test="settings-content">
          <NuxtPage />
        </div>
      </div>
      <template v-else>
        <p v-if="changed" class="muted" role="status" data-test="settings-password-changed">
          {{ t('auth.login.password_changed') }}
        </p>
        <p class="muted" data-test="settings-signed-out">
          <i18n-t keypath="settings.signed_out" scope="global">
            <template #link>
              <NuxtLink :to="{ path: localePath('/login'), query: { redirect: route.fullPath } }">{{ t('nav.login') }}</NuxtLink>
            </template>
          </i18n-t>
        </p>
      </template>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { SETTINGS_SECTIONS, settingsSectionOf } from '~/utils/settings-nav.mjs'

const session = useSessionStore()
const route = useRoute()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
const signedIn = computed(() => session.state === 'in' && !!session.claims)
const active = computed(() => settingsSectionOf(route.path))
/* 015 §2 password/change 204 clears the cookie: say why the page went away
   (set by pages/settings/security.vue) */
const changed = useState('settings-password-changed', () => false)
</script>

<style scoped>
.settings-layout {
  display: grid;
  grid-template-columns: minmax(160px, 220px) minmax(0, 1fr);
  gap: 24px;
  align-items: start;
  min-width: 0;
}
.settings-nav ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.settings-nav__link {
  display: flex;
  align-items: center;
  min-height: 36px;
  padding: 6px 12px;
  border-radius: var(--radius-sm, 8px);
  border-inline-start: 3px solid transparent;
  color: var(--color-text);
  text-decoration: none;
  overflow-wrap: anywhere;
}
.settings-nav__link:hover { background: var(--color-bg-2); }
.settings-nav__link--active {
  background: var(--color-bg-2);
  border-inline-start-color: var(--color-accent);
  font-weight: 600;
}
.settings-content { min-width: 0; display: flex; flex-direction: column; gap: 16px; }
@media (max-width: 720px) {
  .settings-layout { grid-template-columns: minmax(0, 1fr); gap: 12px; }
  .settings-nav ul { flex-direction: row; flex-wrap: wrap; gap: 4px; }
  .settings-nav__link { border-inline-start: 0; border-bottom: 2px solid transparent; border-radius: 0; padding: 6px 8px; }
  .settings-nav__link--active { border-bottom-color: var(--color-accent); background: none; }
}
</style>
