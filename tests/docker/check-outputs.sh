#!/bin/bash

set -euo pipefail

containers=$(docker ps -aq --filter "label=com.docker.compose.project=tests");

for cid in $containers; do
  exit_code=$(docker inspect -f '{{ .State.ExitCode }}' "$cid")
  if [ "$exit_code" -ne 0 ]; then
    name=$(docker inspect -f '{{ .Name }}' "$cid" | sed 's|/||')
    echo "FAIL: Container '$name' exited with code $exit_code"
    exit 1
  fi
done
