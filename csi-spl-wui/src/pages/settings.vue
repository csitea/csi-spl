<!-- /settings (CLE-3402) — the user dropdown's Settings entry. Modelled on the
     reference storefront's /account page, keeping only what the spool supports:
     profile (read-only: the hub has no profile PATCH; the picture is the
     member's stored IdP picture or identicon), language (CLE-3403's
     <LanguageSetting />), appearance (theme), sign-in method + password change
     (native-auth-v1 §2, password sessions only) and sign out. -->
<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2 id="settings-h">Settings</h2>
    </header>
    <div class="feed-body settings" data-test="settings">
      <p v-if="session.state === 'loading'" class="muted">Loading…</p>
      <template v-else-if="signedIn">
        <section class="settings__card" data-test="settings-profile" aria-labelledby="settings-profile-h">
          <h3 id="settings-profile-h">Profile</h3>
          <div class="settings__profile">
            <span class="settings__avatar" :class="'settings__avatar--' + mode" aria-hidden="true">
              <SpoolAvatar v-if="mode === 'member'" :id="me.hum" :size="64" />
              <template v-else-if="mode === 'initials'">{{ initials }}</template>
              <UiIcon v-else name="user" :size="32" />
            </span>
            <dl class="settings__facts">
              <template v-if="me.name">
                <dt>Name</dt>
                <dd data-test="settings-name">{{ me.name }}</dd>
              </template>
              <template v-if="me.email">
                <dt>Email</dt>
                <dd data-test="settings-email">{{ me.email }}</dd>
              </template>
              <template v-if="me.hum">
                <dt>Member id</dt>
                <dd data-test="settings-hum"><code>{{ me.hum }}</code></dd>
              </template>
              <template v-if="me.tenant">
                <dt>Workspace</dt>
                <dd data-test="settings-tenant"><code>{{ me.tenant }}</code></dd>
              </template>
            </dl>
          </div>
          <p class="muted settings__hint">
            Your picture is the one your sign-in provider shares; without one the spool draws your identicon.
          </p>
        </section>

        <section id="settings-language" class="settings__card" data-test="settings-language" aria-labelledby="settings-language-h">
          <h3 id="settings-language-h">Language</h3>
          <!-- CLE-3403: <LanguageSetting /> mounts here -->
        </section>

        <section class="settings__card" data-test="settings-appearance" aria-labelledby="settings-appearance-h">
          <h3 id="settings-appearance-h">Appearance</h3>
          <div class="settings__row">
            <span>Theme</span>
            <ThemeToggle />
          </div>
        </section>

        <section class="settings__card" data-test="settings-signin" aria-labelledby="settings-signin-h">
          <h3 id="settings-signin-h">Sign-in and security</h3>
          <div class="settings__row">
            <span>Signed in with</span>
            <strong data-test="settings-method">{{ methodLabel(me.method) }}</strong>
          </div>
          <ChangePasswordForm v-if="me.method === 'password'" @changed="changed = true" />
          <p v-else class="muted settings__hint">Your password is managed by {{ methodLabel(me.method) }}.</p>
          <div class="settings__actions">
            <button class="btn ghost" type="button" data-test="settings-signout" @click="session.logout()">
              Sign out
            </button>
          </div>
        </section>
      </template>
      <template v-else>
        <p v-if="changed" class="muted" role="status" data-test="settings-password-changed">
          Password changed — sign in with the new one.
        </p>
        <p class="muted" data-test="settings-signed-out">
          <NuxtLink :to="{ path: localePath('/login'), query: { redirect: '/settings' } }">Sign in</NuxtLink>
          to see your settings.
        </p>
      </template>
    </div>
  </div>
</template>

<script setup lang="ts">
import ChangePasswordForm from '~/components/ChangePasswordForm.vue'
import { useSessionStore } from '~/stores/session'
import { avatarMode, methodLabel, userIdentity, userInitials } from '~/utils/user-menu.mjs'

const session = useSessionStore()
const localePath = useLocalePath()
const signedIn = computed(() => session.state === 'in' && !!session.claims)
const me = computed(() => userIdentity(session.claims))
const mode = computed(() => avatarMode(session.claims))
const initials = computed(() => userInitials(session.claims))
/* 015 §2 password/change 204 clears the cookie: say why the page went away */
const changed = ref(false)
</script>

<style scoped>
.settings { display: flex; flex-direction: column; gap: 16px; }
.settings__card {
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md, 12px);
  background: var(--color-bg-2);
  padding: 14px 16px;
  min-width: 0;
  max-width: 640px;
}
.settings__card h3 { margin: 0 0 10px; font-size: 15px; }
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
.settings__facts dt { color: var(--color-muted); font-size: 13px; }
.settings__facts dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
.settings__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  min-height: var(--tap, 44px);
}
.settings__hint { font-size: 13px; margin: 10px 0 0; }
.settings__actions { margin-top: 12px; }
</style>
