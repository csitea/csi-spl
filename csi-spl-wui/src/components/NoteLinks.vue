<!-- Spec 155 2.3 / 2.6 (B7, SPL-4330; SPL-4893): the open note's stored
     links, a compact list under the text with no heading and no paste box
     (owner t1 ba784026: a link typed in the text is linked there, the same
     way as in a discussion). Shown only when the note has links: those added
     before, or by "Add to note" (SPL-4578). Each row: the kind icon, the
     label (else a short ref; "Link to a workspace you left" after a leave,
     D4), the workspace's name when it is not this one, and a remove x. A
     link opens on its workspace's host (utils/note-links.mjs noteLinkHref);
     a url link in a new tab, rel="noopener noreferrer". Loaded with
     NoteDetail, so none of it is first-load JS. -->
<template>
  <section v-if="rows.length" class="note-ln" data-test="note-links" :aria-label="t('notes.links_title')">
    <ul class="note-ln__list">
      <li v-for="r in rows" :key="r.link.id" class="note-ln__row" data-test="note-link" :data-kind="r.link.kind" :data-left="r.link.left ? 'true' : 'false'">
        <span class="note-ln__kind" :title="t('notes.kind.' + r.link.kind)"><UiIcon :name="KIND_ICON[r.link.kind] || 'open'" :size="16" /><span class="sr-only">{{ t('notes.kind.' + r.link.kind) }}</span></span>
        <a
          v-if="r.anchor"
          class="note-ln__a"
          data-test="note-link-open"
          v-bind="r.anchor"
          :title="r.anchor.href"
          @click="open(r.to, $event)"
        >{{ r.text }}</a>
        <span v-else class="note-ln__a note-ln__a--text muted" data-test="note-link-text">{{ r.text }}</span>
        <span v-if="r.wsName" class="note-ln__ws muted" data-test="note-link-ws">{{ r.wsName }}</span>
        <button type="button" class="icon-btn note-ln__remove" data-test="note-link-remove" :aria-label="t('notes.link_remove')" :title="t('notes.link_remove')" @click="remove(r.link.id)">
          <UiIcon name="x" :size="16" />
        </button>
      </li>
    </ul>
    <p v-if="error" class="note-ln__error" role="alert" data-test="note-link-error">{{ t(error) }}</p>
  </section>
</template>

<script setup lang="ts">
import { useNotesStore, type NoteLink } from '~/stores/notes'
import { useSessionStore } from '~/stores/session'
import { hostTenant, useSpoolApi } from '~/composables/useSpoolApi'
import { noteLinkAnchor, noteLinkHref, noteLinkText, type NoteLinkCtx } from '~/utils/note-links.mjs'
import { activeIdIndex, resolveTyped } from '~/utils/id-links.mjs'
import { tenantNamesOf } from '~/utils/app-link-label.mjs'
import type { UiIconName } from '~/utils/uiIcons'

const KIND_ICON: Record<string, UiIconName> = { msg: 'messages', topic: 'list', issue: 'issues', event: 'calendar', doc: 'folder', channel: 'hash', url: 'open' }

const props = defineProps<{ noteId: string, links: NoteLink[] }>()
const emit = defineEmits<{ change: [links: NoteLink[]] }>()
const { t } = useI18n({ useScope: 'global' })
const store = useNotesStore()
const session = useSessionStore()
const router = useRouter()
const localePath = useLocalePath()
const api = useSpoolApi()
const pub = useRuntimeConfig().public

const error = ref('')

/* the page's workspace (its host, else the client's, else the session's) and
   host; siteUrl only with tenant hosts on (app-link-label.mjs) */
const ctx = computed<NoteLinkCtx>(() => ({
  tenant: hostTenant() || String(api.tenant || '') || String(session.claims?.t || ''),
  siteUrl: String(pub.tenantHosts || '0') === '1' ? String(pub.siteUrl || '') : '',
  apexTenant: String(pub.tenant || ''),
  pageOrigin: import.meta.client ? window.location.origin : '',
}))
const names = computed(() => tenantNamesOf(session.claims))

const rows = computed(() => props.links.map((link) => {
  const open = { ...ctx.value, pathFor: (p: string) => localePath(p), typed: (k: string, r: string) => resolveTyped(k, r, activeIdIndex()) }
  const ws = String(link.workspace_id || '')
  return {
    link,
    to: noteLinkHref(link, open),
    /* a link into a workspace the person left opens nothing: its page would refuse */
    anchor: link.left ? null : noteLinkAnchor(link, open),
    text: link.left ? t('notes.link_left') : noteLinkText(link),
    wsName: ws && ws !== ctx.value.tenant ? names.value[ws] || ws : '',
  }
}))

/** A link on this host goes through the router; another host or a new tab is the browser's. */
function open(to: { here: boolean, path: string }, e: MouseEvent) {
  if (!to.here || !to.path || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
  e.preventDefault()
  void router.push(to.path)
}

async function remove(linkId: string) {
  try {
    await store.removeLink(props.noteId, linkId)
    emit('change', props.links.filter((l) => l.id !== linkId))
  } catch {
    error.value = 'notes.not_saved'
  }
}
</script>

<style scoped>
.note-ln__list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.note-ln__row { display: flex; align-items: center; gap: 6px; min-width: 0; min-height: 32px; }
.note-ln__kind { flex: none; color: var(--color-muted); }
.note-ln__a { flex: 0 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.note-ln__ws { flex: none; font-size: 0.8125rem; }
.note-ln__remove { margin-inline-start: auto; flex: none; }
.note-ln__error { margin: 0.25rem 0 0; color: var(--color-danger); }
@media (max-width: 820px) {
  .note-ln__row { min-height: var(--tap, 44px); }
  .note-ln__remove { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
}
</style>
