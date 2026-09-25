import { useFontSize } from '~/composables/useFontSize'

export default defineNuxtPlugin(() => {
  useFontSize().hydrate()
})
