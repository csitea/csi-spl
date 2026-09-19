<template>
  <div class="lang-switcher" data-test="lang-switcher">
    <!--
      Preference persistence (donor WUI parity, Nuxt-native):
      - Primary: cookie `i18n_redirected`, written by plugins/locale-cookie.client.ts
        on every locale change and read by the root redirect script
        (utils/rootLocaleRedirect.mjs) before `/` hydrates.
      - Mirror: localStorage key `csi-spl-lang` on change (client-only) so SPA
        revisits keep the choice even if the cookie path differs; does not
        override the module's cookie-driven redirect on first paint.

      UX: Headless UI Combobox (keyboard + a11y). Filter activates only after
      ≥2 characters typed; 0–1 characters shows the full locale list.
      Matching (src/utils/localeSearch.ts) covers the endonym shown in the
      list, the locale code, the English exonym and the IETF tag / region
      subtag, case- and diacritic-insensitively — so "eng" finds English
      from any locale and "se" finds Swedish.

      A signed-in human's stored preference (LanguageSetting.vue, Settings)
      is applied once after sign-in by plugins/preferred-locale.client.ts;
      this header control switches the UI only, like the donor's.
    -->
    <Combobox
      as="div"
      class="lang-switcher__combobox"
      :model-value="selectedLocale"
      by="code"
      nullable
      @update:model-value="onSelect"
    >
      <ComboboxLabel class="visually-hidden">
        {{ t('nav.lang_label') }}
      </ComboboxLabel>
      <div class="lang-switcher__control">
        <ComboboxInput
          class="lang-switcher__input"
          data-test="lang-switcher-input"
          :display-value="displayLocale"
          :placeholder="t('nav.lang_search_placeholder')"
          :aria-label="t('nav.lang_label')"
          :title="t('nav.lang_note')"
          autocomplete="off"
          @change="onQueryChange"
          @focus="onFocus"
          @mouseup="onMouseUp"
          @blur="onBlur"
        />
        <ComboboxButton
          class="lang-switcher__button"
          data-test="lang-switcher-button"
          :aria-label="t('nav.lang_label')"
        >
          <span class="lang-switcher__chevron" aria-hidden="true">▾</span>
        </ComboboxButton>
      </div>
      <ComboboxOptions
        class="lang-switcher__options"
        data-test="lang-switcher-options"
      >
        <li
          v-if="filteredLocales.length === 0"
          class="lang-switcher__empty"
          data-test="lang-switcher-no-matches"
          role="status"
          aria-live="polite"
        >
          {{ t('nav.lang_no_matches') }}
        </li>
        <ComboboxOption
          v-for="loc in filteredLocales"
          :key="loc.code"
          v-slot="{ active, selected }"
          as="template"
          :value="loc"
        >
          <li
            class="lang-switcher__option"
            :class="{
              'lang-switcher__option--active': active,
              'lang-switcher__option--selected': selected,
            }"
            :data-test="`lang-item-${loc.code}`"
          >
            <span class="lang-switcher__flag" aria-hidden="true">{{ loc.flag }}</span>
            <span class="lang-switcher__name">{{ loc.name }}</span>
            <span class="lang-switcher__code">{{ loc.code }}</span>
          </li>
        </ComboboxOption>
      </ComboboxOptions>
    </Combobox>
    <p class="lang-switcher__hint" data-test="lang-switcher-hint" aria-hidden="true">
      {{ t('nav.lang_note') }}
    </p>
  </div>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue'
import {
  Combobox,
  ComboboxButton,
  ComboboxInput,
  ComboboxLabel,
  ComboboxOption,
  ComboboxOptions,
} from '@headlessui/vue'
import { filterLocales, normalizeLocaleQuery } from '@/utils/localeSearch'

type LocaleCode = 'bg' | 'fi' | 'ru' | 'en' | 'sv' | 'he' | 'tr' | 'mk' | 'el' | 'lt' | 'et' | 'lv' | 'sr' | 'ro' | 'uk' | 'sk' | 'pl' | 'es' | 'nl'

interface LocaleEntry {
  code: LocaleCode
  name: string
  flag: string
  /** Full IETF tag (`sv-SE`); searchable so region codes work too. */
  iso?: string
}

/** Flag emoji per configured locale (native name comes from i18n locale config). */
const LOCALE_FLAGS: Record<LocaleCode, string> = {
  bg: '🇧🇬',
  fi: '🇫🇮',
  sv: '🇸🇪',
  en: '🇬🇧',
  ru: '🇷🇺',
  he: '🇮🇱',
  tr: '🇹🇷',
  mk: '🇲🇰',
  el: '🇬🇷',
  lt: '🇱🇹',
  et: '🇪🇪',
  lv: '🇱🇻',
  sr: '🇷🇸',
  ro: '🇷🇴',
  uk: '🇺🇦',
  sk: '🇸🇰',
  pl: '🇵🇱',
  es: '🇪🇸',
  nl: '🇳🇱',
}

const LS_KEY = 'csi-spl-lang'

const { locales, locale: currentLocale, t } = useI18n({ useScope: 'global' })
const switchLocalePath = useSwitchLocalePath()

const query = ref('')
/** True between focus and the click that would collapse the focus selection. */
let keepFocusSelection = false

const availableLocales = computed<LocaleEntry[]>(() =>
  // `language` is the @nuxtjs/i18n v9 name for what the config calls `iso`;
  // read both so the IETF tag stays searchable across module versions.
  (locales.value as Array<{ code: string; name?: string; iso?: string; language?: string }>).map(l => ({
    code: l.code as LocaleCode,
    name: l.name ?? l.code,
    flag: LOCALE_FLAGS[l.code as LocaleCode] ?? '🌐',
    iso: l.language ?? l.iso,
  })),
)

const selectedLocale = computed<LocaleEntry | null>(() =>
  availableLocales.value.find(l => l.code === currentLocale.value) ?? null,
)

/**
 * 0–1 characters: full list (user can open and scroll/keyboard-nav).
 * ≥FILTER_MIN_CHARS (2): fold-insensitive match on endonym, code or English
 * exonym — threshold and matching live in src/utils/localeSearch.ts.
 */
const filteredLocales = computed(() =>
  filterLocales(availableLocales.value, query.value),
)

function displayLocale(loc: unknown): string {
  // Headless UI types the display-value callback as (item: unknown) => string.
  const entry = loc as LocaleEntry | null
  if (!entry) return ''
  return `${entry.flag} ${entry.name}`
}

function onQueryChange(event: Event) {
  const raw = (event.target as HTMLInputElement).value
  // Headless UI keeps `display-value` in the input, so a caret-at-the-end
  // keystroke produces "🇫🇮 Suomieng" rather than "eng". onFocus selects the
  // text so the first keystroke replaces it; this is the belt-and-braces pass
  // for browsers/IMEs that drop the selection before the input event lands.
  query.value = normalizeLocaleQuery(raw, displayLocale(selectedLocale.value))
}

/**
 * Opening the switcher selects the whole current language, so one backspace
 * wipes it and typing replaces it. Selecting (rather than erasing) keeps the
 * current language visible until the user actually types something.
 */
function onFocus(event: FocusEvent) {
  query.value = ''
  const input = event.target as HTMLInputElement | null
  if (!input || typeof input.select !== 'function' || !input.value) return
  input.select()
  keepFocusSelection = true
}

/**
 * A pointer press focuses the input and then collapses the caret to the click
 * position on mouseup, undoing the select() above. Swallow that one mouseup so
 * the selection made on focus survives a plain click.
 */
function onMouseUp(event: MouseEvent) {
  if (!keepFocusSelection) return
  keepFocusSelection = false
  event.preventDefault()
}

function onBlur() {
  keepFocusSelection = false
}

function persistLocale(code: string) {
  // SSR-safe: only touch localStorage on the client.
  if (!import.meta.client) return
  try {
    localStorage.setItem(LS_KEY, code)
  } catch {
    // private mode / quota — cookie path still works
  }
}

async function onSelect(loc: LocaleEntry | null) {
  query.value = ''
  if (!loc) return
  const code = loc.code
  if (!code || code === currentLocale.value) return
  persistLocale(code)
  // Navigate so URL prefix updates (prefix_except_default: bg has no prefix).
  // ALWAYS re-apply current query/hash (e.g. a verify/reset token or a
  // thread deep link must survive a language switch). switchLocalePath
  // usually returns fullPath, but path-only or empty results have dropped
  // the query — rebuild explicitly.
  const route = useRoute()
  const switched = switchLocalePath(code)
  const pathOnly = (switched || route.path).split(/[?#]/)[0] || '/'
  await navigateTo({
    path: pathOnly,
    query: { ...route.query },
    hash: route.hash || undefined,
  })
}
</script>

<style scoped>
.lang-switcher {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 2px;
  min-width: 0;
  max-width: 100%;
  position: relative;
}
.lang-switcher__combobox {
  position: relative;
  min-width: 0;
  max-width: 100%;
  width: 11.5rem;
}
.lang-switcher__control {
  display: flex;
  align-items: stretch;
  min-width: 0;
  max-width: 100%;
  border: 1px solid var(--color-border);
  border-radius: 8px;
  background-color: var(--color-surface);
  overflow: hidden;
}
.lang-switcher__control:hover {
  border-color: var(--color-accent);
  background-color: var(--color-surface-hover);
}
.lang-switcher__control:focus-within {
  outline: 2px solid var(--color-accent);
  outline-offset: 2px;
  border-color: var(--color-accent);
}
.lang-switcher__input {
  flex: 1 1 auto;
  min-width: 0;
  min-height: 36px;
  padding: 4px 8px;
  font-size: 0.875rem;
  font-family: inherit;
  line-height: 1.3;
  color: var(--color-fg);
  background: transparent;
  border: 0;
  outline: none;
  cursor: text;
}
.lang-switcher__button {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 36px;
  min-height: 36px;
  padding: 0 6px;
  margin: 0;
  border: 0;
  border-inline-start: 1px solid var(--color-border);
  background: transparent;
  color: var(--color-muted);
  cursor: pointer;
  font-size: 0.75rem;
  line-height: 1;
}
.lang-switcher__button:hover {
  color: var(--color-fg);
  background-color: var(--color-surface-hover);
}
.lang-switcher__options {
  position: absolute;
  z-index: 40;
  inset-inline-end: 0;
  top: calc(100% + 4px);
  width: max(100%, 12rem);
  max-width: 18rem;
  max-height: min(16rem, 50vh);
  margin: 0;
  padding: 4px 0;
  list-style: none;
  overflow-x: hidden;
  overflow-y: auto;
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: 8px;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
  box-sizing: border-box;
}
.lang-switcher__option {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 44px;
  padding: 8px 12px;
  font-size: 0.875rem;
  line-height: 1.3;
  color: var(--color-fg);
  cursor: pointer;
  box-sizing: border-box;
}
.lang-switcher__option--active {
  background-color: var(--color-surface-hover);
}
.lang-switcher__option--selected {
  font-weight: 600;
}
.lang-switcher__flag {
  flex: 0 0 auto;
}
.lang-switcher__name {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.lang-switcher__code {
  flex: 0 0 auto;
  font-size: 0.75rem;
  color: var(--color-muted);
  text-transform: uppercase;
}
.lang-switcher__empty {
  padding: 12px;
  font-size: 0.875rem;
  color: var(--color-muted);
  text-align: center;
}
/* Hint is compact-header silent; MobileMenu can surface it via :deep(). */
.lang-switcher__hint {
  display: none;
  margin: 0;
  max-width: 14rem;
  font-size: 0.75rem;
  line-height: 1.3;
  color: var(--color-muted);
  text-align: end;
}
.visually-hidden {
  position: absolute;
  width: 1px;
  height: 1px;
  padding: 0;
  margin: -1px;
  overflow: hidden;
  clip: rect(0, 0, 0, 0);
  white-space: nowrap;
  border: 0;
}
</style>
