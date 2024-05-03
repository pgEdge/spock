#!/bin/bash

set -e

exception_entries=$(cat ${GITHUB_WORKSPACE}/exception-tests.out)
echo $exception_entries
if [ $exception_entries != 3 ];
then
  exit 1
fi

spockbench_files=$(ls ${GITHUB_WORKSPACE}/spockbench-*.out | wc -l)
echo $spockbench_files

if [ $spockbench_files != 3 ];
then
  exit 1
fi

grep -q "ERROR" ${GITHUB_WORKSPACE}/spockbench-*.out && exit 1 || exit 0
