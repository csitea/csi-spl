<template>
  <!-- spec 116-T5: the links row, under the features row. Plain links, no
       NuxtLink (its chunk would join the first download), and no i18n key
       (one would ship in the core catalogue `/` preloads); the labels are
       the site's own English ones. -->
  <section class="ll" aria-labelledby="ll-title" data-test="login-links">
    <ul class="ll__list">
      <li class="ll__item">
        <a class="ll__link" :href="localePath('/blog')" data-test="login-link-blog">{{ t('auth.login.links.blog') }}</a>
      </li>
      <li class="ll__item">
        <a class="ll__link" :href="localePath('/public-calendar')" data-test="login-link-calendar">{{ t('auth.login.links.calendar') }}</a>
      </li>
      <li class="ll__item">
        <a class="ll__link" :href="localePath('/help')" data-test="login-link-help">{{ t('auth.login.links.help') }}</a>
      </li>
      <li class="ll__item">
        <a class="ll__link" :href="SOURCE_REPO_URL" target="_blank" rel="noopener noreferrer" data-test="login-link-source">{{ t('auth.login.links.source') }}</a>
      </li>
    </ul>
  </section>
</template>

<script setup lang="ts">
import { SOURCE_REPO_URL } from '~/utils/source-repo.mjs'

const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.ll {
  width: 100%;
  min-width: 0;
  text-align: center;
}
.ll__list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 16px;
  font-size: 0.875rem;
}
.ll__item {
  min-width: 0;
}
.ll__link {
  color: var(--color-accent);
  text-decoration: none;
  transition: opacity 0.15s ease;
}
.ll__link:hover {
  opacity: 0.7;
}
/* Phone: one column, compact */
@media (max-width: 480px) {
  .ll__list {
    gap: 12px;
    font-size: 0.8125rem;
  }
}
@media (prefers-reduced-motion: reduce) {
  .ll__link { transition: none; }
  .ll__link:hover { opacity: 1; }
}
</style>
