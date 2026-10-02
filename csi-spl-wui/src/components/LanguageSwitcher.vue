<template>
  <div ref="root" class="lang-switcher" :class="{ 'lang-switcher--fill': fill }" data-test="lang-switcher">
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
      is applied once after sign-in by plugins/preferred-locale.client.ts.
      Saving there ALSO switches the UI on the spot (owner 2026-09-23) — a
      language control that leaves the page in the old language reads as
      broken — so both surfaces now go through useLocaleSwitch.
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
        <!--
          The field grid-stacks the visible input over one hidden sizer per
          locale (endonym + flag), so the closed control's intrinsic width is
          the LONGEST name's — never the current selection's — and it neither
          jumps between languages nor clips any of the 19. `size="1"` keeps the
          input's own intrinsic width out of the grid track; the sizers own it.
          The field's right padding (SPL-1184: 4px ≈ 1mm, halved from 8px on the
          owner's word) is the only slack after the longest name before the ▾.
        -->
        <span class="lang-switcher__field">
          <ComboboxInput
            class="lang-switcher__input"
            data-test="lang-switcher-input"
            size="1"
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
          <span
            v-for="loc in availableLocales"
            :key="`sizer-${loc.code}`"
            class="lang-switcher__sizer"
            aria-hidden="true"
          >{{ loc.flag }} {{ loc.name }}</span>
        </span>
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
import { computed, onBeforeUnmount, onMounted, ref, toRefs } from 'vue'
import {
  Combobox,
  ComboboxButton,
  ComboboxInput,
  ComboboxLabel,
  ComboboxOption,
  ComboboxOptions,
} from '@headlessui/vue'
import { filterLocales, normalizeLocaleQuery } from '@/utils/localeSearch'
import { useLocaleSwitch } from '@/composables/useLocaleSwitch'
import { observePopover } from '~/utils/place-popover.mjs'

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

/**
 * CLE-77892 (owner, t1 9417ccf3: "this still looks quite narrow on my
 * phone"): `fill` is the avatar sheet's row control - it spans the space the
 * row gives it, never narrower than the longest "<flag> <name>", and the whole
 * box is ONE tap target that opens the list (the ▾ is drawn inside it, not a
 * second button). The top bar and the sign-in frame keep the compact control.
 */
const props = withDefaults(defineProps<{ fill?: boolean }>(), { fill: false })
const { fill } = toRefs(props)

const { locales, locale: currentLocale, t } = useI18n({ useScope: 'global' })
const { switchTo } = useLocaleSwitch()

const query = ref('')
const root = ref<HTMLElement | null>(null)
let stopPopover = () => {}
onMounted(() => {
  stopPopover = observePopover(root.value, {
    panel: '.lang-switcher__options',
    anchor: '.lang-switcher__control',
    align: 'end',
  })
})
onBeforeUnmount(() => stopPopover())
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

async function onSelect(loc: LocaleEntry | null) {
  query.value = ''
  if (!loc) return
  // The navigation, the localStorage mirror and the "switchLocalePath said
  // nothing useful" fallback all live in useLocaleSwitch, shared with
  // Settings -> Language so the two surfaces cannot drift apart.
  await switchTo(loc.code)
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
  /* Shrink-wrap to the longest locale name (via the sizers) instead of a
     fixed 11.5rem, which left a wide dead gap after short names. */
  width: max-content;
}
.lang-switcher__control {
  display: flex;
  align-items: stretch;
  /* The bordered box hugs its content (the field sized to the longest name +
     the chevron), so even a container that forces the combobox wide cannot
     open a gap inside the control. */
  width: max-content;
  min-width: 0;
  max-width: 100%;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background-color: var(--color-surface);
  overflow: hidden;
}
/* The field's width is the widest locale label: the hidden sizers sit in the
   grid flow and size the single track, while the visible input is taken OUT of
   track sizing (absolute) and just overlays the cell — otherwise its width:100%
   feeds back into the auto track and inflates it. flex:0 so it never grows to
   fill spare row space, which would re-open the gap the fix closes. */
.lang-switcher__field {
  position: relative;
  display: inline-grid;
  flex: 0 1 auto;
  min-width: 0;
}
.lang-switcher__sizer {
  grid-area: 1 / 1;
  min-width: 0;
  visibility: hidden;
  pointer-events: none;
  white-space: nowrap;
  /* SPL-1184: the trailing slack after the name is the right padding; halved
     from 8px to 4px on the owner's word. Left stays 8px so the flag/name keep
     their breathing room from the border. The sizer owns the field width, so
     this is what actually narrows the closed control's gap before the ▾. */
  padding: 4px 4px 4px 8px;
  font-size: 0.875rem;
  font-family: inherit;
  line-height: 1.3;
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
  border-radius: var(--radius-sm);
  position: absolute;
  inset: 0;
  width: 100%;
  min-width: 0;
  min-height: 36px;
  /* SPL-1184: match the sizer's 4px right slack so the caret/value line up with
     the halved gap; left stays 8px. */
  padding: 4px 4px 4px 8px;
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
  border-radius: var(--radius-sm);
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
  z-index: var(--z-popover);
  inset-inline-end: 0;
  top: calc(100% + 4px);
  /* Fit the widest row (flag + name + code) and no wider. NO min-width:100%
     here: place-popover.mjs switches the panel to position:fixed and pins its
     width via lockWidth, but a percentage min-width would then resolve against
     the viewport (100vw) and blow the list full-width. */
  width: max-content;
  max-width: min(18rem, calc(100vw - 16px));
  max-height: min(16rem, 50vh);
  margin: 0;
  padding: 4px 0;
  list-style: none;
  overflow-x: hidden;
  overflow-y: auto;
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
  box-sizing: border-box;
}
.lang-switcher__option {
  border-radius: var(--radius-sm);
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 44px;
  /* SPL-1184: the matching open-list slack, tightened with the closed control
     (inline padding 12px -> 8px) so the drop-down reads as tight as the field
     it opens from. min-height keeps the 44px tap target. */
  padding: 8px 8px;
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
/* CLE-77892: the avatar sheet's full-row control. The field keeps the
   longest name as its minimum (min-width:auto lets the sizers hold it), the
   control stretches to whatever the row has left, and the ComboboxButton is
   laid over the whole box, so a tap anywhere opens the list; the ▾ sits at
   its inline end, inside the field's end padding. The list is as wide as the
   control (width:100% before place-popover pins it in px via lockWidth). */
.lang-switcher--fill { align-items: stretch; width: 100%; }
.lang-switcher--fill .lang-switcher__combobox,
.lang-switcher--fill .lang-switcher__control { width: 100%; }
.lang-switcher--fill .lang-switcher__control { position: relative; }
.lang-switcher--fill .lang-switcher__field { flex: 1 1 auto; min-width: auto; min-height: var(--tap, 44px); }
.lang-switcher--fill .lang-switcher__sizer,
.lang-switcher--fill .lang-switcher__input { padding: 4px 36px 4px 12px; font-size: 0.9375rem; }
.lang-switcher--fill .lang-switcher__button {
  position: absolute;
  inset: 0;
  justify-content: flex-end;
  padding: 0 14px;
  border-inline-start: 0;
}
.lang-switcher--fill .lang-switcher__button:hover { background: transparent; }
.lang-switcher--fill .lang-switcher__options { width: 100%; max-width: none; }
/* SPL-990: phones (the avatar sheet, the sign-in frame): a 44 px target */
@media (max-width: 820px) {
  .lang-switcher__input,
  .lang-switcher__button { min-height: var(--tap, 44px); }
  .lang-switcher__button { min-width: var(--tap, 44px); }
}
</style>
