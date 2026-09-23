<!-- /settings (CLE-3402; GitHub-style since specs/023 §3.4) — the user
     dropdown's Settings entry. A left nav of sections, the selected section on
     the right; each section is its own child route (pages/settings/*.vue), so
     /settings/keys and /fi/settings/keys deep-link. /settings itself redirects
     to /settings/profile. Below 720px the nav becomes a wrapping row above the
     content. A settled signed-out session never reaches this screen:
     the shared redirect replaces it with /login. -->
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
/* CLE-3427: the active nav item is a SELECTED item — a step DARKER than the
   hover fill, and its 3px edge is the one ring colour the whole WUI uses. */
.settings-nav__link--active {
  background: var(--color-selected);
  border-inline-start-color: var(--focus-ring);
  font-weight: 600;
}
.settings-content { min-width: 0; display: flex; flex-direction: column; gap: 16px; }
@media (max-width: 720px) {
  .settings-layout { grid-template-columns: minmax(0, 1fr); gap: 12px; }
  .settings-nav ul { flex-direction: row; flex-wrap: wrap; gap: 4px; }
  .settings-nav__link { border-inline-start: 0; border-bottom: 2px solid transparent; border-radius: var(--radius-sm); padding: 6px 8px; }
  .settings-nav__link--active { border-bottom-color: var(--focus-ring); background: none; }
}
</style>
