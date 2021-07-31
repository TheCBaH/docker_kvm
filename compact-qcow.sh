#!/bin/sh
set -eu
set -x
image=$1
du -h $image
virt-sparsify --in-place $image
qemu-img convert -O qcow2 -c $image $image.tmp
mv $image.tmp $image
du -h $image
