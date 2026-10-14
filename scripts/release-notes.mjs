import { realpathSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { changeTypeNames, groupedChanges, releaseBody, releaseNotes } from './notes.mjs'
import { githubToken, headDate, previousVersionTag, pullsBetween, repository } from './pulls.mjs'

function fail(errors) {
  for (const error of errors) console.error(error)
  console.error(`add one of: ${changeTypeNames.join(', ')}`)
  process.exit(1)
}

async function main() {
  const args = process.argv.slice(2)
  const changesOnly = args[0] === '--changes'
  const [fromArg, toArg, versionArg] = changesOnly ? args.slice(1) : args
  const to = toArg || 'HEAD'
  const from = !fromArg || fromArg === '-' ? '' : fromArg
  const version = (versionArg || '').replace(/^v/, '')
  if (!changesOnly && !version) throw new Error('usage: release-notes.mjs [--changes] <from|-> <to> [version]')
  const pulls = await pullsBetween(repository(), from, to, githubToken())
  if (changesOnly) {
    const { body, errors } = groupedChanges(pulls)
    if (errors.length > 0) fail(errors)
    process.stdout.write(body)
    return
  }
  const first = !from && !previousVersionTag(to)
  const { notes, errors } = from ? releaseNotes(pulls, version, headDate(to)) : releaseBody(pulls, version, headDate(to), first)
  if (errors.length > 0) fail(errors)
  if (!notes) {
    console.error(`no merged pull requests since ${from || 'the start'}`)
    process.exit(1)
  }
  process.stdout.write(notes)
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  main().catch((error) => {
    console.error(error.message)
    process.exit(1)
  })
}
