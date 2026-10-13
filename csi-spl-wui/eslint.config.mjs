// @ts-check
import eslint from '@eslint/js'
import tseslint from 'typescript-eslint'
import pluginVue from 'eslint-plugin-vue'

export default tseslint.config(
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
  ...pluginVue.configs['flat/recommended'],
  {
    rules: {
      '@typescript-eslint/no-explicit-any': 'error',
      'vue/no-v-html': 'error',
      'vue/multi-word-component-names': 'off',
    },
  },
  {
    files: ['**/*.vue'],
    languageOptions: {
      parserOptions: {
        parser: tseslint.parser,
      },
    },
  },
  {
    ignores: ['node_modules/', '.nuxt/', '.output/', 'dist/', 'public/'],
  },
)