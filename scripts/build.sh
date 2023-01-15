#!/bin/bash
set -eEuo pipefail

cd "$(dirname "$0")"/..

D_COMPILER=$(cat .d-compiler)
test -e ~/dlang/"$D_COMPILER" || { curl -fsS https://dlang.org/install.sh | bash -s "$D_COMPILER" ; }
source ~/dlang/"$D_COMPILER"/activate

for f in autotest.d webserver.d
do
    rdmd -g --build-only -L-lssl -L-lcrypto $f
done
