<!-- Settings → Profile (CLE-3402's card, moved here by specs/023 §3.4).
     The display name is the one editable field (CLE-34968,
     DisplayNameSetting); the picture is the member's stored IdP picture or
     identicon. -->
<template>
  <SettingsSection id="settings-profile" :title="t('settings.profile')" data-test="settings-profile">
    <div class="settings__profile">
      <span class="settings__avatar" :class="'settings__avatar--' + mode" aria-hidden="true">
        <SpoolAvatar v-if="mode === 'member'" :id="me.hum" :size="64" />
        <template v-else-if="mode === 'initials'">{{ initials }}</template>
        <UiIcon v-else name="user" :size="32" />
      </span>
      <dl class="settings__facts">
        <template v-if="me.name">
          <dt>{{ t('settings.name') }}</dt>
          <dd data-test="settings-name">{{ me.name }}</dd>
        </template>
        <template v-if="me.email">
          <dt>{{ t('settings.email') }}</dt>
          <dd data-test="settings-email">{{ me.email }}</dd>
        </template>
        <template v-if="me.hum">
          <dt>{{ t('settings.member_id') }}</dt>
          <dd data-test="settings-hum"><code>{{ me.hum }}</code></dd>
        </template>
        <template v-if="me.tenant">
          <dt>{{ t('settings.workspace') }}</dt>
          <dd data-test="settings-tenant"><code>{{ me.tenant }}</code></dd>
        </template>
      </dl>
    </div>
    <p class="muted settings__hint">
      {{ t('settings.picture_hint') }}
    </p>
    <DisplayNameSetting />
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import DisplayNameSetting from '~/components/DisplayNameSetting.vue'
import { useSessionStore } from '~/stores/session'
import { avatarMode, userIdentity, userInitials } from '~/utils/user-menu.mjs'

const session = useSessionStore()
const { t } = useI18n({ useScope: 'global' })
const me = computed(() => userIdentity(session.claims))
const mode = computed(() => avatarMode(session.claims))
const initials = computed(() => userInitials(session.claims))
</script>

<style scoped>
.settings__profile { display: flex; gap: 16px; align-items: flex-start; flex-wrap: wrap; min-width: 0; }
.settings__avatar {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 64px;
  height: 64px;
  border-radius: 50%;
  border: 1.5px solid var(--color-border-strong);
  background: var(--color-surface);
  color: var(--color-muted);
  font-size: 22px;
  font-weight: 700;
  overflow: hidden;
  flex-shrink: 0;
}
.settings__avatar--initials {
  background: color-mix(in srgb, var(--color-accent) 16%, var(--color-surface));
  color: var(--color-accent);
}
.settings__avatar--member :deep(.spool-avatar) { border-radius: 50%; display: block; }
.settings__facts {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr);
  gap: 4px 12px;
  margin: 0;
  min-width: 0;
  flex: 1;
}
.settings__facts dt { color: var(--color-muted); font-size: 0.8125rem; }
.settings__facts dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
.settings__hint { font-size: 0.8125rem; margin: 10px 0 0; }
/* SPL-993: a phone stacks each label over its value, so a long e-mail keeps
   the full width instead of breaking every few characters. */
@media (max-width: 480px) {
  .settings__facts { grid-template-columns: minmax(0, 1fr); gap: 0; flex-basis: 100%; }
  .settings__facts dd + dt { margin-top: 8px; }
}
</style>
