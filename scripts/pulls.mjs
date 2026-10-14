import { spawnSync } from 'node:child_process'

export function git(args) {
  const result = spawnSync('git', args, { encoding: 'utf8' })
  if (result.error) throw result.error
  if (result.status !== 0) {
    throw new Error((result.stderr || `git ${args.join(' ')}`).trim())
  }
  return result.stdout
}

export function commitShas(from, to = 'HEAD') {
  const args = ['log', '--reverse', '--format=%H']
  args.push(from ? `${from}..${to}` : to)
  return git(args)
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
}

export function headDate(rev = 'HEAD') {
  return git(['log', '-1', '--format=%cs', rev]).trim()
}

export function previousVersionTag(current = '') {
  const tags = git(['tag', '-l', 'v*', '--sort=-v:refname'])
    .split('\n')
    .map((line) => line.trim())
    .filter((tag) => /^v\d+\.\d+\.\d+$/.test(tag) && tag !== current)
  for (const candidate of tags) {
    const ancestor = spawnSync('git', ['merge-base', '--is-ancestor', candidate, current || 'HEAD'])
    if (ancestor.status === 0) return candidate
  }
  return ''
}

export function repository() {
  if (process.env.CI_REPO_OWNER && process.env.CI_REPO_NAME) {
    return `${process.env.CI_REPO_OWNER}/${process.env.CI_REPO_NAME}`
  }
  if (process.env.CI_REPO && process.env.CI_REPO.includes('/')) return process.env.CI_REPO
  const remote = git(['remote', 'get-url', 'origin']).trim()
  const match = /github\.com[:/]([^/]+)\/(.+?)(?:\.git)?$/.exec(remote)
  if (!match) throw new Error('could not read the GitHub repository from origin')
  return `${match[1]}/${match[2]}`
}

export function githubToken() {
  return process.env.GITHUB_TOKEN || process.env.GH_TOKEN || ''
}

export async function github(path, token) {
  const headers = {
    Accept: 'application/vnd.github+json',
    'User-Agent': 'mactivity-release',
    'X-GitHub-Api-Version': '2022-11-28',
  }
  if (token) headers.Authorization = `Bearer ${token}`
  const response = await fetch(`https://api.github.com${path}`, { headers })
  const text = await response.text()
  if (!response.ok) throw new Error(`GitHub ${path} returned ${response.status}: ${text}`)
  return text ? JSON.parse(text) : null
}

export async function pullsBetween(repo, from, to, token) {
  const seen = new Map()
  for (const sha of commitShas(from, to)) {
    const listed = await github(`/repos/${repo}/commits/${sha}/pulls`, token)
    if (!Array.isArray(listed)) throw new Error(`GitHub returned no pull requests for ${sha}`)
    for (const pull of listed) {
      if (!pull.merged_at || seen.has(pull.number)) continue
      let labels = pull.labels
      if (!labels) {
        const full = await github(`/repos/${repo}/pulls/${pull.number}`, token)
        labels = full.labels
      }
      seen.set(pull.number, {
        number: pull.number,
        title: pull.title || '',
        url: pull.html_url,
        labels: (labels || []).map((label) => label.name),
      })
    }
  }
  return [...seen.values()]
}
