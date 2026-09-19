<template>
  <NuxtLayout>
    <NuxtPage />
  </NuxtLayout>
</template>

<script setup lang="ts">
// Site-wide head, shaped like the donor WUI's app.vue: the version stamp is a
// <meta name="version"> so a deployed page says which build it is without a
// fetch, and the document lang/dir + hreflang alternates come from
// useLocaleHead exactly as the donor does (spec 021). The rest of the SEO
// shell is left out on purpose — the WUI is noindex.
const appVersion = String(useRuntimeConfig().public.appVersion || '')

const { locale } = useI18n({ useScope: 'global' })

const rtlLocales: Record<string, true> = { he: true }

// @nuxtjs/i18n v9: options are { dir, lang, seo, key } — not the v8 add* names.
const i18nHead = useLocaleHead({
  dir: true,
  lang: true,
  seo: true,
})

function docDir(): 'ltr' | 'rtl' {
  const fromI18n = i18nHead.value.htmlAttrs?.dir
  if (fromI18n === 'rtl' || fromI18n === 'ltr') return fromI18n
  return rtlLocales[locale.value] ? 'rtl' : 'ltr'
}

useHead(() => ({
  htmlAttrs: {
    lang: i18nHead.value.htmlAttrs?.lang || locale.value,
    dir: docDir(),
  },
  link: [...(i18nHead.value.link || [])],
  meta: appVersion ? [{ name: 'version', content: appVersion }] : [],
}))
</script>
