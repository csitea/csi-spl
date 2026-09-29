// W14 (spec 047, SPL-1169): the /help page's link rules (utils/help.mjs).
//
// Run: node tests/unit/help.test.mjs
import { HELP_REPO_BASE, helpHref, rewriteHelpLinks, validHelpSlug } from '../../src/utils/help.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

console.log('help')
ok('a sibling page becomes the /help route', helpHref('./how-to-post.md') === '/help/how-to-post' && helpHref('global-search.md#x') === '/help/global-search')
ok('the index is /help itself', helpHref('./index.md') === '/help')
ok('the route builder is the page\'s (locale prefix)', helpHref('./user-settings.md', (s) => '/fi/help/' + s) === '/fi/help/user-settings')
ok('absolute, mailto, anchor and site paths stay', ['https://example.com/a', 'mailto:a@example.com', '#top', '/search?q=x'].every((h) => helpHref(h) === h))
ok('any other relative link points at the public repo', helpHref('../../specs/047/x.md') === new URL('../../specs/047/x.md', HELP_REPO_BASE).href)
ok('rewrite touches only link targets', rewriteHelpLinks('see [Post](./how-to-post.md) and (./x.md) text') === 'see [Post](/help/how-to-post) and (./x.md) text')
ok('slugs are the sync rule', validHelpSlug('getting-started') && !validHelpSlug('../x') && !validHelpSlug('') && !validHelpSlug('A'))
const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.log(`help: ${failed} FAILED`)
  process.exit(1)
}
console.log('help: all passed')
