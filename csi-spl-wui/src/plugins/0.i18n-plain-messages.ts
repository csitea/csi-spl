// Perf round 3, P3-20: vue-i18n compiles plain-string messages too
// (src/utils/i18n-plain-messages.mjs). Registered before vue-i18n makes its
// context (enforce: 'pre' runs ahead of @nuxtjs/i18n's plugin, and the
// context reads the registered compiler when it is created). Server too: the
// prerendered documents render the same strings.
import { registerMessageCompiler } from '@intlify/core-base'
import type { MessageCompiler } from '@intlify/core-base'
import { plainMessageCompiler } from '~/utils/i18n-plain-messages.mjs'

export default defineNuxtPlugin({
  name: 'spool:i18n-plain-messages',
  enforce: 'pre',
  setup() {
    registerMessageCompiler(plainMessageCompiler as MessageCompiler)
  },
})
