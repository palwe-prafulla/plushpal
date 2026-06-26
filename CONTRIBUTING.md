# Contributing to PlushBuddy

Thanks for taking a look at PlushBuddy.

This public repository is currently a personal showcase/open-source reference
project. It is not accepting external pull requests, patches, direct commits,
or community-maintained changes.

You are welcome to fork the project under the license terms and experiment in
your own copy.

## Pull request policy

External pull requests are not accepted. PRs opened against this repository may
be automatically closed by the repository workflow.

If this policy changes later, this file will be updated first.

## Development setup for forks

From a fresh clone:

```sh
git submodule update --init --recursive
make public-artifacts
qa/automation/run_local_quality_gate.sh
```

Build and test outputs are written outside the repository under
`~/Downloads/PlushPal` by default.

If you fork the project and make local changes, the main local quality gate is:

```sh
qa/automation/run_local_quality_gate.sh
```

If your change touches packaging, also run:

```sh
make public-artifacts
```

If your change touches Android, iPhone, browser, Mac client, or MacStation
behavior in your fork, keep the relevant smoke-test evidence from
`~/Downloads/PlushPal/test-results`.

## Privacy and safety rules

- Do not commit API keys, `.env` files, signing keys, keystores, private audio
  samples, private photos, generated voice profiles, or local model/runtime
  caches.
- Do not add cloud calls that bypass explicit parent configuration.
- Do not send raw child/kid profile data to cloud providers unless the current
  design document and UI consent flow explicitly allow it.
- Keep generated build/test artifacts outside the repo.

## Code style

- Keep reusable product logic in shared Flutter/Rust layers where possible.
- Keep MacStation responsible for voice/model services, not for owning client
  profile/history state.
- Prefer focused tests for each regression.
