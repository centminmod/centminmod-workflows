#!/bin/bash

# Replace these variables with your actual values
GITHUB_USERNAME='centminmod'
REPO_NAME='centminmod-workflows'
GITHUB_TOKEN="your_personal_access_token"

# Function to cancel in-progress workflow runs
cancel_in_progress_workflow_runs() {
  local page=1
  while :; do
    response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/$GITHUB_USERNAME/$REPO_NAME/actions/runs?status=in_progress&per_page=100&page=$page")

    run_ids=$(echo "$response" | jq -r '.workflow_runs[].id')

    # Break if no more runs
    if [[ -z "$run_ids" ]]; then
      break
    fi

    for run_id in $run_ids; do
      curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$GITHUB_USERNAME/$REPO_NAME/actions/runs/$run_id/cancel"
    done

    # Increment page number
    page=$((page + 1))
  done
}

# Cancel all in-progress workflow runs
cancel_in_progress_workflow_runs