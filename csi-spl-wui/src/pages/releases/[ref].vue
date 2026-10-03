<!-- Spec 065 7.2 (owner Q10 yes): the stable link of a release note,
     /releases/<sha>, /releases/<7+ char prefix> or /releases/v<X.Y.Z>. It
     opens the same ReleaseNotesDialog the version card's "Release notes"
     button opens, on that note or that version, so the link and the footer
     show one modal, not two pages. Closing it goes to the start page. -->
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
const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()

const noteRef = computed(() => String(route.params.ref || ''))
const open = ref(true)

watch(open, (o) => { if (!o) void navigateTo(localePath('/')) })
/* a second link followed while here opens the dialog again */
watch(noteRef, () => { open.value = true })
</script>
