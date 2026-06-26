# GitHub repository settings

Use these settings after creating the public GitHub repository.

The goal is: public read access, but no external contribution workflow.

Most settings can be applied by API:

```sh
export GITHUB_TOKEN='...'
tools/github/apply_repo_settings.sh palwe-prafulla plushpal main
```

Or store the token in macOS Keychain so future terminal sessions can use it
without a plaintext project `.env` file:

```sh
security add-generic-password -a "$USER" -s plushpal.github.token -w '...'
tools/github/apply_repo_settings.sh palwe-prafulla plushpal main
```

Use a fine-grained token scoped to this repository with Administration
read/write, Contents read/write, and Actions read/write. Do not commit or paste
the token into docs, issues, or chat transcripts.

## General repository features

In **Settings -> General -> Features**:

- Disable Wikis.
- Disable Discussions unless you intentionally want public discussion.
- Disable Projects unless you need them.
- Disable Issues if you do not want issue reports.

GitHub does not provide a normal "disable pull requests" toggle for an active
public repository. This repo therefore includes:

- `.github/PULL_REQUEST_TEMPLATE.md`, which tells users PRs are not accepted;
- `.github/workflows/close-external-prs.yml`, which automatically comments on
  and closes pull requests from users other than the repository owner.

If you want the repository to become completely read-only later, use GitHub's
**Archive repository** option. Archived repositories cannot receive new issues,
pull requests, or pushes until unarchived.

## Branch protection

In **Settings -> Branches -> Branch protection rules**, protect `main`:

- Require a pull request before merging: optional if only the owner commits
  directly.
- Restrict who can push to matching branches: enable and select only the owner
  for organization repositories. Personal-account repositories do not support
  this restriction; instead, do not add collaborators unless they should be able
  to push.
- Do not allow force pushes.
- Do not allow deletions.
- Require status checks before merging if you later allow owner PRs.

In **Settings -> Collaborators and teams**:

- Do not add collaborators unless they should be able to push.
- If collaborators are ever added, give the least privilege possible.

## Actions permissions

In **Settings -> Actions -> General**:

- Allow GitHub Actions for this repository.
- Keep workflow permissions at least-privilege.
- The auto-close PR workflow needs `pull-requests: write` and `issues: write`,
  which are declared in the workflow file.

## Secrets

Do not add personal Gemini/OpenAI keys as repository secrets for this public
project unless you intentionally want CI to call those providers.

Provider keys used for manual testing should stay local and outside the repo.
