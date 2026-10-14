import { changeTypeNames, releaseBody } from './notes.mjs'
import { githubToken, headDate, previousVersionTag, pullsBetween, repository } from './pulls.mjs'

const token = githubToken()
const tag = process.env.CI_COMMIT_TAG || ''
if (!token) {
  console.error('GITHUB_TOKEN is empty')
  process.exit(1)
}
if (!/^v\d+\.\d+\.\d+$/.test(tag)) {
  console.error('CI_COMMIT_TAG is not a version tag')
  process.exit(1)
}

const repo = repository()
const version = tag.slice(1)
const from = previousVersionTag(tag)
const pulls = await pullsBetween(repo, from, tag, token)
const { notes, errors } = releaseBody(pulls, version, headDate(tag), !from)
if (errors.length > 0) {
  for (const error of errors) console.error(error)
  console.error(`add one of: ${changeTypeNames.join(', ')}`)
  process.exit(1)
}
if (!notes) {
  console.error(`no merged pull requests since ${from || 'the start'}`)
  process.exit(1)
}
process.stdout.write(notes)

const headers = {
  Authorization: `Bearer ${token}`,
  Accept: 'application/vnd.github+json',
  'X-GitHub-Api-Version': '2022-11-28',
  'User-Agent': 'mactivity-release',
  'Content-Type': 'application/json',
}

const created = await fetch(`https://api.github.com/repos/${repo}/releases`, {
  method: 'POST',
  headers,
  body: JSON.stringify({ tag_name: tag, name: version, body: notes }),
})
if (created.status === 422) {
  const existing = await fetch(`https://api.github.com/repos/${repo}/releases/tags/${tag}`, { headers })
  if (!existing.ok) {
    console.error(await created.text())
    process.exit(1)
  }
  const release = await existing.json()
  const updated = await fetch(`https://api.github.com/repos/${repo}/releases/${release.id}`, {
    method: 'PATCH',
    headers,
    body: JSON.stringify({ name: version, body: notes }),
  })
  if (!updated.ok) {
    console.error(await updated.text())
    process.exit(1)
  }
  const refreshed = await updated.json()
  console.log(refreshed.html_url)
  process.exit(0)
}
if (!created.ok) {
  console.error(await created.text())
  process.exit(1)
}
const release = await created.json()
console.log(release.html_url)
