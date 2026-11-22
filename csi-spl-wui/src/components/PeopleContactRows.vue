<!-- Spec 154 B9 (2.7): group 3 of the People panel, the reader's contacts who
     are no member here, and the list's one read. A lazy chunk with
     contacts-client.mjs, mounted when the panel first opens, so the initial
     download never carries it (C25). It stays mounted under the "In this
     workspace" filter: the parent still needs the list for the "contact" tags.
     Spec 154 B17 (11.4): a row with a picture shows it, on screen only: a row
     asks when it scrolls into view (IntersectionObserver), at most 4 at once
     (contactPhoto), one fetch per sha256 for the page's life, as a data: URL. -->
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
        <span :ref="(el) => watchRow(el as Element | null, c)" class="people-contacts__icon">
          <img v-if="pics[picKey(c)]" :src="pics[picKey(c)]" alt="" class="people-contacts__pic" data-test="people-contact-photo">
          <UiIcon v-else name="user" :size="16" />
        </span>
        <span class="label">{{ contactName(c) }}</span>
      </NuxtLink>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { loadAvatarImageUrl } from '~/utils/avatar'
import { contactPhoto, contactsList, onContactsChanged } from '~/utils/contacts-client.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { contactName } from '~/utils/people-order.mjs'

type Row = { contact_id: string, photo?: string | null }
defineProps<{ rows: Row[], show: boolean }>()
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

/* the pictures by contact_id and sha256, so a changed picture is asked again */
const pics = reactive<Record<string, string>>({})
const asked = new Set<string>()
const rowOf = new WeakMap<Element, Row>()
let seen: IntersectionObserver | null = null
const picKey = (c: Row) => `${c.contact_id}|${c.photo || ''}`

async function showPic(c: Row) {
  const key = picKey(c)
  if (asked.has(key)) return
  asked.add(key)
  const src = await contactPhoto(api, c, loadAvatarImageUrl)
  if (src) pics[key] = src
}

function onSeen(entries: IntersectionObserverEntry[]) {
  for (const e of entries) {
    const c = e.isIntersecting ? rowOf.get(e.target) : undefined
    if (!c) continue
    seen?.unobserve(e.target)
    void showPic(c)
  }
}

/* a row with a picture not asked yet waits until it is on screen */
function watchRow(el: Element | null, c: Row) {
  if (!el || !c.photo || asked.has(picKey(c))) return
  if (typeof IntersectionObserver !== 'function') return void showPic(c)
  seen ??= new IntersectionObserver(onSeen)
  rowOf.set(el, c)
  seen.observe(el)
}

const off = onContactsChanged(read)
onBeforeUnmount(() => {
  off()
  seen?.disconnect()
})
onMounted(read)
</script>

<style scoped>
.people-contacts__head { margin: 10px 0 4px; padding-inline: 10px; font-size: 0.75rem; font-weight: 600; }
.people-contacts__icon { display: inline-flex; align-items: center; justify-content: center; width: 22px; height: 22px; flex-shrink: 0; color: var(--color-muted); }
.people-contacts__pic { width: 22px; height: 22px; border-radius: 50%; object-fit: cover; }
</style>
