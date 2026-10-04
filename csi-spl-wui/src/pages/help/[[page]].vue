<!-- /help and /help/<page> (W14, spec 047, SPL-1169): the help pages of
     csi-spl-doc/doc/help, served from the copy in public/help-md (see
     src/node/help/sync-help.mjs). /help is the index page; a sibling link
     (./x.md) opens /help/x in this tab. Signed in or not: the help is not a
     product screen, so a stranger on the sign-in page reaches it too.
     At <= 820 px the page list hides; the index page lists every page.
     t1 67f91532 (owner): help is TWO panes on a desktop, the page list left
     and the document right; the sidebar keeps its icon rail only
     (ChannelSidebar helpRailOnly) and a topic panel open beside the channel
     the reader came from closes. Each pane scrolls on its own (the page
     body does not). The document column is centred on the viewport. -->
<template>
  <div class="feed-col">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 id="help-h">{{ t('help.title') }}</h2>
      <SectionClose side="end" />
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
import { fillHelpHosts, helpRepoBase, hostOf, rewriteHelpLinks, validHelpSlug } from '~/utils/help.mjs'
import { boxHubUrl } from '~/utils/connect-agent.mjs'
import { useTopicStore } from '~/stores/topic'
import { useLiveFeed } from '~/stores/live'

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
    /* cnf env.wui.repo_web_url + repo_help_path; unset = repo links hidden */
    const pub = useRuntimeConfig().public
    text.value = rewriteHelpLinks(fillHelpHosts(md, hosts()), route, helpRepoBase(pub.repoWebUrl, pub.repoHelpPath))
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
/* t1 67f91532 (owner: "if one clicks from the channel view - of course the
   3rd panel with the content of the channel view should be closed"): no
   topic panel sits beside help, whichever store holds it */
const topic = useTopicStore()
const livePane = useLiveFeed('pane')
function closeTopicPanel() {
  if (livePane.taskId) livePane.close()
  if (topic.open) topic.close()
}
watch(() => [livePane.taskId, topic.open], closeTopicPanel)
onMounted(closeTopicPanel)
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
/* Desktop only. The page body stops scrolling and each pane scrolls on its
   own. The document is centred on the viewport: 72-80ch is wider than the
   slot that stays clear of the list (the list ends near 315px, and a
   centred column has to start at or after about 336px, so the widest
   centred column at 1440px is about 760px, 66ch at the default font).
   Where that column would cover the list, it moves to --help-safe and
   narrows to the room that is left, and the list stays visible. The phone
   rule below is unchanged. */
@media (min-width: 821px) {
  .settings-page {
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .help-layout {
    flex: 1 1 auto;
    min-height: 0;
    align-items: stretch;
    grid-template-rows: minmax(0, 1fr);
  }
  .help-nav {
    min-height: 0;
    overflow-x: clip;
    overflow-y: auto;
    overscroll-behavior: contain;
  }
  .help-content {
    --help-safe: 336px;
    --help-doc: min(66ch, 760px);
    position: fixed;
    z-index: 1;
    margin: 0;
    width: min(var(--help-doc), calc(100vw - var(--help-safe) - 16px));
    max-width: min(var(--help-doc), calc(100vw - var(--help-safe) - 16px));
    left: max(var(--help-safe), calc(50% - min(66ch, 760px) / 2));
    right: auto;
    /* header is 57px under the 58px top bar; the body pads 16px above and 8px below */
    top: calc(var(--top-bar-h) + 73px);
    bottom: 8px;
    overflow-x: clip;
    overflow-y: auto;
    overscroll-behavior: contain;
  }
}
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
