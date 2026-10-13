// ESLint flat config for the WUI (SPL-1055): `pnpm run lint`.
//
// Two rules, both errors, on every .ts / .vue file under src/:
// - @typescript-eslint/no-explicit-any (SPL-1051): use the real type, or
//   `unknown` plus a narrowing guard.
// - vue/no-v-html (SPL-1053): render text with interpolation or h(). The one
//   sink allowed is pages/blog.vue, a fragment built by markdownToHtml and
//   refused at build time when hostile (src/node/blog/sync-blog.mjs); it
//   carries a per-line disable that names why.
// No recommended preset: the gate holds only what was agreed, with zero
// baseline hits, so any new hit is a new defect.
import tseslint from 'typescript-eslint'
import vue from 'eslint-plugin-vue'
import vueParser from 'vue-eslint-parser'

export default [
  // .mjs/.js are plain JS (SPL-1052 counts them): these rules are type rules
  { ignores: ['.nuxt/**', '.output/**', 'dist/**', 'node_modules/**', '**/*.{js,mjs,cjs}'] },
  {
    files: ['src/**/*.ts'],
    languageOptions: { parser: tseslint.parser },
    plugins: { '@typescript-eslint': tseslint.plugin },
    rules: { '@typescript-eslint/no-explicit-any': 'error' },
  },
  {
    files: ['src/**/*.vue'],
    languageOptions: {
      parser: vueParser,
      parserOptions: { parser: tseslint.parser, extraFileExtensions: ['.vue'], sourceType: 'module' },
    },
    plugins: { '@typescript-eslint': tseslint.plugin, vue },
    // the processor + comment-directive make <!-- eslint-disable-next-line --> work in a template
    processor: 'vue/vue',
    rules: {
      'vue/comment-directive': 'error',
      '@typescript-eslint/no-explicit-any': 'error',
      'vue/no-v-html': 'error',
    },
  },
]
