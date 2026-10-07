<!-- Spec 065 7.2 (owner Q10 yes): the stable link of a release note,
     /releases/<sha>, /releases/<7+ char prefix> or /releases/v<X.Y.Z>. It
     opens the same ReleaseNotesDialog the version card's "Release notes"
     button opens, on that note or that version, so the link and the footer
     show one modal, not two pages.

     Closing it (X, Escape, the phone's Back) goes back to the exact place
     the link was clicked (owner, t1 3385cecb: "proper flow from click"): a
     link followed inside the app steps back to that page; a link opened
     cold (a new tab, a pasted URL) has nothing under it and goes to the
     start page instead, replacing this entry. -->
<template>
  <div class="feed-col" data-test="releases-page">
    <header class="feed-header">
      <MobileBack />
      <h2>{{ t('release_notes.title') }}</h2>
    </header>
    <div class="feed-body" />
    <ReleaseNotesDialog v-model:open="open" :initial-ref="noteRef" />
  </div>
</template>

<script setup lang="ts">
import { mobileOverlayOf } from '~/utils/mobile-stack.mjs'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const router = useRouter()
const localePath = useLocalePath()

const noteRef = computed(() => String(route.params.ref || ''))
const open = ref(true)
/* vue-router's own entry state: `back` is the in-app page this link was
   followed from, null on a cold load. Read in setup, before the dialog (a
   child) pushes its phone overlay entry on top. */
const cameFrom = import.meta.client ? String((window.history.state as { back?: unknown } | null)?.back || '') : ''

/* On a phone the dialog's own history entry (useMobileStack) is stepped over
   first when the X closes it; leave the page only once that is done. */
async function overlayGone() {
  for (let i = 0; i < 20 && mobileOverlayOf(window.history.state); i++) await new Promise((r) => setTimeout(r, 50))
}

watch(open, async (o) => {
  if (o) return
  await overlayGone()
  if (cameFrom) router.back()
  else await navigateTo(localePath('/'), { replace: true })
})
/* a second link followed while here opens the dialog again */
watch(noteRef, () => { open.value = true })
</script>
