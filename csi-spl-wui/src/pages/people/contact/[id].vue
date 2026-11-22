<!-- Spec 154 B9 (2.4, 2.7): one contact's card in the middle pane, a lazy route.
     The four fields, Edit and Delete; Message when the contact is a member of
     this workspace (member_id), else Invite for a reader who may invite. Email
     and phone open the reader's own apps (contact-links.mjs, rdb 0193).
     /people/contact/new is the same form, empty: the panel's Add contact (+),
     with Import from file above its fields (SPL-5279).
     Spec 154 B17 (11.3, 11.4): company, job title, birthday and notes, shown
     when set and edited in the form; the picture (from Google only, no upload)
     beside the name, as a data: URL; the in_only line when a value from Google
     was cut and the contact is no longer written back. -->
<template>
  <div class="feed-col" data-test="contact-page">
    <header class="feed-header">
      <MobileBack />
      <img v-if="photoSrc && !isNew" :src="photoSrc" alt="" class="contact-head__pic" data-test="contact-photo">
      <h2 class="contact-head">{{ isNew ? t('people.add_contact') : shownName }}</h2>
    </header>
    <div class="feed-body">
      <p v-if="view === 'loading'" class="muted contact-card">{{ t('common.loading') }}</p>
      <p v-else-if="view === 'missing'" class="muted contact-card" data-test="contact-missing">{{ t('contacts.not_found') }}</p>
      <form v-else-if="view === 'form'" class="contact-card contact-card--form" data-test="contact-form" novalidate @submit.prevent="save">
        <!-- SPL-5279: the panel's Import from file moved here, onto the new contact form -->
        <div v-if="isNew" class="contact-card__import">
          <button type="button" class="btn ghost" data-testid="people-import-contacts" :disabled="busy" @click="importOpen = true">
            {{ t('contacts.import.open') }}
          </button>
        </div>
        <label v-for="f in FIELDS" :key="f.key" class="contact-card__field">
          <span>{{ t('contacts.' + f.key) }}</span>
          <textarea v-if="f.type === 'textarea'" v-model="form[f.key]" class="input" rows="4" :maxlength="f.max" :data-test="'contact-input-' + f.key" />
          <input
            v-else
            v-model="form[f.key]"
            class="input"
            :type="f.type"
            :maxlength="f.max"
            :placeholder="f.key === 'birthday' ? t('contacts.birthday_hint') : undefined"
            autocomplete="off"
            :data-test="'contact-input-' + f.key"
          >
        </label>
        <p v-if="error" class="contact-card__error" role="alert" data-test="contact-error">{{ t(error) }}</p>
        <div class="contact-card__actions contact-card__actions--form">
          <button type="submit" class="btn" data-test="contact-save" :disabled="busy">{{ t('contacts.save') }}</button>
          <button type="button" class="btn ghost" data-test="contact-cancel" :disabled="busy" @click="cancel">{{ t('common.cancel') }}</button>
        </div>
      </form>
      <div v-else class="contact-card" data-test="contact-card">
        <dl class="contact-card__facts">
          <dt>{{ t('contacts.first_name') }}</dt>
          <dd data-test="contact-first-name">{{ contact?.first_name || '-' }}</dd>
          <dt>{{ t('contacts.last_name') }}</dt>
          <dd data-test="contact-last-name">{{ contact?.last_name || '-' }}</dd>
          <dt>{{ t('contacts.email') }}</dt>
          <dd data-test="contact-email">
            <a v-if="emailLink" :href="emailLink" :target="blank(emailLink)" rel="noopener noreferrer">{{ contact?.email }}</a>
            <template v-else>{{ contact?.email || '-' }}</template>
          </dd>
          <dt>{{ t('contacts.phone') }}</dt>
          <dd data-test="contact-phone">
            <a v-if="phoneLink" :href="phoneLink" :target="blank(phoneLink)" rel="noopener noreferrer">{{ contact?.phone }}</a>
            <template v-else>{{ contact?.phone || '-' }}</template>
          </dd>
          <template v-for="f in MORE" :key="f">
            <template v-if="contact?.[f]">
              <dt>{{ t('contacts.' + f) }}</dt>
              <dd :class="{ 'contact-card__notes-text': f === 'notes' }" :data-test="'contact-' + f">{{ contact?.[f] }}</dd>
            </template>
          </template>
        </dl>
        <p v-if="contact?.in_only" class="muted contact-card__in-only" data-test="contact-in-only">{{ t('contacts.in_only') }}</p>
        <div class="contact-card__actions">
          <button v-if="canMessage" type="button" class="btn" data-test="contact-message" @click="message">
            <UiIcon name="messages" :size="16" /><span>{{ t('people.message') }}</span>
          </button>
          <button v-if="canInvite" type="button" class="btn" data-test="contact-invite" :disabled="busy" @click="invite">{{ t('contacts.invite') }}</button>
          <button type="button" class="btn ghost" data-test="contact-edit" @click="edit">{{ t('contacts.edit') }}</button>
          <button type="button" class="btn ghost danger" data-test="contact-delete" @click="confirmOpen = true">
            <UiIcon name="trash" :size="16" /><span>{{ t('contacts.delete') }}</span>
          </button>
        </div>
        <p v-if="said" class="contact-card__said" role="status" data-test="contact-said">{{ t('contacts.invited', { email: contact?.email }) }}</p>
        <p v-if="error" class="contact-card__error" role="alert" data-test="contact-error">{{ t(error) }}</p>
      </div>
    </div>

    <!-- spec 154 B17: a new instance each opening, so nothing of the last file stays; async, so no first paint carries it (C47) -->
    <ContactsImportDialog v-if="importOpen" v-model:open="importOpen" />
    <UiDialog :open="confirmOpen" size="md" :title="t('contacts.delete_title')" @update:open="confirmOpen = $event">
      <p data-test="contact-delete-text">{{ t('contacts.delete_confirm', { name: shownName }) }}</p>
      <template #footer>
        <button type="button" class="btn ghost" data-test="contact-delete-cancel" @click="confirmOpen = false">{{ t('common.cancel') }}</button>
        <button type="button" class="btn danger" :disabled="busy" data-test="contact-delete-ok" @click="remove">{{ t('contacts.delete') }}</button>
      </template>
    </UiDialog>
  </div>
</template>

<script setup lang="ts">
import UiDialog from '~/components/UiDialog.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { loadAvatarImageUrl } from '~/utils/avatar'
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'
import { useSessionStore } from '~/stores/session'
import { contactHref } from '~/utils/contact-links.mjs'
import { contactCreate, contactDelete, contactErrorKey, contactGet, contactInvite, contactPatch, contactPhoto, contactReread } from '~/utils/contacts-client.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { contactName } from '~/utils/people-order.mjs'
import { userErrorKey } from '~/utils/tenant-users.mjs'

const ContactsImportDialog = defineAsyncComponent(() => import('~/components/ContactsImportDialog.vue'))

type Contact = {
  contact_id: string, first_name: string, last_name: string, email: string | null, phone: string | null, member_id?: string | null
  company?: string, job_title?: string, birthday?: string | null, notes?: string, in_only?: boolean, photo?: string | null
}
type FieldKey = 'first_name' | 'last_name' | 'email' | 'phone' | 'company' | 'job_title' | 'birthday' | 'notes'

/* max = the hub's caps (spec 154 11.3), so a too_long is rare; the hub still checks */
const FIELDS: Array<{ key: FieldKey, type: string, max?: number }> = [
  { key: 'first_name', type: 'text', max: 100 },
  { key: 'last_name', type: 'text', max: 100 },
  { key: 'email', type: 'email' },
  { key: 'phone', type: 'tel' },
  { key: 'company', type: 'text', max: 200 },
  { key: 'job_title', type: 'text', max: 200 },
  { key: 'birthday', type: 'text', max: 10 },
  { key: 'notes', type: 'textarea', max: 8000 },
]
/* the card shows these only when set */
const MORE = ['company', 'job_title', 'birthday', 'notes'] as const

const { t, locale } = useI18n({ useScope: 'global' })
const route = useRoute()
const api = useSpoolApi()
const access = useAccessStore()
const roster = useRosterStore()
const session = useSessionStore()
const localePath = useLocalePath()

const id = computed(() => decodeURIComponent(String(route.params.id || '')))
const isNew = computed(() => id.value === 'new')
const contact = ref<Contact | null>(null)
const view = ref<'loading' | 'missing' | 'form' | 'card'>('loading')
const form = reactive<Record<FieldKey, string>>({ first_name: '', last_name: '', email: '', phone: '', company: '', job_title: '', birthday: '', notes: '' })
const busy = ref(false)
const error = ref('')
const said = ref(false)
const confirmOpen = ref(false)
const importOpen = ref(false)
const photoSrc = ref('')

const shownName = computed(() => contactName(contact.value))
const canMessage = computed(() => Boolean(contact.value?.member_id) && contact.value?.member_id !== roster.self?.id)
const canInvite = computed(() => !contact.value?.member_id && Boolean(contact.value?.email) && access.can('members.invite'))
const emailLink = computed(() => (contact.value?.email ? contactHref('mailto:' + contact.value.email, session.claims) : null))
const phoneLink = computed(() => (contact.value?.phone ? contactHref('tel:' + contact.value.phone.replace(/[^\d+]/g, ''), session.claims) : null))
const blank = (href: string) => (/^https:/i.test(href) ? '_blank' : undefined)

function fillForm(c: Contact | null) {
  for (const f of FIELDS) form[f.key] = String(c?.[f.key] || '')
}

/* the picture of the contact on screen; a later contact's answer wins */
async function showPhoto(c: Contact | null) {
  photoSrc.value = ''
  if (!c?.photo) return
  const src = await contactPhoto(api, c, loadAvatarImageUrl)
  if (contact.value?.contact_id === c.contact_id && contact.value?.photo === c.photo) photoSrc.value = src
}

async function load() {
  error.value = ''
  said.value = false
  if (isNew.value) {
    contact.value = null
    photoSrc.value = ''
    fillForm(null)
    view.value = 'form'
    return
  }
  view.value = 'loading'
  try {
    contact.value = await withSessionRetry(api, () => contactGet(api, id.value)) as Contact
    view.value = 'card'
    void showPhoto(contact.value)
  } catch {
    contact.value = null
    view.value = 'missing'
  }
}

function edit() {
  fillForm(contact.value)
  error.value = ''
  view.value = 'form'
}

function cancel() {
  error.value = ''
  if (isNew.value) void navigateTo(localePath('/people'))
  else view.value = 'card'
}

async function save() {
  if (busy.value) return
  busy.value = true
  error.value = ''
  const values = {
    first_name: form.first_name.trim(),
    last_name: form.last_name.trim(),
    email: form.email.trim() || null,
    phone: form.phone.trim() || null,
    company: form.company.trim(),
    job_title: form.job_title.trim(),
    birthday: form.birthday.trim() || null,
    notes: form.notes.trim(),
  }
  try {
    if (isNew.value) {
      const row = await contactCreate(api, values) as Contact
      await navigateTo(localePath('/people/contact/' + encodeURIComponent(row.contact_id)), { replace: true })
    } else {
      const row = await contactPatch(api, id.value, values)
      contact.value = await contactReread(api, id.value, row, contact.value) as Contact
      view.value = 'card'
      void showPhoto(contact.value)
    }
  } catch (e) {
    error.value = contactErrorKey(e)
  } finally {
    busy.value = false
  }
}

async function remove() {
  if (busy.value) return
  busy.value = true
  error.value = ''
  try {
    await contactDelete(api, id.value)
    confirmOpen.value = false
    await navigateTo(localePath('/people'))
  } catch {
    confirmOpen.value = false
    error.value = 'contacts.delete_failed'
  } finally {
    busy.value = false
  }
}

function message() {
  void navigateTo(localePath('/dm/' + encodeURIComponent(contact.value?.member_id + '@box-wui')))
}

async function invite() {
  if (busy.value || !contact.value?.email) return
  busy.value = true
  error.value = ''
  said.value = false
  try {
    await contactInvite(api, contact.value.email, locale.value)
    said.value = true
  } catch (e) {
    error.value = userErrorKey(e)
  } finally {
    busy.value = false
  }
}

watch(id, load)
onMounted(() => {
  void access.load()
  void load()
})
</script>

<style scoped>
.contact-head { min-width: 0; overflow-wrap: anywhere; }
.contact-head__pic { width: 40px; height: 40px; border-radius: 50%; object-fit: cover; flex-shrink: 0; }
.contact-card__notes-text { white-space: pre-wrap; }
.contact-card__in-only { margin: 0; overflow-wrap: anywhere; }
.contact-card--form textarea.input { height: auto; min-height: calc(var(--contact-input-h) * 3); padding: 6px 10px; resize: vertical; font-family: inherit; }
.contact-card { padding: 16px; max-width: 640px; display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.contact-card__field { display: flex; flex-direction: column; gap: 4px; }
.contact-card__field span { color: var(--color-muted); font-size: 0.8125rem; }
.contact-card__facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 6px 14px; margin: 0; }
.contact-card__facts dt { color: var(--color-muted); font-size: 0.8125rem; }
.contact-card__facts dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
.contact-card__actions { display: flex; gap: 10px; flex-wrap: wrap; }
.contact-card__actions .btn { display: inline-flex; align-items: center; gap: 6px; min-height: var(--tap, 44px); }
.contact-card__import { display: flex; }
.contact-card__import .btn { min-height: var(--tap, 44px); }
.contact-card__error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
.contact-card__said { margin: 0; overflow-wrap: anywhere; }
/* SPL-5504 (owner, topic 50a68313): the form's inputs 30% taller and 35%
   narrower than the browser default they had (measured 608 x 21 px, the full
   field width), in a card; on a phone they fill the card. The card keeps its
   640 px and 16 px padding, so 65% of the field is 65% of the old input.
   The soft edge is a box-shadow, not a border, so the field width is unchanged.
   This page only, never the shared .input class. */
.contact-card--form {
  --contact-input-h: 27.3px;
  margin-top: 4px;
  background: var(--color-surface);
  border-radius: var(--radius-lg);
  box-shadow: 0 0 0 1px var(--color-border), 0 4px 16px rgb(0 0 0 / 0.08);
}
.contact-card--form .contact-card__field { gap: 6px; }
.contact-card--form .contact-card__field span { font-weight: 600; letter-spacing: 0.01em; }
.contact-card--form .input,
.contact-card__actions--form { box-sizing: border-box; width: 65%; }
.contact-card--form .input {
  height: var(--contact-input-h);
  padding: 0 10px;
  font-size: 0.875rem;
  color: var(--color-fg);
  background: var(--color-bg);
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-md);
  transition: border-color 0.15s ease, box-shadow 0.15s ease;
}
.contact-card--form .input:hover { border-color: var(--color-accent); }
.contact-card--form .input:focus { outline: none; }
.contact-card--form .input:focus-visible {
  border-color: var(--color-accent);
  outline: var(--focus-ring-w) solid var(--focus-ring);
  outline-offset: var(--focus-offset);
}
.contact-card__actions--form { flex-wrap: nowrap; margin-top: 4px; }
.contact-card__actions--form .btn { flex: 1 1 0; justify-content: center; min-width: 0; }
@media (max-width: 480px) {
  .contact-card__facts { grid-template-columns: minmax(0, 1fr); gap: 0; }
  .contact-card__facts dd + dt { margin-top: 8px; }
  .contact-card--form .input,
  .contact-card__actions--form { width: 100%; }
}
</style>
