#!/bin/sh
set -eux

apk --no-cache add hvtools
for s in  fcopy kvp vss; do
    n=hv_${s}_daemon
    rc-service $n start
    rc-update add $n
done
