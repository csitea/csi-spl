// Check for decode differences between decodeHTMLStrict and entities.decodeHTMLStrict

import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { decodeHTMLStrict } from '../csi-spl-wui/src/utils/entities-browser.mjs'

// Mock decodeHTML for Node.js (not used in this script)
const decodeHTML = () => { throw new Error('decodeHTML is not available in Node.js') }
const entities = await import('../csi-spl-wui/node_modules/entities/dist/index.js')

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../csi-spl-wui')

// Fetch all named entities from the `entities` package's generated encode-html.js
const encodeHtmlPath = join(WUI, 'node_modules/entities/dist/generated/encode-html.js')
const encodeHtmlContent = readFileSync(encodeHtmlPath, 'utf8')
const namedEntitiesString = encodeHtmlContent.match(/export default "([^"]+)"/)[1]

// Split the string into individual named entities
const names = []
let current = ''
for (const char of namedEntitiesString) {
  if (char === ';') {
    names.push(`&${current};`)
    current = ''
  } else {
    current += char
  }
}

// Check for decode differences
const differences = []
for (const name of names) {
  const our = decodeHTMLStrict(name)
  const ref = entities.decodeHTMLStrict(name)
  if (our !== ref) {
    differences.push({ name, our, ref })
  }
}

// Print differences
console.log(`Found ${differences.length} decode differences:`)
console.log(JSON.stringify(differences, null, 2))