#!/bin/bash
set -eEuo pipefail

cd "$(dirname "$0")"/..

(
	cd work/cache-git/v3/

	find .git/refs/ae-sys-d-cache/ -type f -mtime +56 -delete
	git gc
)

for d in results results-bad
do
	find $d/ -name build.log -mtime +56 -delete
done
