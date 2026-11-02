<!-- Spec 154 B9 (2.7): group 3 of the People panel, the reader's contacts who
     are no member here, and the list's one read. A lazy chunk with
     contacts-client.mjs, mounted when the panel first opens, so the initial
     download never carries it (C25). It stays mounted under the "In this
     workspace" filter: the parent still needs the list for the "contact" tags. -->
<template>
  <div v-if="failed" class="people-contacts" data-test="people-contacts-failed">
    <p class="muted topic-empty" role="alert">{{ t('contacts.load_failed') }}</p>
    <button type="button" class="btn ghost" data-test="people-contacts-retry" @click="read">{{ t('contacts.retry') }}</button>
  </div>
  <div v-else-if="show && rows.length" class="people-contacts" data-test="people-contact-rows">
    <h3 class="muted people-contacts__head">{{ t('contacts.group') }}</h3>
    <div v-for="c in rows" :key="c.contact_id" class="nav-row">
      <NuxtLink
        class="nav-item"
        :class="{ active: open === c.contact_id }"
        :aria-current="open === c.contact_id ? 'true' : undefined"
        :data-key="c.contact_id"
        data-test="people-contact-row"
        :to="localePath('/people/contact/' + encodeURIComponent(c.contact_id))"
      >
        <span class="people-contacts__icon"><UiIcon name="user" :size="16" /></span>
        <span class="label">{{ contactName(c) }}</span>
      </NuxtLink>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { contactsList, onContactsChanged } from '~/utils/contacts-client.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { contactName } from '~/utils/people-order.mjs'

defineProps<{ rows: Array<{ contact_id: string }>, show: boolean }>()
const emit = defineEmits<{ list: [contacts: Array<{ contact_id: string, member_id?: string | null }>], refused: [] }>()

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const session = useSessionStore()
const route = useRoute()
const localePath = useLocalePath()
const failed = ref(false)
const open = computed(() => {
  const m = route.path.match(/\/people\/contact\/([^/]+)$/)
  return m ? decodeURIComponent(m[1]) : ''
})

async function read() {
  failed.value = false
  try {
    emit('list', await withSessionRetry(api, () => contactsList(api, String(session.claims?.hum || ''))))
  } catch (e) {
    /* the hub's own "not for you here": the panel goes back to members only */
    const status = (e as { status?: number }).status
    if (status === 403 || status === 404) emit('refused')
    else failed.value = true
  }
}

const off = onContactsChanged(read)
onBeforeUnmount(off)
onMounted(read)
</script>

<style scoped>
.people-contacts__head { margin: 10px 0 4px; padding-inline: 10px; font-size: 0.75rem; font-weight: 600; }
.people-contacts__icon { display: inline-flex; align-items: center; justify-content: center; width: 22px; height: 22px; flex-shrink: 0; color: var(--color-muted); }
</style>
