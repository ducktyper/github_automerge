#!/usr/bin/env bash

if [ -s "$HOME/.bashrc" ]; then source "$HOME/.bashrc"; fi

function task { echo -e "\n\033[1;30m$1\033[0m"; }
function note { echo -e "\033[0;32m$1\033[0m"; }
function warn { echo -e "\033[0;33m$1\e[0m"; }
function error { echo -e "\033[0;31m$1\033[0m"; }
function exit_on_fail {
  if [ "$?" -ne 0 ]; then
    error "$1"
    exit 1
  fi
}

MERGE_ENV="$1"
BRANCH="$2"

if [ -z "$MERGE_ENV" ] || [ -z "$BRANCH" ]; then
  echo
  echo "GitHub automerge merges your approved branch handling rebase and waiting for CI for you."
  echo
  echo "How to use:"
  echo
  echo "./merge.sh [ENV_NAME] [BRANCH_NAME]"
  echo
  echo "  [ENV_NAME]: env file name contains the repo details (check .env.example)"
  echo "  [BRANCH_NAME]: approved branch to merge"
  echo
  echo "Example Usage:"
  echo
  echo "./merge.sh github_automerge cool-feature"
  echo
  echo "  This loads the repo details from '.env.github_automerge' and merge the 'cool-feature' branch."
  echo
  exit 0
fi

task "Load repo details"
source "$(dirname "$0")/.env.$MERGE_ENV"
exit_on_fail "Fail to load .env.$MERGE_ENV"

if [ -z "$GITHUB_USERNAME" ] || [ -z "$GITHUB_PERSONAL_ACCESS_TOKEN" ] || [ -z "$GITHUB_ORGANISATION" ] || [ -z "$GITHUB_PROJECT" ] || [ -z "$MIN_CHECK_COUNT" ] || [ -z "$MIN_STATUS_COUNT" ]; then
  error "Some variables are missing from .env.$MERGE_ENV"
  exit 1
fi

task "Check repo"
GITHUB_USER="$GITHUB_USERNAME:$GITHUB_PERSONAL_ACCESS_TOKEN"
GITHUB_URL="https://api.github.com/repos/$GITHUB_ORGANISATION/$GITHUB_PROJECT"
PROJECT_PATH="$(dirname "$0")/projects/$GITHUB_PROJECT"

# Clone repo if not found
if [ ! -d "$PROJECT_PATH" ]; then
  git clone git@github.com:$GITHUB_ORGANISATION/$GITHUB_PROJECT.git $PROJECT_PATH
  exit_on_fail "Fail to clone the repo"
fi

cd $PROJECT_PATH

while true; do
  task "Rebase feature branch"
  git switch main
  git pull origin main
  git fetch origin $BRANCH
  exit_on_fail "Fail to fetch $BRANCH!"
  git show-ref --verify --quiet refs/heads/$BRANCH
  if [ "$?" -eq 0 ]; then
    git branch -D $BRANCH
  fi
  git switch $BRANCH
  git rebase origin/main
  if [ "$?" -ne 0 ]; then
    git rebase --abort
    error "Fail to rebase. Rebase manually and try again!"
    exit 1
  fi
  git push origin -f $BRANCH
  exit_on_fail "Fail to push $BRANCH!"
  COMMIT=$(git rev-parse HEAD)
  note "Branch: $BRANCH"
  note "Commit: $COMMIT"

  task "Find pull request"
  PULLS_RESPONSE=$(
    curl -s -u $GITHUB_USER $GITHUB_URL/pulls -G \
      -d 'page=1' \
      -d 'per_page=1' \
      -d 'state=open' \
      -d "head=$GITHUB_ORGANISATION:$BRANCH"
  )
  exit_on_fail "Fail to get pulls!"
  PULL_REQUESTS=$(echo "$PULLS_RESPONSE" | jq '.[] | {title: .title, number: .number}')
  if [ -z "$PULL_REQUESTS" ]; then
    error "No open pull request!"
    exit 1
  fi
  PULL_NUMBER=$(echo "$PULL_REQUESTS" | jq '.number')
  PULL_TITLE=$(echo "$PULL_REQUESTS" | jq '.title')
  note "Pull title: $PULL_TITLE"
  note "Pull number: $PULL_NUMBER"

  task "Find approved review"
  REVIEWS_RESPONSE=$(curl -s -u $GITHUB_USER $GITHUB_URL/pulls/$PULL_NUMBER/reviews)
  exit_on_fail "Fail to get reviews!"
  APPROVER=$(echo "$REVIEWS_RESPONSE" | jq '.[] | select(.state? == "APPROVED") | .user.login')
  if [ -z $APPROVER ]; then
    error "Yet approved!"
    exit 1
  fi
  note "APPROVED BY: $APPROVER"

  task "Check checks"
  while true; do
    CHECKS_RESPONSE=$(curl -s -u $GITHUB_USER $GITHUB_URL/commits/$COMMIT/check-runs)
    exit_on_fail "Fail to get checks!"
    CHECKS=$(echo "$CHECKS_RESPONSE" | jq '.check_runs | group_by(.name) | map(.[0]) | [.[] | {status: .status, name: .name, html_url: .html_url}]')
    # https://docs.github.com/en/rest/checks/runs#get-a-check-run
    # status: queued, in_progress, completed
    CHECK_COUNT=$(echo "$CHECKS" | jq 'length')
    SUCCESS_CHECK_COUNT=$(echo "$CHECKS" | jq '[.[] | select(.status == "completed")] | length')
    if (( $CHECK_COUNT >= $MIN_CHECK_COUNT && $CHECK_COUNT == $SUCCESS_CHECK_COUNT )); then
      note "All completed: $SUCCESS_CHECK_COUNT"
      break
    fi
    warn "Waiting for checks\n$CHECKS"
    echo "Retry in 60 seconds"
    sleep 60
  done

  task "Check Statuses"
  while true; do
    STATUSES_RESPONSE=$(curl -s -f -u $GITHUB_USER $GITHUB_URL/commits/$COMMIT/statuses)
    exit_on_fail "Fail to get statuses!"
    STATUSES=$(echo "$STATUSES_RESPONSE" | jq '. | group_by(.context) | map(.[0]) | [.[] | {state: .state, context: .context, target_url: .target_url}]')
    FAILED_STATUS_COUNT=$(echo "$STATUSES" | jq '[.[] | select(.state == "failure")] | length')
    if (( $FAILED_STATUS_COUNT > 0 )); then
      error "Some statuses have failed!\n$STATUSES"
      exit 1
    fi
    STATUSES_COUNT=$(echo "$STATUSES" | jq 'length')
    SUCCESS_STATUS_COUNT=$(echo "$STATUSES" | jq '[.[] | select(.state == "success")] | length')
    if (( $STATUSES_COUNT >= $MIN_STATUS_COUNT && $STATUSES_COUNT == $SUCCESS_STATUS_COUNT )); then
      note "All completed: $SUCCESS_STATUS_COUNT"
      break
    fi
    warn "Waiting for statuses\n$STATUSES"
    echo "Retry in 60 seconds"
    sleep 60
  done

  task "Merge"
  COMMIT_COUNT=$(git rev-list --count main..$BRANCH)
  if (( $COMMIT_COUNT == 1 )); then
    git push origin $BRANCH:main
    if [ "$?" -eq 0 ]; then
      break
    fi
    warn "Fail to push. Retry from the start."
  else
    MERGE_RESPONSE=$(
      curl -X PUT -s -u $GITHUB_USER $GITHUB_URL/pulls/$PULL_NUMBER/merge -G \
        -d 'merge_method=merge' \
        -d "sha=$COMMIT"
    )
    MERGED=$(echo "$MERGE_RESPONSE" | jq '.merged')
    if [ "$MERGED" = "true" ]; then
      break
    fi
    warn "Failed to merge. Retry from the start.\n$MERGE_RESPONSE"
  fi
done

# Clean
git checkout main
git branch -D $BRANCH

note "Merged Successfully"
