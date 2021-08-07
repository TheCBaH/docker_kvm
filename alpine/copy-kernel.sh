#!/bin/sh
set -x
set -eu
this_dir=$(dirname $0)
ver=${1:-latest-stable}
img="data/img/alpine-$ver-boot.img"
temp=data/img.$ver
mkdir -p $temp
virt-copy-out -a $img /boot/vmlinuz-virt /boot/initramfs-virt /boot/extlinux.conf $temp
for f in vmlinuz-virt initramfs-virt extlinux.conf ; do
  mv $temp/$f data/img/alpine-$ver-$f
done
rm -rf $temp
