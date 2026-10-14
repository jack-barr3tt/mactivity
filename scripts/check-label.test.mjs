import assert from 'node:assert/strict'
import { test } from 'node:test'
import { resolveLabels } from './check-label.mjs'

test('a pull request reads its current labels', async () => {
  const labels = await resolveLabels({ CI_COMMIT_PULL_REQUEST: '3', CI_COMMIT_PULL_REQUEST_LABELS: '' }, async () => ({
    labels: [{ name: 'feature' }, { name: 'ci' }],
  }))
  assert.deepEqual(labels, ['feature', 'ci'])
})

test('without a pull request the pipeline labels are used', async () => {
  const labels = await resolveLabels({ CI_COMMIT_PULL_REQUEST_LABELS: 'docs, ci' }, async () => {
    throw new Error('should not load')
  })
  assert.deepEqual(labels, ['docs', 'ci'])
})
