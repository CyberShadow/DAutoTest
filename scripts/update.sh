#!/bin/bash
set -eEuo pipefail

cd "$(dirname "$0")"/..

git pull
git submodule update
scripts/build.sh
killall autotest
