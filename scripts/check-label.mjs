import { pathToFileURL } from 'node:url'
import { changeTypeNames, selectChangeType, splitLabels } from './notes.mjs'
import { github, githubToken, repository } from './pulls.mjs'

export async function resolveLabels(env, loadPull) {
  const number = String(env.CI_COMMIT_PULL_REQUEST || '').trim()
  if (number) {
    const pull = await loadPull(number)
    return (pull.labels || []).map((label) => label.name).filter(Boolean)
  }
  return splitLabels(env.CI_COMMIT_PULL_REQUEST_LABELS || '')
}

async function main() {
  const labels = await resolveLabels(process.env, (number) =>
    github(`/repos/${repository()}/pulls/${number}`, githubToken()),
  )
  const { type, found } = selectChangeType(labels)
  if (type) {
    console.log(type)
    return
  }
  if (found.length > 1) console.error(`pull request has ${found.join(' and ')}`)
  else console.error('pull request has no change type')
  console.error(`add one of: ${changeTypeNames.join(', ')}`)
  process.exitCode = 1
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main()
}
