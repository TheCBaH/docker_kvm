#!/bin/sh
set -eu
set -x
apk --no-cache add\
 gcompat\
 git\
 libgcc\
 libstdc++\
 make\
 musl\

mkdir -p /opt/data

sed -i -E 's/^(AllowTcpForwarding +)no/\1yes/' /etc/ssh/sshd_config
