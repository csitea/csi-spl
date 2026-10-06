<!-- Owner 2026-09-27 (topic 38ba1dae): the top-bar logo is small; a click
     opens it in the centre of the screen, with the slogan "spool-hub - where
     humans and ai meet". Loaded lazily (LazyLogoDialog): the picture is
     fetched only when the dialog opens.
     SPL-1150 (owner, topic 3d6c9caf): "more stylish ... a bit smaller modal
     dialog box" and "it should contain a short description of what spool-hub
     is". A compact UiDialog `card` (fades in, none under reduced motion): the
     picture, the slogan, what spool-hub is, the running version and the links
     to the public source and its docs. The X follows SPL-1133.
     Owner (topic 87eaa57b): the picture ships at the size it is shown -
     560 px wide (.logo-card__img max-width) and 1120 px for 2x screens -
     as AVIF with a WebP fallback, not the 1920 px original (270 KB). -->
<template>
  <UiDialog :open="open" :title="t('logo.open')" size="card" @update:open="emit('update:open', $event)">
    <div class="logo-card" data-testid="logo-dialog">
      <figure class="logo-card__fig">
        <picture class="logo-card__pic">
          <source type="image/avif" srcset="/spool-hub-emblem-560.avif 1x, /spool-hub-emblem-1120.avif 2x">
          <img
            class="logo-card__img"
            src="/spool-hub-emblem-560.webp"
            srcset="/spool-hub-emblem-560.webp 1x, /spool-hub-emblem-1120.webp 2x"
            width="560"
            height="305"
            :alt="t('logo.slogan')"
            decoding="async"
            data-testid="logo-dialog-img"
          >
        </picture>
        <figcaption class="logo-card__slogan" data-testid="logo-dialog-slogan">
          <strong>spool-hub</strong> - {{ t('logo.slogan') }}
        </figcaption>
      </figure>
      <p class="logo-card__about" data-testid="logo-dialog-about">{{ t('logo.about') }}</p>
      <div class="logo-card__meta">
        <span class="logo-card__version" data-testid="logo-dialog-version">
          {{ t('logo.version') }} <code>{{ version }}</code>
        </span>
        <span class="logo-card__links">
          <a :href="SOURCE_URL" target="_blank" rel="noopener noreferrer" data-testid="logo-dialog-source">{{ t('logo.source') }}</a>
          <a :href="DOCS_URL" target="_blank" rel="noopener noreferrer" data-testid="logo-dialog-docs">{{ t('logo.docs') }}</a>
        </span>
      </div>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import { displayVersion } from '~/utils/display-version.mjs'
defineProps<{ open: boolean }>()
const emit = defineEmits<{ 'update:open': [boolean] }>()
const { t } = useI18n()

/* the public repository (spec 044: one public repo) and its help pages */
const SOURCE_URL = 'https://github.com/csitea/csi-spl'
const DOCS_URL = 'https://github.com/csitea/csi-spl/tree/master/csi-spl-doc/doc/help'
const version = computed(() => displayVersion(String(useRuntimeConfig().public.appVersion || '').trim() || 'dev'))
</script>

<style scoped>
.logo-card {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 14px;
  padding: 8px 28px 22px;
  text-align: center;
}
.logo-card__fig {
  margin: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 12px;
  width: 100%;
}
/* the <picture> wrapper takes no box: the img stays the flex item */
.logo-card__pic { display: contents; }
.logo-card__img {
  display: block;
  width: 100%;
  max-width: 560px;
  max-height: 38vh;
  height: auto;
  object-fit: contain;
  border-radius: var(--radius-md);
}
.logo-card__slogan {
  font-size: 1.25rem;
  line-height: 1.35;
  color: var(--color-heading, var(--color-fg));
}
.logo-card__slogan strong { color: var(--color-accent); font-weight: 700; }
.logo-card__about {
  margin: 0;
  max-width: 56ch;
  font-size: 0.9375rem;
  line-height: 1.55;
  color: var(--color-muted);
  overflow-wrap: anywhere;
}
.logo-card__meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 8px 16px;
  width: 100%;
  margin-top: 4px;
  padding-top: 14px;
  border-top: 1px solid var(--color-border);
  font-size: 0.8125rem;
  color: var(--color-muted);
}
.logo-card__version code {
  padding: 2px 8px;
  border-radius: var(--radius-pill);
  background: var(--color-bg-2);
  color: var(--color-fg);
  font-size: 0.75rem;
}
.logo-card__links { display: inline-flex; flex-wrap: wrap; gap: 4px 16px; }
.logo-card__links a {
  color: var(--color-accent);
  font-weight: 600;
  text-decoration: none;
}
.logo-card__links a:hover { text-decoration: underline; }
/* a phone: the dialog is a full screen - centre the card in it */
@media (max-width: 600px) {
  .logo-card { min-height: 100%; justify-content: center; padding: 16px 16px 24px; }
  .logo-card__meta { justify-content: center; }
}
</style>
