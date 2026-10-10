<!-- A member's sign-in emails (owner HUM-10, t1 f265541a; hub 153e6c359).
     `self`: the signed-in person's own list (Settings -> Sign-in and
     security), with a "Confirm with <provider>" link per pending address: a
     link sign-in started from this session is the one way the hub turns a
     pending address active. Not self: an admin's view of a member (Workspace
     settings -> Members); it adds and removes as the hub allows, but only the
     member can confirm. Loaded only with those views (sign-in-emails.mjs). -->
<template>
  <div class="signin-emails" :data-test="self ? 'signin-emails' : 'signin-emails-admin'">
    <p class="muted signin-emails__intro">{{ t(self ? 'signin_emails.intro' : 'signin_emails.intro_admin') }}</p>
    <p v-if="loading && !rows.length" class="muted" aria-live="polite" data-test="signin-emails-loading">{{ t('signin_emails.loading') }}</p>
    <ul v-else-if="rows.length" class="signin-emails__list" data-test="signin-emails-list">
      <li
        v-for="r in rows"
        :key="r.email"
        class="signin-emails__row"
        :data-state="r.state"
        :data-test="'signin-emails-row-' + r.state"
      >
        <div class="signin-emails__line">
          <span class="signin-emails__email" dir="ltr" data-test="signin-emails-address">{{ r.email }}</span>
          <span class="signin-emails__chip" :class="'signin-emails__chip--' + r.state" data-test="signin-emails-state">{{ t('signin_emails.state_' + r.state) }}</span>
          <span v-if="r.main" class="signin-emails__chip signin-emails__chip--main" data-test="signin-emails-main">{{ t('signin_emails.main') }}</span>
        </div>
        <p v-if="r.state === 'active' && r.providers.length" class="muted signin-emails__sub" data-test="signin-emails-providers">
          {{ t('signin_emails.signs_in_with', { providers: providerList(r.providers) }) }}
        </p>
        <p v-if="r.state === 'pending'" class="muted signin-emails__sub" data-test="signin-emails-pending-hint">
          {{ t(self ? 'signin_emails.pending_hint' : 'signin_emails.pending_hint_admin', { providers: confirmNames }) }}
        </p>
        <div class="signin-emails__actions">
          <template v-if="self && r.state === 'pending'">
            <a
              v-for="p in confirmWith"
              :key="p"
              class="btn ghost signin-emails__btn"
              :href="confirmHref(p, r.email)"
              :data-test="'signin-emails-confirm-' + p"
            >{{ t('signin_emails.confirm_with', { provider: signInEmailProviderName(p) }) }}</a>
          </template>
          <template v-if="canEdit && !r.main">
            <template v-if="confirming === r.email">
              <span class="signin-emails__ask">{{ t('signin_emails.remove_confirm', { email: r.email }) }}</span>
              <button type="button" class="btn ghost signin-emails__btn signin-emails__danger" :disabled="busy" data-test="signin-emails-remove-yes" @click="remove(r.email)">{{ t('signin_emails.remove') }}</button>
              <button type="button" class="btn ghost signin-emails__btn" :disabled="busy" data-test="signin-emails-remove-cancel" @click="confirming = ''">{{ t('signin_emails.cancel') }}</button>
            </template>
            <button
              v-else
              type="button"
              class="btn ghost signin-emails__btn"
              :disabled="busy"
              data-test="signin-emails-remove"
              @click="askRemove(r.email)"
            >{{ t('signin_emails.remove') }}</button>
          </template>
        </div>
      </li>
    </ul>
    <p v-else-if="!error" class="muted" data-test="signin-emails-empty">{{ t('signin_emails.empty') }}</p>

    <form v-if="canEdit" class="signin-emails__form" data-test="signin-emails-add-form" @submit.prevent="add">
      <label class="signin-emails__label" :for="inputId">{{ t('signin_emails.add_label') }}</label>
      <div class="signin-emails__add">
        <input
          :id="inputId"
          v-model="draft"
          type="email"
          inputmode="email"
          autocomplete="off"
          maxlength="320"
          dir="ltr"
          data-test="signin-emails-input"
        >
        <button type="submit" class="btn signin-emails__btn" :disabled="busy || !draft.trim()" data-test="signin-emails-add">{{ t('signin_emails.add') }}</button>
      </div>
    </form>
    <p v-if="notice" class="signin-emails__notice" role="status" data-test="signin-emails-notice">{{ notice }}</p>
    <p v-if="error" class="signin-emails__error" role="alert" data-test="signin-emails-error">{{ error }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAuthBase, useAuthClient } from '~/composables/useAuthClient'
import { useSessionStore } from '~/stores/session'
import { userIdentity } from '~/utils/user-menu.mjs'
import {
  SIGN_IN_EMAIL_PROVIDERS,
  addSignInEmail,
  loadSignInEmails,
  mockSignInEmailProviders,
  removeSignInEmail,
  signInEmailAddedKey,
  signInEmailAddress,
  signInEmailConfirmHref,
  signInEmailConfirmProviders,
  signInEmailErrorKey,
  signInEmailProviderName,
  signInEmailRows,
} from '~/utils/sign-in-emails.mjs'

const props = withDefaults(defineProps<{ humanId: string, self?: boolean, canEdit?: boolean }>(), { self: false, canEdit: true })
const { t, locale } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const auth = useAuthClient()
const authBase = useAuthBase()
const session = useSessionStore()
const route = useRoute()
const inputId = useId()

type Row = ReturnType<typeof signInEmailRows>[number]
const rows = ref<Row[]>([])
const enabled = ref<string[]>([])
const loading = ref(false)
const busy = ref(false)
const draft = ref('')
const notice = ref('')
const error = ref('')
const confirming = ref('')

const confirmWith = computed(() => signInEmailConfirmProviders(enabled.value))
/* the providers named in the explanation: the enabled ones, else all four */
const confirmNames = computed(() => {
  const list = confirmWith.value.length ? confirmWith.value : SIGN_IN_EMAIL_PROVIDERS
  return listOf(list.map(signInEmailProviderName), 'disjunction')
})

function listOf(items: string[], type: 'conjunction' | 'disjunction') {
  try {
    return new Intl.ListFormat(String(locale.value || 'en'), { type }).format(items)
  } catch {
    return items.join(', ')
  }
}

function providerList(providers: string[]) {
  return listOf(providers.map((p) => signInEmailProviderName(p) || t('user_menu.method_password')), 'conjunction')
}

function confirmHref(provider: string, email: string) {
  return signInEmailConfirmHref(provider, email, route.fullPath, userIdentity(session.claims).tenant, authBase)
}

function fail(e: unknown) {
  error.value = t(signInEmailErrorKey(e))
}

async function load() {
  if (!props.humanId) return
  loading.value = true
  error.value = ''
  try {
    rows.value = signInEmailRows(await loadSignInEmails(api, props.humanId))
  } catch (e) {
    rows.value = []
    fail(e)
  } finally {
    loading.value = false
  }
}

async function loadProviders() {
  try {
    enabled.value = api.mock ? await mockSignInEmailProviders() : await auth.providers()
  } catch {
    enabled.value = []
  }
}

async function add() {
  if (busy.value) return
  notice.value = ''
  error.value = ''
  const email = signInEmailAddress(draft.value)
  if (!email) {
    error.value = t('signin_emails.error_bad_email')
    return
  }
  busy.value = true
  try {
    const answer = await addSignInEmail(api, props.humanId, email)
    const key = signInEmailAddedKey(answer)
    notice.value = key === 'signin_emails.added_pending'
      ? t(props.self ? 'signin_emails.added_pending' : 'signin_emails.added_pending_admin', { email, providers: confirmNames.value })
      : t(key, { email })
    draft.value = ''
    await load()
  } catch (e) {
    fail(e)
  } finally {
    busy.value = false
  }
}

function askRemove(email: string) {
  notice.value = ''
  error.value = ''
  confirming.value = email
}

async function remove(email: string) {
  if (busy.value) return
  busy.value = true
  error.value = ''
  try {
    await removeSignInEmail(api, props.humanId, email)
    notice.value = t('signin_emails.removed', { email })
    await load()
  } catch (e) {
    fail(e)
  } finally {
    confirming.value = ''
    busy.value = false
  }
}

watch(() => props.humanId, () => {
  notice.value = ''
  confirming.value = ''
  draft.value = ''
  void load()
})
onMounted(() => {
  void load()
  void loadProviders()
})
</script>

<style scoped>
.signin-emails { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.signin-emails__intro { margin: 0; font-size: 0.875rem; }
.signin-emails__list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
.signin-emails__row {
  display: flex;
  flex-direction: column;
  gap: 4px;
  padding: 10px 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm, 8px);
  min-width: 0;
}
.signin-emails__line { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; min-width: 0; }
.signin-emails__email { font-weight: 600; overflow-wrap: anywhere; min-width: 0; }
.signin-emails__chip {
  display: inline-flex;
  align-items: center;
  padding: 1px 8px;
  border-radius: var(--radius-pill);
  font-size: 0.75rem;
  border: 1px solid var(--color-border);
  background: var(--color-bg);
  color: var(--color-muted);
}
.signin-emails__chip--active { color: var(--color-text); font-weight: 600; }
.signin-emails__chip--pending { font-style: italic; }
.signin-emails__chip--main { color: var(--color-text); }
.signin-emails__sub { margin: 0; font-size: 0.8125rem; overflow-wrap: anywhere; }
.signin-emails__actions { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.signin-emails__actions:empty { display: none; }
.signin-emails__btn {
  display: inline-flex;
  align-items: center;
  min-height: var(--tap, 44px);
  text-decoration: none;
}
.signin-emails__ask { font-size: 0.875rem; overflow-wrap: anywhere; }
.signin-emails__danger { color: var(--color-danger); border-color: var(--color-danger); }
.signin-emails__form { display: flex; flex-direction: column; gap: 6px; }
.signin-emails__label { font-size: 0.875rem; font-weight: 600; }
.signin-emails__add { display: flex; gap: 8px; flex-wrap: wrap; }
/* the same field as Settings -> Profile's display name */
.signin-emails__add input {
  flex: 1 1 220px;
  min-width: 0;
  min-height: var(--tap, 44px);
  padding: 6px 10px;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm, 8px);
  background: var(--color-surface);
  color: var(--color-text);
  font: inherit;
}
.signin-emails__notice { margin: 0; font-size: 0.875rem; }
.signin-emails__error { margin: 0; font-size: 0.875rem; color: var(--color-danger); }
</style>
