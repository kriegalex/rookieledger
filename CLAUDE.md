# CLAUDE.md

Guidance for Claude Code when working in this repository. What the project is and how its parts fit is in
`README.md`; what the game client was seen to do is in `docs/client-behaviour.md`.

## Git workflow: trunk-based development

- `main` is the only long-lived branch and is always releasable. It is protected on GitHub: no direct push, no force
  push, no deletion, linear history. This holds for the owner too.
- Every feature, bugfix or other change is made on its own short-lived branch, cut from the latest `main` and named
  `<type>/<short-name>` with the Conventional Commits types: `feat/group-loot`, `fix/queue-skill-point`,
  `docs/…`, `ci/…`, `build/…`, `chore/…`.
- A branch reaches `main` through a pull request whose checks are green (`test`, `image` and `windows`, the jobs of
  `.github/workflows/ci.yml`) and which is up to date with `main`: GitHub refuses the merge otherwise. It is merged
  by rebase and fast-forward, never squashed and never with a merge commit, so the commits of the branch land on
  `main` as they are. GitHub deletes the branch on merge.
- Every commit of a branch is therefore a Conventional Commit worth keeping (`feat(addon): …`). Fix-ups are folded
  into the commit they fix before the merge is asked for (`git commit --fixup` then `git rebase --autosquash`).
- A branch that fell behind is rebased onto `main` (`git fetch && git rebase origin/main`), not merged with it, and
  pushed again with `git push --force-with-lease`. Rewriting history is for one's own unmerged branch only.
- Branches live for days, not weeks. A feature too large for that lands in several small pull requests, each leaving
  `main` working; what is not ready stays behind a switch that defaults to off, as `LEDGER_REGISTRATION` and
  `LEDGER_API_AUTH` do. There is no `develop` and there are no release branches.
- A release is a tag on `main`. The pull request that finishes a version also heads `CHANGELOG.md` with
  `# RookieLedger vX.Y.Z`; once it is merged, tag that commit of `main` and push the tag (`README.md`, "Releases").

For Claude:

- Never commit on `main`. Before the first edit of a task, create its branch (`git switch -c <type>/<name> main`
  after `git pull --ff-only`); one task, one branch.
- Commit and push the branch, and open the pull request with `gh pr create`, only when the user asks for it. Merge
  (`gh pr merge --rebase`) only on their word and with the checks green, then return to `main` and pull.
- Tagging a release is the user's decision each time.

## Checks to run before a pull request

```sh
python3 -I -m unittest discover -s tests -v    # addon (under lua5.1) and server
(cd companion && go vet ./... && go test ./...)
docker build --build-arg VERSION=v0.0.0 -t rookieledger-server:ci server && server/image_test.sh rookieledger-server:ci v0.0.0   # when server/ changed
```
