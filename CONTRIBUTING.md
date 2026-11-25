# Contributing to moocp

How we work on moocp. For architecture, building and testing see the developer handbook in the [README](README.md) (part 4, in German). Decisions about the program itself are recorded as ADRs in `docs/adr/`; this file covers how we collaborate.

Everything on GitHub (issues, pull requests, commits, branch names, labels) is written in English. The README, the changelog and all texts shown in the app stay German, because the users are German teachers.

## Principles

- An issue is assigned before anyone works on it, people and AI tools alike: assign it to yourself first, and never start on an issue assigned to someone else without talking to them and changing the assignment. This is how we avoid doing the same work twice.
- One shared repository, no forks. Everyone with write access works on short-lived branches.
- `main` is protected: changes only via pull request (PR), never a force-push, never a rewrite of history.
- Everyone can start and build their own things without asking first. Most changes are reviewed after the merge (see [Review and merge](#review-and-merge)); testers on the nightly channel do the rest.
- Work is split by feature, never by platform. There are no `windows` or `macos` branches. A platform is described with labels and in the issue.

## Contributing or building a plugin

There are two ways to add something, and both are welcome:

- **Contribute to moocp.** If a feature belongs in moocp itself, open an issue here. Once accepted, it is part of moocp, covered by its guarantees, and discussed here like everything else.
- **Build a plugin.** If you want to develop independently, build a plugin in your own project, with its own repository, issues and releases. You do not need to ask first. The plugin interface is described in the README (part 4).

A plugin is the responsibility of its own project. This repository, its issues and its pull requests therefore contain nothing about a particular plugin and nothing about features that only a plugin has. Questions and requests about the plugin interface itself belong here, described by what the interface has to do in general, not by one use case.

### Developing plugins in test mode

For end-to-end runs without clicks, moocp has a test mode that also covers plugins within narrow limits. It exists only in a debug build started with `--dart-define=MOOCP_TESTBETRIEB=true` and only for an instance profile explicitly bound to a test course (`MOOCP_TESTZUGANG_PROFILE`, see `docs/agents/testing.md`); the installed app never has it. For a plugin under development, start moocp from source, for example `flutter run -d windows --dart-define=MOOCP_TESTBETRIEB=true -a --plugin-entwicklung -a <plugin folder>`, with the key in `MOOCP_PLUGIN_SCHLUESSEL` as usual.

- Built-in tools called by the plugin follow the existing test-mode rules (own hidden ZZ probes in bound test courses).
- A write to an additional address is approved automatically only inside a run (`/v1/moodle/lauf/beginnen`) whose course is a bound test course and whose course and activity the address matches; everywhere else the approval dialog shows.
- Prepared answers for the plugin's dialogs go into `plugin-dialoge.json` next to the test profile's access file, matched by plugin short name, dialog kind and title. Without a matching answer the dialog shows.
- Never automatic: the consent to a plugin, the dialog of a development plugin, interface and update dialogs, `/v1/freigabe`, and everything that asks on every level. The name check is unchanged.

Every automatic step is in the log and in the answer. Details and the file format are in the README (part 4, "Plugins im Testbetrieb").

## Issues

- Every piece of work starts as an issue. Small obvious fixes may go straight to a PR.
- Use the issue templates. State which systems are affected: *confirmed* (you tried it), *suspected* or *unknown*.
- Do not put real instance addresses, school names, course numbers or personal data in issues or PRs (the repository is public).

### Labels

| Group | Labels |
|---|---|
| Triage | `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix` |
| Kind | `bug`, `enhancement`, `refactoring`, `documentation`, `question` |
| Platform | `os:windows`, `os:macos`, `os:linux`, `os:all`, `os:unclear` |
| Area | `skills` (mainly changes the text of the skills in `skills/`, no new tool) |
| Release | `nightly` (found in or about a nightly), `post-reviewed` (PR reviewed after its merge) |

A platform label is set by the person who knows. With `os:unclear` also set `needs-info`; whoever reproduces or fails to reproduce the problem on another system comments and corrects the label. For a given system, the person who tested on it has the last word.

`skills` marks issues that bring knowledge into the skills rather than change the app: they are worked on in `skills/` (`skills/CLAUDE.md`), need no build and no platform test, and so carry no platform label. Kind and triage state are set as usual. If a new or changed tool is needed as well, it is an app issue, and the skill part is a sub-item of it.

## Branches

Create a branch from an up-to-date `main`, named `<kind>/<issue-number>-<short-slug>`:

`fix/42-backup-no-user-data`, `feat/17-linux-bridge`, `docs/contributing`, `chore/…`, `refactor/…`.

- One issue, one branch, one PR. A PR contains one complete feature or fix, so nobody needs three PRs to understand one change.
- Size is a guideline, not a rule. Up to roughly 2000 changed lines is normal; beyond that ask whether the change can be sliced. Slices should be mergeable on their own, and unfinished work is simply not wired in yet.
- Only if a feature cannot be sliced, use an integration branch `feat/<name>`. Sub-PRs target that branch, and one final PR goes to `main`. Sub-branches exist only below an integration branch. Merge `main` into it regularly.
- Keep your branch current by merging `main` into it. Never rebase commits you have already pushed.
- Delete the branch after the merge. Release branches `release/x.y` are the exception: they stay (see [Hotfixes](#hotfixes)).

## Pull requests

- The title says what changes for the user or the maintainer; it ends up in the history.
- The description says what and why, links the issue (`Closes #42`) and names what you tested and on which system.
- If a conversation would be easier than comments, say so in the PR ("a call might help").
- User-visible changes get one line under the upcoming version in `CHANGELOG.md` (German, see the rules in `CLAUDE.md`).
- Run `flutter analyze` and `flutter test` before opening the PR.

## Review and merge

We follow **Ship / Show / Ask** (Rouan Wilsenach, martinfowler.com). Every PR is one of three kinds; say which in the description.

| Kind | When | Review |
|---|---|---|
| **Show** (default) | everything not listed under Ask or Ship | Merge it yourself once `flutter analyze` and `flutter test` are green. The other maintainer reviews it afterwards and sets the label `post-reviewed`. Findings become a follow-up issue or PR. |
| **Ask** | any path in `.github/CODEOWNERS`, every hotfix, every change to these rules | Merge only after the other maintainer has agreed, in person, by message or in a GitHub review. A formal approval in GitHub is not required; whoever merges notes the agreement in the PR. |
| **Ship** | typos and wording only | none |

- One issue, one PR. Small PRs can be reviewed one by one after the merge; a PR collecting several issues turns that into one huge review.
- `.github/CODEOWNERS` lists the paths that are always Ask and requests the other maintainer as reviewer automatically:
  - the blocklist and allowlist (`sperrliste.dart`, `moodle_zugang.dart`, `browserliste.dart`) and interactive elements (`elemente.dart`),
  - approval logic (`freigabe.dart`) and credentials (`anmeldedaten.dart`, `anmeldung.dart`),
  - installer and update (`installer/`, `lib/update/`),
  - `CLAUDE.md`, `AGENTS.md`, the ADRs, `CONTRIBUTING.md` and `.github/` (workflows, templates, CODEOWNERS).

  This is why data protection and approvals (A1, A3 in `CLAUDE.md`) are as safe in a nightly as in a stable release.
- An AI review runs on every PR. A human decides what to take from it and still looks at the whole change.
- A change that a previous stable release could not read back (settings, profiles, stored files) is a mandatory review point: users must always be able to return to stable.
- Post-reviews are not urgent, but they gate the next stable release: nothing becomes stable while a PR up to that commit lacks `post-reviewed`.
- Merge method: **merge commit** by default, so every single commit stays traceable. **Squash** only if the history of the branch is messy. **No rebase merge.** A PR can be traced on GitHub even after its branch is deleted.
- If one of us is away for a longer time, the other carries on and leaves a short note in the affected issue or PR about what changed in the meantime.

## Communication

- Decisions are made in the issue or PR, with an `@` mention so the other one is notified. Set the other maintainer as reviewer.
- Fundamental questions are discussed by phone or mail first, and the result is written down in the issue, a PR or an ADR.
- GitHub Discussions are off. We switch them on if discussions get too big for issues.

## Releases

There are two channels. The decision and its reasons are ADR E39 (`docs/adr/0039-release-kanaele.md`), the commands are in the README (part 4, "Veröffentlichen").

### Nightly

A nightly is the current state of `main`. GitHub Actions builds and publishes it every night if `main` has new commits, and any maintainer can start one by hand at any time ("Run workflow"); that is also how a tested fix reaches testers quickly. The tag is `v<upcoming version>-nightly.<YYYYMMDD>.<n>`, the release is marked as a pre-release, and its text is the section of the upcoming version in `CHANGELOG.md`. `main` always carries the next minor version in `pubspec.yaml`. Patch versions are kept for hotfixes.

Testers report problems with the issue template for nightlies; such issues get the label `nightly`.

### Stable

A maintainer picks a published nightly (not necessarily the latest), tags exactly its commit `v<version>` and starts the release workflow for that tag (README part 4, "Veröffentlichen"). Before a stable release:

- the nightly has been out for at least 14 days,
- no open issue with `nightly` and `bug` affects it or an earlier nightly,
- every PR up to that commit has `post-reviewed`,
- the other maintainer approves the `stable` environment, confirming they used that nightly long enough.

The workflow checks the tag, the version and green checks, then waits for the approval in the environment `stable`; the first three points are not automated yet, so the other maintainer checks them before approving. Then the workflow creates the release, and `main` moves to the next minor version.

### Hotfixes

A hotfix fixes the current stable release without shipping the new features already on `main`. The trick is a release branch that only exists once it is needed:

```
main           A ── B ── C ── F′ ── D     F′ = the fix, lands here first
               │
               └── tag v0.13.0
release/0.13   A ── F                     F = F′ cherry-picked → tag v0.13.1
```

1. Fix the bug on `main` with a normal PR (F′). The next nightly has it.
2. If `release/0.13` does not exist yet, create it from the stable tag: `git switch -c release/0.13 v0.13.0`, push it.
3. On a branch from `release/0.13`, cherry-pick only the fix: `git cherry-pick -x <commit of F′>`. `-x` notes the original commit in the message. Because a fix is small, conflicts are rare; if there is one, resolve it like a merge conflict. If the release branch has no `.github/workflows/checks.yml` yet (it was cut before the checks existed), cherry-pick the commit that added it first; otherwise the required checks never report and the PR stays blocked. Open the PR against `release/0.13` (kind Ask), bump the patch version in `pubspec.yaml` and add the `CHANGELOG.md` line.
4. After the merge, tag the branch `v0.13.1` and run the release workflow for that tag. No waiting period: the fix was already tested on `main`.

Stable users get 0.13.1. Nightly users already have the fix and are not offered it, because 0.13.1 is lower than 0.14.0-nightly. A release branch is never merged back into `main`; the next hotfix of the same version continues on it.

### Repository settings

These settings carry the rules; changing them is a rule change (Ask):

- `main`: PR required, required status checks `flutter analyze` and `flutter test` (the job names of the `Checks` workflow, which runs on Linux for every PR and every push to `main`; rename a job only together with this rule), required approvals 0, review from code owners not required, no force-push, no deletion. Ask relies on the agreement between the maintainers; if that proves too loose, "require review from code owners" is switched on again.
- `release/*`: same, but one approval required.
- Environment `stable`: required reviewer is the other maintainer; the person who started the run cannot approve it.
- Workflows: `Checks` (`flutter analyze`, `flutter test`) runs automatically on every PR and every push to `main`, Linux only. Builds and tests on Windows and macOS run only on request or in the release workflow (a nightly builds all three platforms when `main` has new commits), never otherwise (their runners are scarce and slow): `python3 tool/ci_bau.py <platforms>` from a branch, the commit markers `[ci:linux]`, `[ci:windows]`, `[ci:macos]`, or "Run workflow" with `platform` and `task`. Details in the README (part 4, "Prüfen und Bauen mit GitHub Actions"). Workflows use pinned major versions of actions and `permissions: contents: read`.
