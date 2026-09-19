<!-- Searchable locale picker — same Headless UI Combobox + localeSearch
     matching as LanguageSwitcher (endonym, English exonym, code, IETF tag).
     v-model is the locale code string (e.g. "bg"). Used by admin user forms. -->
<template>
  <div class="locale-cbx" :data-test="`${testPrefix}-wrap`">
    <Combobox
      as="div"
      class="locale-cbx__combobox"
      :model-value="selected"
      by="code"
      nullable
      @update:model-value="onSelect"
    >
      <ComboboxLabel v-if="!labelledBy" class="visually-hidden">
        {{ t("nav.lang_label") }}
      </ComboboxLabel>
      <div class="locale-cbx__control">
        <ComboboxInput
          class="locale-cbx__input"
          :data-test="testPrefix"
          :display-value="displayLocale"
          :placeholder="t('nav.lang_search_placeholder')"
          :aria-label="labelledBy ? undefined : t('nav.lang_label')"
          :aria-labelledby="labelledBy || undefined"
          autocomplete="off"
          @change="onQueryChange"
          @focus="onFocus"
          @mouseup="onMouseUp"
          @blur="onBlur"
        />
        <ComboboxButton
          class="locale-cbx__button"
          :data-test="`${testPrefix}-button`"
          :aria-label="t('nav.lang_label')"
        >
          <span class="locale-cbx__chevron" aria-hidden="true">▾</span>
        </ComboboxButton>
      </div>
      <ComboboxOptions
        class="locale-cbx__options"
        :data-test="`${testPrefix}-options`"
      >
        <li
          v-if="filtered.length === 0"
          class="locale-cbx__empty"
          :data-test="`${testPrefix}-no-matches`"
          role="status"
          aria-live="polite"
        >
          {{ t("nav.lang_no_matches") }}
        </li>
        <ComboboxOption
          v-for="loc in filtered"
          :key="loc.code"
          v-slot="{ active, selected: isSelected }"
          as="template"
          :value="loc"
        >
          <li
            class="locale-cbx__option"
            :class="{
              'locale-cbx__option--active': active,
              'locale-cbx__option--selected': isSelected,
            }"
            :data-test="`${testPrefix}-item-${loc.code}`"
          >
            <span class="locale-cbx__flag" aria-hidden="true">{{ loc.flag }}</span>
            <span class="locale-cbx__name">{{ loc.name }}</span>
            <span class="locale-cbx__code">{{ loc.code }}</span>
          </li>
        </ComboboxOption>
      </ComboboxOptions>
    </Combobox>
  </div>
</template>

<script setup lang="ts">
import { computed, ref } from "vue"
import {
  Combobox,
  ComboboxButton,
  ComboboxInput,
  ComboboxLabel,
  ComboboxOption,
  ComboboxOptions,
} from "@headlessui/vue"
import { filterLocales, normalizeLocaleQuery } from "@/utils/localeSearch"

type LocaleCode =
  | "bg" | "fi" | "ru" | "en" | "sv" | "he" | "tr" | "mk" | "el"
  | "lt" | "et" | "lv" | "sr" | "ro" | "uk" | "sk" | "pl" | "es" | "nl"

interface LocaleEntry {
  code: string
  name: string
  flag: string
  iso?: string
}

const LOCALE_FLAGS: Record<string, string> = {
  bg: "🇧🇬",
  fi: "🇫🇮",
  sv: "🇸🇪",
  en: "🇬🇧",
  ru: "🇷🇺",
  he: "🇮🇱",
  tr: "🇹🇷",
  mk: "🇲🇰",
  el: "🇬🇷",
  lt: "🇱🇹",
  et: "🇪🇪",
  lv: "🇱🇻",
  sr: "🇷🇸",
  ro: "🇷🇴",
  uk: "🇺🇦",
  sk: "🇸🇰",
  pl: "🇵🇱",
  es: "🇪🇸",
  nl: "🇳🇱",
}

const props = withDefaults(
  defineProps<{
    modelValue: string
    testPrefix: string
    labelledBy?: string
    allowedCodes?: readonly string[]
  }>(),
  { labelledBy: "", allowedCodes: undefined },
)

const emit = defineEmits<{
  (e: "update:modelValue", v: string): void
}>()

const { locales, t } = useI18n({ useScope: "global" })

const query = ref("")
let keepFocusSelection = false

const available = computed<LocaleEntry[]>(() => {
  const allowed = props.allowedCodes ? new Set(props.allowedCodes) : null
  return (locales.value as Array<{ code: string; name?: string; iso?: string; language?: string }>)
    .filter((l) => !allowed || allowed.has(l.code))
    .map((l) => ({
      code: l.code,
      name: l.name ?? l.code,
      flag: LOCALE_FLAGS[l.code as LocaleCode] ?? "🌐",
      iso: l.language ?? l.iso,
    }))
})

const selected = computed<LocaleEntry | null>(
  () => available.value.find((l) => l.code === props.modelValue) ?? null,
)

const filtered = computed(() => filterLocales(available.value, query.value))

function displayLocale(loc: unknown): string {
  const entry = loc as LocaleEntry | null
  if (!entry) return ""
  return `${entry.flag} ${entry.name}`
}

function onQueryChange(event: Event) {
  const raw = (event.target as HTMLInputElement).value
  query.value = normalizeLocaleQuery(raw, displayLocale(selected.value))
}

function onFocus(event: FocusEvent) {
  query.value = ""
  const input = event.target as HTMLInputElement | null
  if (!input || typeof input.select !== "function" || !input.value) return
  input.select()
  keepFocusSelection = true
}

function onMouseUp(event: MouseEvent) {
  if (!keepFocusSelection) return
  keepFocusSelection = false
  event.preventDefault()
}

function onBlur() {
  keepFocusSelection = false
}

function onSelect(loc: LocaleEntry | null) {
  query.value = ""
  if (!loc?.code) return
  emit("update:modelValue", loc.code)
}
</script>

<style scoped>
.locale-cbx {
  position: relative;
  min-width: 0;
  max-width: 100%;
  width: 100%;
}
.locale-cbx__combobox {
  position: relative;
  min-width: 0;
  max-width: 100%;
  width: 100%;
}
.locale-cbx__control {
  display: flex;
  align-items: stretch;
  min-width: 0;
  max-width: 100%;
  border: 1px solid var(--color-border, #ccc);
  border-radius: 8px;
  background: var(--color-surface, #fff);
  overflow: hidden;
}
.locale-cbx__control:focus-within {
  outline: 2px solid var(--color-accent, #3050ff);
  outline-offset: 2px;
  border-color: var(--color-accent, #3050ff);
}
.locale-cbx__input {
  flex: 1 1 auto;
  min-width: 0;
  min-height: 40px;
  padding: 0.625rem 0.875rem;
  font-size: 1rem;
  font-family: inherit;
  line-height: 1.3;
  color: inherit;
  background: transparent;
  border: 0;
  outline: none;
}
.locale-cbx__button {
  flex: 0 0 auto;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 40px;
  min-height: 40px;
  padding: 0 8px;
  margin: 0;
  border: 0;
  border-inline-start: 1px solid var(--color-border, #ccc);
  background: transparent;
  color: var(--color-muted, #666);
  cursor: pointer;
}
.locale-cbx__options {
  position: absolute;
  z-index: 40;
  inset-inline-start: 0;
  top: calc(100% + 4px);
  width: 100%;
  max-width: 100%;
  max-height: min(16rem, 50vh);
  margin: 0;
  padding: 4px 0;
  list-style: none;
  overflow-x: hidden;
  overflow-y: auto;
  background: var(--color-surface, #fff);
  border: 1px solid var(--color-border, #ccc);
  border-radius: 8px;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
  box-sizing: border-box;
}
.locale-cbx__option {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 44px;
  padding: 8px 12px;
  font-size: 0.95rem;
  cursor: pointer;
  box-sizing: border-box;
}
.locale-cbx__option--active {
  background: var(--color-surface-hover, #f4f4f4);
}
.locale-cbx__option--selected {
  font-weight: 600;
}
.locale-cbx__flag { flex: 0 0 auto; }
.locale-cbx__name {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.locale-cbx__code {
  flex: 0 0 auto;
  font-size: 0.75rem;
  color: var(--color-muted, #666);
  text-transform: uppercase;
}
.locale-cbx__empty {
  padding: 12px;
  font-size: 0.875rem;
  color: var(--color-muted, #666);
  text-align: center;
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
