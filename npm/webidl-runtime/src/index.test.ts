import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ABI_VERSION } from './index.ts'

test('ABI_VERSION is 1', () => {
  assert.equal(ABI_VERSION, 1)
})
