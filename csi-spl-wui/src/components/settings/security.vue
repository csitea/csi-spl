<!-- Settings → Sign-in and security (CLE-3402's card, specs/023 §3.4):
     sign-in method, password change (native-auth-v1 §2, password sessions
     only) and sign out. -->
<template>
  <SettingsSection id="settings-signin" :title="t('settings.signin_security')" data-test="settings-signin">
    <div class="settings__row">
      <span>{{ t('settings.signed_in_with') }}</span>
      <strong data-test="settings-method">{{ method }}</strong>
    </div>
    <ChangePasswordForm v-if="me.method === 'password'" @changed="changed = true" />
    <p v-else class="muted settings__hint">{{ t('settings.password_managed_by', { method }) }}</p>
    <div class="settings__actions">
      <button class="btn ghost" type="button" data-test="settings-signout" @click="session.logout()">
        {{ t('user_menu.sign_out') }}
      </button>
    </div>
    <!-- CLE-77781: this is the person's OWN sign-in page, not the workspace's
         people. Point admins who came here looking for members/invites at the
         right place (Workspace settings → Members). -->
    <p v-if="canManageMembers" class="muted settings__hint" data-test="settings-members-hint">{{ t('settings.members_hint') }}</p>
    <div v-if="canManageMembers" class="settings__actions">
      <NuxtLink :to="localePath('/tenant-settings/members')" class="btn ghost settings__members-link" data-test="settings-members-link">{{ t('settings.members_link') }}</NuxtLink>
    </div>
  </SettingsSection>
</template>

<script setup lang="ts">
import ChangePasswordForm from '~/components/ChangePasswordForm.vue'
import SettingsSection from '~/components/SettingsSection.vue'
import { useSessionStore } from '~/stores/session'
import { useAccessStore } from '~/stores/access'
import { methodLabelKey, userIdentity } from '~/utils/user-menu.mjs'
import { USERS_PERMISSION } from '~/utils/tenant-users.mjs'

const session = useSessionStore()
const access = useAccessStore()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
const me = computed(() => userIdentity(session.claims))
// CLE-77781: only an admin who can manage members sees the pointer to Workspace
// settings → Members (the hub re-checks; this just hides a dead link otherwise).
const canManageMembers = computed(() => access.can(USERS_PERMISSION))
onMounted(() => { access.load() })
/* the sign-in method in words, in the active locale (spec 021) */
const method = computed(() => {
  const k = methodLabelKey(me.value.method)
  return t(k.key, k.params)
})
/* read by pages/login.vue once the 204 has signed this browser out */
const changed = useState('settings-password-changed', () => false)
</script>

<style scoped>
.settings__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  min-height: var(--tap, 44px);
}
.settings__hint { font-size: 0.8125rem; margin: 10px 0 0; }
.settings__actions { margin-top: 12px; }
/* CLE-77781: a real >= 44px tap target (mobile-m5 e2e: every settings link is
   >= 44px). .btn sets min-height but an inline <a> ignores it, so give the
   link an explicit flex display; inline-flex keeps it sized to its text. */
.settings__members-link {
  display: inline-flex;
  align-items: center;
  min-height: var(--tap, 44px);
  text-decoration: none;
}
</style>
