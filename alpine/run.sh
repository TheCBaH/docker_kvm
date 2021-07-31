#!/bin/sh
set -x
set -eu
this_dir=$(dirname $0)
ver=${1:-latest-stable}
img="data/img/alpine-$ver-boot.img"
exec qemu-system-x86_64\
  -nographic\
  -m 1G\
  -smp 2\
  -accel kvm\
  -device virtio-net-pci,netdev=net0\
  -netdev user,id=net0,hostfwd=tcp::8022-:22\
  -drive if=virtio,format=qcow2,file=$img\
  -no-reboot\
  -snapshot
