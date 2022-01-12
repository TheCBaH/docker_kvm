#!/bin/sh
set -x
set -eu
this_dir=$(dirname $0)
ver=${1:-latest-stable}
data_dir=${DATA_DIR:-data}
img="$data_dir/img/alpine-$ver-boot.img"
temp=$data_dir/img.$ver
mkdir -p $temp
virt-copy-out -a $img /boot/vmlinuz-virt /boot/initramfs-virt /boot/extlinux.conf $temp
for f in vmlinuz-virt initramfs-virt extlinux.conf ; do
  mv $temp/$f $data_dir/img/alpine-$ver-$f
done
rm -rf $temp
