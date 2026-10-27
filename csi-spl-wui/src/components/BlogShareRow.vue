<!-- Reusable share row component for blog posts. -->
<!-- Props:
  - testIdSuffix: string (required), distinguishes the two rows (-top or -end).
  - shareTitle: string (required), the post title.
  - sharePageUrl: string (required), the post URL.
-->
<template>
  <div class="bpost__share" role="group" :aria-label="t('blog.share')" :data-test="`blog-share-${testIdSuffix}`">
    <template v-for="c in shareControls" :key="c.id">
      <button
        v-if="c.id === 'copy'"
        type="button"
        class="bpost__share-btn"
        :class="{ 'is-copied': copiedId === c.id }"
        :data-test="`blog-share-${c.id}-${testIdSuffix}`"
        :aria-label="shareLabel(c.id)"
        :title="shareLabel(c.id)"
        @click="copyShareLink()"
      >
        <svg class="bpost__share-icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true">
          <path v-if="copiedId === c.id" d="M20 6 9 17l-5-5" />
          <template v-else>
            <path v-for="(d, i) in c.paths" :key="i" :d="d" />
          </template>
        </svg>
      </button>
      <a
        v-else
        class="bpost__share-btn"
        :class="{ 'is-copied': copiedId === c.id }"
        :data-test="`blog-share-${c.id}-${testIdSuffix}`"
        :href="c.href"
        target="_blank"
        rel="noopener"
        :aria-label="shareLabel(c.id)"
        :title="shareLabel(c.id)"
        @click="onShareClick(c.id)"
      >
        <svg class="bpost__share-icon" :class="{ 'is-fill': c.fill && copiedId !== c.id }" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true">
          <path v-if="copiedId === c.id" d="M20 6 9 17l-5-5" />
          <template v-else>
            <path v-for="(d, i) in c.paths" :key="i" :d="d" />
          </template>
        </svg>
      </a>
    </template>
    <button
      v-if="canNativeShare"
      type="button"
      class="bpost__share-btn"
      :data-test="`blog-share-native-${testIdSuffix}`"
      :aria-label="t('blog.share')"
      :title="t('blog.share')"
      @click="shareNative"
    >
      <svg class="bpost__share-icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" aria-hidden="true">
        <circle cx="18" cy="5" r="3" />
        <circle cx="6" cy="12" r="3" />
        <circle cx="18" cy="19" r="3" />
        <line x1="8.59" y1="13.51" x2="15.42" y2="17.49" />
        <line x1="15.41" y1="6.51" x2="8.59" y2="10.49" />
      </svg>
    </button>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, onBeforeUnmount } from 'vue'
import { useI18n } from '#imports'
import { BLOG_SHARE_ORDER, SUBSTACK_NOTES, blogShareHref } from '~/utils/blog-share.mjs'
import { instagramCaption } from '~/utils/marketing-share-links.mjs'
import { writeClipboard } from '~/utils/clipboard.mjs'

const { t } = useI18n({ useScope: 'global' })

const props = defineProps({
  testIdSuffix: { type: String, required: true },
  shareTitle: { type: String, required: true },
  sharePageUrl: { type: String, required: true },
})

const SHARE_ICONS: Record<string, { fill: boolean, paths: string[] }> = {
  copy: { fill: false, paths: [
    'M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71',
    'M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71',
  ] },
  linkedin: { fill: true, paths: ['M19 0h-14c-2.761 0-5 2.239-5 5v14c0 2.761 2.239 5 5 5h14c2.762 0 5-2.239 5-5v-14c0-2.761-2.238-5-5-5zm-11 19h-3v-11h3v11zm-1.5-12.268c-.966 0-1.75-.79-1.75-1.764s.784-1.764 1.75-1.764 1.75.79 1.75 1.764-.783 1.764-1.75 1.764zm13.5 12.268h-3v-5.604c0-3.368-4-3.113-4 0v5.604h-3v-11h3v1.765c1.396-2.586 7-2.777 7 2.476v6.759z'] },
  facebook: { fill: true, paths: ['M9 8h-3v4h3v12h5v-12h3.642l.358-4h-4v-1.667c0-.955.192-1.333 1.115-1.333h2.885v-5h-3.808c-3.596 0-5.192 1.583-5.192 4.615v3.385z'] },
  instagram: { fill: false, paths: [
    'M7 2h10a5 5 0 0 1 5 5v10a5 5 0 0 1-5 5H7a5 5 0 0 1-5-5V7a5 5 0 0 1 5-5z',
    'M16 11.37A4 4 0 1 1 12.63 8 4 4 0 0 1 16 11.37z',
    'M17.5 6.5h.01',
  ] },
  viber: { fill: false, paths: [
    'M12 2C6.5 2 3 5.1 3 10c0 2.7 1 4.6 2.7 5.9V21l3.6-2.4c.9.2 1.8.3 2.7.3 5.5 0 9-3.1 9-8.4S17.5 2 12 2z',
    'M8.5 7.5c.3 2.8 2.6 5.4 5.6 6.2l1-1.2-1.6-1-.8.6c-1-.5-1.9-1.4-2.4-2.4l.6-.8-1-1.6z',
    'M13 6.5a3 3 0 0 1 3 3',
    'M13 4.5a5 5 0 0 1 5 5',
  ] },
  x: { fill: true, paths: ['M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.21l-5.21-6.817L4.978 21.75H1.67l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z'] },
  whatsapp: { fill: true, paths: ['M.057 24l1.687-6.163c-1.041-1.804-1.588-3.849-1.587-5.946.003-6.556 5.338-11.891 11.893-11.891 3.181.001 6.167 1.24 8.413 3.488 2.245 2.248 3.481 5.236 3.48 8.414-.003 6.557-5.338 11.892-11.893 11.892-1.99-.001-3.951-.5-5.688-1.448l-6.305 1.654zm6.597-3.807c1.676.995 3.276 1.591 5.392 1.592 5.448 0 9.886-4.434 9.889-9.885.002-5.462-4.415-9.89-9.881-9.892-5.452 0-9.887 4.434-9.889 9.884-.001 2.225.651 3.891 1.746 5.634l-.999 3.648 3.742-.981zm11.387-5.464c-.074-.124-.272-.198-.57-.347-.297-.149-1.758-.868-2.031-.967-.272-.099-.47-.149-.669.149-.198.297-.768.967-.941 1.165-.173.198-.347.223-.644.074-.297-.149-1.255-.462-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.297-.347.446-.521.151-.172.2-.296.3-.495.099-.198.05-.372-.025-.521-.075-.148-.669-1.611-.916-2.206-.242-.579-.487-.501-.669-.51l-.57-.01c-.198 0-.52.074-.792.372s-1.04 1.016-1.04 2.479 1.065 2.876 1.213 3.074c.149.198 2.095 3.2 5.076 4.487.709.306 1.263.489 1.694.626.712.226 1.36.194 1.872.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.289.173-1.413z'] },
  telegram: { fill: true, paths: ['M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z'] },
  reddit: { fill: true, paths: ['M12 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0zm5.01 4.744c.688 0 1.25.561 1.25 1.249a1.25 1.25 0 0 1-2.498.056l-2.597-.547-.8 3.747c1.824.07 3.48.632 4.674 1.488.308-.309.73-.491 1.207-.491.968 0 1.754.786 1.754 1.754 0 .716-.435 1.333-1.01 1.614a3.111 3.111 0 0 1 .042.52c0 2.694-3.13 4.87-7.004 4.87-3.874 0-7.004-2.176-7.004-4.87 0-.183.015-.366.043-.534A1.748 1.748 0 0 1 4.028 12c0-.968.786-1.754 1.754-1.754.463 0 .898.196 1.207.49 1.207-.883 2.878-1.43 4.744-1.487l.885-4.182a.342.342 0 0 1 .14-.197.35.35 0 0 1 .238-.042l2.906.617a1.214 1.214 0 0 1 1.108-.701zM9.25 12C8.561 12 8 12.562 8 13.25c0 .687.561 1.248 1.25 1.248.687 0 1.248-.561 1.248-1.249 0-.688-.561-1.249-1.249-1.249zm5.5 0c-.687 0-1.248.561-1.248 1.25 0 .687.561 1.248 1.249 1.248.688 0 1.249-.561 1.249-1.249 0-.687-.562-1.249-1.25-1.249zm-5.466 3.99a.327.327 0 0 0-.231.094.33.33 0 0 0 0 .463c.842.842 2.484.913 2.961.913.477 0 2.105-.056 2.961-.913a.361.361 0 0 0 .029-.463.33.33 0 0 0-.464 0c-.547.533-1.684.73-2.512.73-.828 0-1.979-.196-2.512-.73a.326.326 0 0 0-.232-.095z'] },
  substack: { fill: true, paths: ['M22.539 8.242H1.46V5.406h21.08v2.836zM1.46 10.812V24L12 18.11 22.54 24V10.812H1.46zM22.54 0H1.46v2.836h21.08V0z'] },
  email: { fill: false, paths: [
    'M4 4h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z',
    'M22 6l-10 7L2 6',
  ] },
}

const canNativeShare = ref(false)
const shareControls = computed(() => BLOG_SHARE_ORDER.map((id) => {
  const icon = SHARE_ICONS[id] || { fill: false, paths: [] as string[] }
  const href = id === 'substack'
    ? SUBSTACK_NOTES
    : (blogShareHref(id, { url: props.sharePageUrl, title: props.shareTitle }) || '')
  return { id, href, fill: icon.fill, paths: icon.paths }
}))

function shareLabel(id: string): string {
  switch (id) {
    case 'copy': return t('blog.copy_link')
    case 'linkedin': return t('blog.share_linkedin')
    case 'facebook': return t('blog.share_facebook')
    case 'instagram': return t('blog.share_instagram')
    case 'x': return t('blog.share_x')
    case 'whatsapp': return t('blog.share_whatsapp')
    case 'viber': return t('blog.share_viber')
    case 'telegram': return t('blog.share_telegram')
    case 'reddit': return t('blog.share_reddit')
    case 'substack': return t('blog.share_substack')
    case 'email': return t('blog.share_email')
    default: return t('blog.share')
  }
}

const copiedId = ref('')
let copiedTimer: ReturnType<typeof setTimeout> | undefined

async function copyShareLink(which = 'copy', text = props.sharePageUrl) {
  if (!props.sharePageUrl || !text) return
  const ok = await writeClipboard(text)
  if (!ok) return
  copiedId.value = which
  if (copiedTimer) clearTimeout(copiedTimer)
  copiedTimer = setTimeout(() => { copiedId.value = '' }, 1600)
}

// Substack and Instagram take no share URL: the click copies what to paste
// there (the link; Instagram's caption, spec 090 T037) and opens the site.
function onShareClick(id: string) {
  if (id === 'substack') void copyShareLink('substack')
  if (id === 'instagram') void copyShareLink('instagram', instagramCaption({ url: props.sharePageUrl, title: props.shareTitle }))
}

async function shareNative() {
  const url = props.sharePageUrl
  if (!url) return
  try {
    await navigator.share({ title: props.shareTitle, url })
  } catch { /* the visitor closed the sheet */ }
}

onBeforeUnmount(() => {
  if (copiedTimer) clearTimeout(copiedTimer)
})
</script>

<style scoped>
/* Eleven controls and Web Share stay on one line on a 390 px phone: the
   buttons shrink to 26 px and the gap narrows rather than wrap. The class is
   doubled because pages/blog.vue still styles this root element with its
   own scoped .bpost__share (flex-wrap: wrap), which would otherwise win. */
.bpost__share.bpost__share {
  display: flex;
  flex-wrap: nowrap;
  align-items: center;
  gap: 4px;
  max-width: 100%;
  min-width: 0;
}
@media (max-width: 480px) {
  .bpost__share.bpost__share {
    gap: 2px;
  }
}
.bpost__share-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: 0 1 32px;
  width: 32px;
  min-width: 26px;
  max-width: 32px;
  height: 32px;
  padding: 0;
  border: 0;
  border-radius: var(--radius-md);
  background: transparent;
  color: var(--color-muted);
  font: inherit;
  line-height: 1;
  text-decoration: none;
  cursor: pointer;
}
.bpost__share-btn:hover,
.bpost__share-btn:focus-visible {
  background: var(--color-surface-hover);
  color: var(--color-fg);
}
.bpost__share-btn.is-copied {
  color: var(--color-fg);
}
.bpost__share-icon {
  width: 16px;
  height: 16px;
  flex: none;
  fill: none;
  stroke: currentColor;
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.bpost__share-icon.is-fill {
  fill: currentColor;
  stroke: none;
}
</style>
