#!/bin/bash
set -eEuo pipefail

cd "$(dirname "$0")"/..

dest=results-bad/$(date +%s)
mkdir -p "$dest"

for FN in $(ls results/\!latest/*.txt | grep -vE '/[0-9a-f]{40}\.txt$')
do
    hash=$(cat $FN)
    echo "$hash"
    mv results/"$hash" "$dest"/ || true
done

mv site/cache-git "$dest"/

killall autotest
killall webserver # need new cat-file process

echo OK
