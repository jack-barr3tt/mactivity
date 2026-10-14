import assert from 'node:assert/strict'
import { test } from 'node:test'
import { initialReleaseNotes, releaseBody, releaseNotes, selectChangeType, splitLabels } from './notes.mjs'

test('one change-type label selects the section', () => {
  assert.deepEqual(selectChangeType(splitLabels('ci, feature')), { type: 'feature', found: ['feature'] })
  assert.deepEqual(selectChangeType(['Security']), { type: 'security', found: ['security'] })
  assert.equal(selectChangeType(['ci']).type, '')
  assert.deepEqual(selectChangeType(['feature', 'fix']).found, ['feature', 'fix'])
})

test('release notes link pull requests under their change type', () => {
  const { notes, errors } = releaseNotes(
    [
      {
        number: 4,
        title: 'Record idle gaps',
        url: 'https://github.com/jack-barr3tt/mactivity/pull/4',
        labels: ['feature', 'ci'],
      },
      {
        number: 5,
        title: 'Close the open segment on quit',
        url: 'https://github.com/jack-barr3tt/mactivity/pull/5',
        labels: ['fix'],
      },
      {
        number: 6,
        title: 'Stop an open redirect',
        url: 'https://github.com/jack-barr3tt/mactivity/pull/6',
        labels: ['Security'],
      },
    ],
    '0.2.0',
    '2026-10-04',
  )
  assert.deepEqual(errors, [])
  assert.equal(
    notes,
    [
      '## 0.2.0 - 2026-10-04',
      '',
      '### Security',
      '- [Stop an open redirect](https://github.com/jack-barr3tt/mactivity/pull/6)',
      '',
      '### Features',
      '- [Record idle gaps](https://github.com/jack-barr3tt/mactivity/pull/4)',
      '',
      '### Fixes',
      '- [Close the open segment on quit](https://github.com/jack-barr3tt/mactivity/pull/5)',
      '',
    ].join('\n'),
  )
})

test('a pull request needs exactly one change type', () => {
  const { notes, errors } = releaseNotes(
    [
      { number: 7, title: 'Clean up', url: 'https://github.com/jack-barr3tt/mactivity/pull/7', labels: [] },
      {
        number: 8,
        title: 'Both',
        url: 'https://github.com/jack-barr3tt/mactivity/pull/8',
        labels: ['feature', 'fix'],
      },
    ],
    '0.2.0',
    '2026-10-04',
  )
  assert.equal(notes, '')
  assert.deepEqual(errors, [
    '#7 has no change type: https://github.com/jack-barr3tt/mactivity/pull/7',
    '#8 has feature and fix: https://github.com/jack-barr3tt/mactivity/pull/8',
  ])
})

test('the first release with no pull requests is the initial note', () => {
  const { notes, errors } = releaseBody([], '0.1.0', '2026-10-14', true)
  assert.deepEqual(errors, [])
  assert.equal(notes, initialReleaseNotes)
  assert.equal(releaseBody([], '0.2.0', '2026-10-14', false).notes, '')
})
