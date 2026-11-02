<!-- Spec 154 B9 (2.4, 2.7): one contact's card in the middle pane, a lazy route.
     The four fields, Edit and Delete; Message when the contact is a member of
     this workspace (member_id), else Invite for a reader who may invite. Email
     and phone open the reader's own apps (contact-links.mjs, rdb 0193).
     /people/contact/new is the same form, empty: the panel's Add contact. -->
<template>
  <div class="feed-col" data-test="contact-page">
    <header class="feed-header">
      <MobileBack />
      <h2 class="contact-head">{{ isNew ? t('people.add_contact') : shownName }}</h2>
    </header>
    <div class="feed-body">
      <p v-if="view === 'loading'" class="muted contact-card">{{ t('common.loading') }}</p>
      <p v-else-if="view === 'missing'" class="muted contact-card" data-test="contact-missing">{{ t('contacts.not_found') }}</p>
      <form v-else-if="view === 'form'" class="contact-card" data-test="contact-form" novalidate @submit.prevent="save">
        <label v-for="f in FIELDS" :key="f.key" class="contact-card__field">
          <span>{{ t('contacts.' + f.key) }}</span>
          <input v-model="form[f.key]" class="input" :type="f.type" autocomplete="off" :data-test="'contact-input-' + f.key">
        </label>
        <p v-if="error" class="contact-card__error" role="alert" data-test="contact-error">{{ t(error) }}</p>
        <div class="contact-card__actions">
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
        </dl>
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
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'
import { useSessionStore } from '~/stores/session'
import { contactHref } from '~/utils/contact-links.mjs'
import { contactCreate, contactDelete, contactErrorKey, contactGet, contactInvite, contactPatch } from '~/utils/contacts-client.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { contactName } from '~/utils/people-order.mjs'
import { userErrorKey } from '~/utils/tenant-users.mjs'

type Contact = { contact_id: string, first_name: string, last_name: string, email: string | null, phone: string | null, member_id?: string | null }
type FieldKey = 'first_name' | 'last_name' | 'email' | 'phone'

const FIELDS: Array<{ key: FieldKey, type: string }> = [
  { key: 'first_name', type: 'text' },
  { key: 'last_name', type: 'text' },
  { key: 'email', type: 'email' },
  { key: 'phone', type: 'tel' },
]

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
const form = reactive<Record<FieldKey, string>>({ first_name: '', last_name: '', email: '', phone: '' })
const busy = ref(false)
const error = ref('')
const said = ref(false)
const confirmOpen = ref(false)

const shownName = computed(() => contactName(contact.value))
const canMessage = computed(() => Boolean(contact.value?.member_id) && contact.value?.member_id !== roster.self?.id)
const canInvite = computed(() => !contact.value?.member_id && Boolean(contact.value?.email) && access.can('members.invite'))
const emailLink = computed(() => (contact.value?.email ? contactHref('mailto:' + contact.value.email, session.claims) : null))
const phoneLink = computed(() => (contact.value?.phone ? contactHref('tel:' + contact.value.phone.replace(/[^\d+]/g, ''), session.claims) : null))
const blank = (href: string) => (/^https:/i.test(href) ? '_blank' : undefined)

function fillForm(c: Contact | null) {
  form.first_name = c?.first_name || ''
  form.last_name = c?.last_name || ''
  form.email = c?.email || ''
  form.phone = c?.phone || ''
}

async function load() {
  error.value = ''
  said.value = false
  if (isNew.value) {
    contact.value = null
    fillForm(null)
    view.value = 'form'
    return
  }
  view.value = 'loading'
  try {
    contact.value = await withSessionRetry(api, () => contactGet(api, id.value)) as Contact
    view.value = 'card'
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
  }
  try {
    if (isNew.value) {
      const row = await contactCreate(api, values) as Contact
      await navigateTo(localePath('/people/contact/' + encodeURIComponent(row.contact_id)), { replace: true })
    } else {
      contact.value = await contactPatch(api, id.value, values) as Contact
      view.value = 'card'
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
.contact-card { padding: 16px; max-width: 640px; display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.contact-card__field { display: flex; flex-direction: column; gap: 4px; }
.contact-card__field span { color: var(--color-muted); font-size: 0.8125rem; }
.contact-card__facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 6px 14px; margin: 0; }
.contact-card__facts dt { color: var(--color-muted); font-size: 0.8125rem; }
.contact-card__facts dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
.contact-card__actions { display: flex; gap: 10px; flex-wrap: wrap; }
.contact-card__actions .btn { display: inline-flex; align-items: center; gap: 6px; min-height: var(--tap, 44px); }
.contact-card__error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
.contact-card__said { margin: 0; overflow-wrap: anywhere; }
@media (max-width: 480px) {
  .contact-card__facts { grid-template-columns: minmax(0, 1fr); gap: 0; }
  .contact-card__facts dd + dt { margin-top: 8px; }
}
</style>
