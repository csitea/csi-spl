// Every locale lists this file second, with `cache: false` (nuxt.config.ts,
// I18N_MODULE_LOCALES). @nuxtjs/i18n 10.6 then counts each locale as
// "dynamic", and a generated build loads its catalogues through the module's
// client loaders: the JSON the build precompiled, in the app's own chunks.
// Without it the client fetches /_i18n/<hash>/<locale>/messages.json, raw
// source strings that this runtime-only vue-i18n (no message compiler) shows
// as "Acting as {name}" (SPL-5070; was __I18N_FULL_STATIC__ on 10.2).
// It adds no messages.
export default defineI18nLocale(() => ({}))
