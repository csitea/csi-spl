<!-- SPL-6675 (owner HUM-10, t1 bcfd15e1 msg b996a06b): "there MUST NOT BE any
     universal search separate page - it MUST be triggerable only from an
     actual search from the omnibox". The results are the search panel
     (components/SearchPanel.vue) beside whatever page is open; this route is
     no page any more. An old /search?q=… link (a copied hit, a bookmark)
     opens that panel on the home page and leaves the address at once. -->
<template>
  <div class="feed-col" data-test="search-redirect" />
</template>

<script setup lang="ts">
import { useSearchStore } from '~/stores/search'

const route = useRoute()
const localePath = useLocalePath()
const search = useSearchStore()

onMounted(() => {
  const q = typeof route.query.q === 'string' ? route.query.q : ''
  search.openPanel(q)
  void navigateTo(localePath('/'), { replace: true })
})
</script>
