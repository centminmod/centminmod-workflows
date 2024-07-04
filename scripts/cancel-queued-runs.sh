#!/bin/bash

# Replace these variables with your actual values
GITHUB_USERNAME='centminmod'
REPO_NAME='centminmod-workflows'
GITHUB_TOKEN="your_personal_access_token"

# List all queued workflow runs
queued_runs=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  https://api.github.com/repos/$GITHUB_USERNAME/$REPO_NAME/actions/runs?status=queued | jq -r '.workflow_runs[].id')

# Cancel each queued workflow run
for run_id in $queued_runs; do
  curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/repos/$GITHUB_USERNAME/$REPO_NAME/actions/runs/$run_id/cancel
done
