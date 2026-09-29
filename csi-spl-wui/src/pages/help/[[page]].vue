<!-- /help and /help/<page> (W14, spec 047, SPL-1169): the help pages of
     csi-spl-doc/doc/help, served from the copy in public/help-md (see
     src/node/help/sync-help.mjs). /help is the index page; a sibling link
     (./x.md) opens /help/x in this tab. Signed in or not: the help is not a
     product screen, so a stranger on the sign-in page reaches it too.
     At <= 820 px the page list hides; the index page lists every page. -->
<template>
  <div class="feed-col">
    <header class="feed-header">
      <MobileBack />
      <h2 id="help-h">{{ t('help.title') }}</h2>
    </header>
    <div class="feed-body settings-page" data-test="help">
      <div class="settings-layout help-layout">
        <nav class="settings-nav help-nav" :aria-label="t('help.nav_label')" data-test="help-nav">
          <ul>
            <li>
              <NuxtLink
                :to="route('')"
                class="settings-nav__link"
                :class="{ 'settings-nav__link--active': !slug }"
                :aria-current="!slug ? 'page' : undefined"
                data-test="help-nav-index"
              >{{ t('help.index') }}</NuxtLink>
            </li>
            <li v-for="p in pages" :key="p.slug">
              <NuxtLink
                :to="route(p.slug)"
                class="settings-nav__link"
                :class="{ 'settings-nav__link--active': slug === p.slug }"
                :aria-current="slug === p.slug ? 'page' : undefined"
                :data-test="'help-nav-' + p.slug"
              >{{ p.title }}</NuxtLink>
            </li>
          </ul>
        </nav>
        <article class="settings-content help-content" aria-labelledby="help-h" data-test="help-content" :data-page="slug || 'index'">
          <p v-if="state === 'loading'" class="muted">{{ t('common.loading') }}</p>
          <p v-else-if="state === 'missing'" class="muted" role="alert" data-test="help-missing">{{ t('help.not_found') }}</p>
          <p v-else-if="state === 'failed'" class="muted" role="alert" data-test="help-failed">{{ t('help.load_failed') }}</p>
          <MarkdownBlock v-else :text="text" bare />
        </article>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import MarkdownBlock from '~/components/MarkdownBlock.vue'
import { fillHelpHosts, hostOf, rewriteHelpLinks, validHelpSlug } from '~/utils/help.mjs'
import { boxHubUrl } from '~/utils/connect-agent.mjs'

type HelpPage = { slug: string, title: string }

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const current = useRoute()
const slug = computed(() => {
  const p = current.params.page
  return typeof p === 'string' ? p : ''
})
const route = (s: string) => localePath(s ? '/help/' + s : '/help')
const pages = ref<HelpPage[]>([])
const text = ref('')
const state = ref<'loading' | 'ready' | 'missing' | 'failed'>('loading')
const pub = useRuntimeConfig().public
/* the copy names hosts as {{api}} / {{site}}: this deployment's own */
function hosts() {
  const origin = import.meta.client ? window.location.origin : ''
  return {
    api: hostOf(boxHubUrl(String(pub.apiBase || ''), origin, '')),
    site: hostOf(String(pub.siteUrl || '')) || hostOf(origin),
  }
}

async function getText(path: string): Promise<string | null> {
  const r = await fetch(path, { cache: 'no-cache' })
  if (r.status === 404) return null
  if (!r.ok) throw new Error('help ' + r.status)
  return r.text()
}

let seq = 0
async function load() {
  const mine = ++seq
  const s = slug.value
  state.value = 'loading'
  if (s && !validHelpSlug(s)) { state.value = 'missing'; return }
  try {
    const md = await getText(`/help-md/${s || 'index'}.md`)
    if (mine !== seq) return
    /* the SPA fallback answers an unknown file with the app shell, not a 404 */
    if (md === null || /^\s*<!doctype html/i.test(md)) { state.value = 'missing'; return }
    text.value = rewriteHelpLinks(fillHelpHosts(md, hosts()), route)
    state.value = 'ready'
  } catch {
    if (mine === seq) state.value = 'failed'
  }
}

onMounted(async () => {
  try {
    const list = await getText('/help-md/pages.json')
    const body = list ? JSON.parse(list) : null
    pages.value = Array.isArray(body?.pages) ? body.pages.filter((p: HelpPage) => validHelpSlug(p?.slug) && typeof p.title === 'string') : []
  } catch {
    /* no list: the index page still links every page */
  }
})
watch(slug, () => { if (import.meta.client) void load() })
onMounted(() => { void load() })
useHead(() => ({ title: t('help.title') }))
</script>

<style scoped>
/* the Settings pages' list + content layout (pages/settings.vue) */
.settings-layout {
  display: grid;
  grid-template-columns: minmax(160px, 240px) minmax(0, 1fr);
  gap: 24px;
  align-items: start;
  min-width: 0;
}
.settings-nav ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.settings-nav__link {
  display: flex;
  align-items: center;
  min-height: 36px;
  padding: 6px 12px;
  border-radius: var(--radius-sm, 8px);
  border-inline-start: 3px solid transparent;
  color: var(--color-text);
  text-decoration: none;
  overflow-wrap: anywhere;
}
.settings-nav__link:hover { background: var(--color-bg-2); }
.settings-nav__link--active {
  background: var(--color-selected);
  border-inline-start-color: var(--focus-ring);
  font-weight: 600;
}
.settings-content { min-width: 0; display: flex; flex-direction: column; gap: 16px; }
.help-content { max-width: 820px; }
.help-content :deep(h1) { font-size: 1.5rem; margin: 0 0 0.5em; }
.help-content :deep(h2) { font-size: 1.2rem; margin: 1.2em 0 0.4em; }
.help-content :deep(h3) { font-size: 1.05rem; margin: 1em 0 0.3em; }
.help-content :deep(hr) { border: 0; border-top: 1px solid var(--color-border); margin: 1.2em 0; }
/* the index page lists every page; on a phone the list would repeat it */
@media (max-width: 820px) {
  .settings-layout { grid-template-columns: minmax(0, 1fr); gap: 12px; }
  .help-layout .help-nav { display: none; }
}
</style>
