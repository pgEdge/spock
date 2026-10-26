#!/bin/bash

set -euo pipefail

containers=$(docker ps -aq --filter "label=com.docker.compose.project=tests");

count=$(echo "$containers" | grep -c . || true)
if [ "$count" -ne 3 ]; then
  echo "FAIL: expected 3 test containers, found $count"
  exit 1
fi

for cid in $containers; do
  exit_code=$(docker inspect -f '{{ .State.ExitCode }}' "$cid")
  if [ "$exit_code" -ne 0 ]; then
    name=$(docker inspect -f '{{ .Name }}' "$cid" | sed 's|/||')
    echo "FAIL: Container '$name' exited with code $exit_code"
    exit 1
  fi
done
