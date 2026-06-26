#!/usr/bin/env bash
set -euo pipefail

# Applies the public-read / owner-controlled GitHub repository settings used by
# PlushBuddy. This script intentionally reads the token from the environment or
# macOS Keychain and never prints it.
#
# Required token:
#   - Classic PAT: "repo" scope for private repos, "public_repo" may be enough
#     for public repos, plus administration access to the target repository.
#   - Fine-grained PAT: target this repository and grant Administration: read/write,
#     Contents: read/write, Actions: read/write.
#
# Usage:
#   export GITHUB_TOKEN='...'
#   tools/github/apply_repo_settings.sh palwe-prafulla plushpal main
#
# Or store the token in macOS Keychain once:
#   security add-generic-password -a "$USER" -s codex.github.token -w '...'
#   tools/github/apply_repo_settings.sh palwe-prafulla plushpal main
#
# Optional:
#   DRY_RUN=1 tools/github/apply_repo_settings.sh palwe-prafulla plushpal main

OWNER="${1:-palwe-prafulla}"
REPO="${2:-plushpal}"
BRANCH="${3:-main}"
API_ROOT="${GITHUB_API_ROOT:-https://api.github.com}"

if [[ -z "${GITHUB_TOKEN:-}" ]] && command -v security >/dev/null 2>&1; then
  GITHUB_TOKEN="$(security find-generic-password -a "$USER" -s codex.github.token -w 2>/dev/null || true)"
fi

if [[ -z "${GITHUB_TOKEN:-}" ]] && command -v security >/dev/null 2>&1; then
  GITHUB_TOKEN="$(security find-generic-password -a "$USER" -s plushpal.github.token -w 2>/dev/null || true)"
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN is required. Export it in your shell or store it in macOS Keychain service codex.github.token, then rerun." >&2
  exit 2
fi

api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local response
  local status

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "DRY_RUN ${method} ${path}"
    if [[ -n "${data}" ]]; then
      echo "${data}"
    fi
    return 0
  fi

  if [[ -n "${data}" ]]; then
    response="$(curl -sS \
      -w $'\n%{http_code}' \
      -X "${method}" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      "${API_ROOT}${path}" \
      --data "${data}")"
  else
    response="$(curl -sS \
      -w $'\n%{http_code}' \
      -X "${method}" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${API_ROOT}${path}")"
  fi

  status="$(printf '%s' "${response}" | tail -n 1)"
  response="$(printf '%s' "${response}" | sed '$d')"

  if [[ "${status}" -lt 200 || "${status}" -ge 300 ]]; then
    echo "GitHub API request failed: ${method} ${path} -> HTTP ${status}" >&2
    if [[ -n "${response}" ]]; then
      printf '%s\n' "${response}" >&2
    fi
    exit 1
  fi
}

echo "Configuring GitHub repository: ${OWNER}/${REPO}"

echo "1/4 Disable optional collaboration surfaces..."
api PATCH "/repos/${OWNER}/${REPO}" '{
  "has_issues": false,
  "has_projects": false,
  "has_wiki": false,
  "has_discussions": false,
  "delete_branch_on_merge": true,
  "allow_merge_commit": false,
  "allow_squash_merge": false,
  "allow_rebase_merge": true,
  "allow_auto_merge": false
}'

echo "2/4 Enable GitHub Actions with least-privilege default workflow token..."
api PUT "/repos/${OWNER}/${REPO}/actions/permissions" '{
  "enabled": true,
  "allowed_actions": "all"
}'

api PUT "/repos/${OWNER}/${REPO}/actions/permissions/workflow" '{
  "default_workflow_permissions": "read",
  "can_approve_pull_request_reviews": false
}'

echo "3/4 Protect ${BRANCH} against force-pushes/deletions..."
api PUT "/repos/${OWNER}/${REPO}/branches/${BRANCH}/protection" "{
  \"required_status_checks\": null,
  \"enforce_admins\": false,
  \"required_pull_request_reviews\": null,
  \"restrictions\": null,
  \"required_linear_history\": false,
  \"allow_force_pushes\": false,
  \"allow_deletions\": false,
  \"block_creations\": false,
  \"required_conversation_resolution\": false,
  \"lock_branch\": false,
  \"allow_fork_syncing\": true
}"

echo "4/4 Verify repository and branch protection endpoints are reachable..."
api GET "/repos/${OWNER}/${REPO}"
api GET "/repos/${OWNER}/${REPO}/branches/${BRANCH}/protection"

echo "Done. GitHub repository settings were applied for ${OWNER}/${REPO}:${BRANCH}."
