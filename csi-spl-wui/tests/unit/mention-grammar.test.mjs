// SPL-3435 (CI failures panel I8): src/utils/mention-grammar.json is the one
// mention grammar the WUI and the hub both read. The hub's hand scan
// (csi-spl-api/src/go/spool-hub-api/internal/store/flow_mentions.go) cannot
// load it at run time, so a contract edit made here would pass the WUI gate and
// turn the hub job red in CI. This test holds the same pin as the hub's
// TestMentionGrammarContract, without Go: a WUI lane that changes the grammar
// fails here first and is told to port the change.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const CONTRACT = join(HERE, '..', '..', 'src', 'utils', 'mention-grammar.json')

// What flow_mentions.go implements (agentIDAt, legacyIDAt, boxEnd).
const GO_SCAN = {
  agent_id_src: '[acgmq]-[0-9]{3}(?![0-9])',
  legacy_id_src: '[A-Z]{2,4}-[0-9]+',
  box_id_src: '[a-z0-9][a-z0-9-]{0,31}',
}

describe('mention grammar contract (SPL-3435)', () => {
  const contract = JSON.parse(readFileSync(CONTRACT, 'utf8'))
  for (const [key, want] of Object.entries(GO_SCAN)) {
    it(`${key} equals what the hub scan implements`, () => {
      assert.equal(
        contract[key],
        want,
        `mention-grammar.json ${key} = ${JSON.stringify(contract[key])}, the hub scan implements ${JSON.stringify(want)}: ` +
          'port the change to csi-spl-api/src/go/spool-hub-api/internal/store/flow_mentions.go, ' +
          'update the pins in its flow_mentions_test.go (TestMentionGrammarContract) and in this test',
      )
    })
  }
})
