# Releasing

Pull requests and pushes to `main` lint the API, run its tests, and run the release-script tests. A Linux agent does not build the menu bar app. `make lint-agent` and `swift test` stay on a Mac.

A pull request has one change-type label: `security`, `feature`, `fix`, `docs`, `test`, `deps`, or `chore`. Create those labels on the repository. The pull request check fails otherwise, and it reruns when the labels change. Other labels can sit alongside that one.

On `main`, with a clean working tree:

```bash
scripts/tagbump
```

The script lists the merged pull requests since the previous tag, then asks for `patch`, `minor`, or `major`. A note is the pull request title linked to that pull request, under the heading for its label. It writes the version into `agent/Info.plist` and commits that when it changed. The tag is lightweight. With no tags and no merged pull requests yet, it tags `v0.1.0` and the note is `Initial release.`

Push `main` and the tag. The script prints the exact command. Woodpecker opens a GitHub release with those notes.

Create the tap once, before the first `make publish`:

```bash
gh repo create jack-barr3tt/homebrew-mactivity --public --description "Homebrew cask for mactivity"
```

`make publish` creates that repository if it is still missing.

On an Apple silicon Mac, check out that tag and run `make publish`. That builds `Mactivity.app`, copies `mactivityd` into the bundle, ad-hoc signs it, and uploads `Mactivity-darwin-arm64.zip` to the release. It then writes the version and sha256 into the cask on `jack-barr3tt/homebrew-mactivity`.

```bash
brew tap jack-barr3tt/homebrew-mactivity
brew install --cask mactivity
```

The cask in `packaging/homebrew/Casks/mactivity.rb` is the formula. Its version and sha256 there are placeholders; `make publish` fills them in on the tap.

Secrets, set in Woodpecker:

| Secret | Purpose |
| --- | --- |
| `github_token` | GitHub token that can read pull requests and create releases |
