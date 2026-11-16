import assert from 'node:assert/strict'
import { existsSync } from 'node:fs'
import { test } from 'node:test'
import { builtHash, sourceHash } from '../scripts/build-link.mjs'

test('link.js and link.wasm are the build of ../link', () => {
  assert.equal(builtHash(), sourceHash(), 'link.js is stale: run `npm run build` (it needs Rust) and commit link.js and link.wasm')
  assert.ok(existsSync(new URL('../link.wasm', import.meta.url)), 'link.wasm is missing: run `npm run build`')
})
