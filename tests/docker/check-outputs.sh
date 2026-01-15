#!/bin/bash

set -euo pipefail

containers=$(docker ps -aq --filter "label=com.docker.compose.project=tests");

if [ -z "$containers" ]; then
  echo "FAIL: No containers found with label 'com.docker.compose.project=tests'"
  exit 1
fi

for cid in $containers; do
  name=$(docker inspect -f '{{ .Name }}' "$cid" | sed 's|/||')
  exit_code=$(docker inspect -f '{{ .State.ExitCode }}' "$cid")

  # Check exit code
  if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: Container '$name' exited with code $exit_code"
    docker logs "$cid" 2>&1 | tail -50
    exit 1
  fi

  # Check PostgreSQL logs for errors
  if docker exec "$cid" test -d /home/pgedge/pgedge/data 2>/dev/null; then
    pg_log=$(docker exec "$cid" find /home/pgedge/pgedge/data -name "postgresql-*.log" -o -name "*.log" 2>/dev/null | head -1)
    if [ -n "$pg_log" ]; then
      error_count=$(docker exec "$cid" grep -i "ERROR:" "$pg_log" 2>/dev/null | grep -v "ERROR:  relation.*does not exist" | wc -l || echo 0)
      if [ "$error_count" -gt 0 ]; then
        echo "FAIL: Container '$name' has $error_count ERROR(s) in PostgreSQL logs"
        docker exec "$cid" grep -i "ERROR:" "$pg_log" | grep -v "ERROR:  relation.*does not exist" | tail -20
        exit 1
      fi
    fi
  fi

  echo "✓ Container '$name' passed all checks"
done

echo "✓ All containers passed validation"
