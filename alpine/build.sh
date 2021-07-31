#!/bin/sh
set -x
set -eu
this_dir=$(dirname $0)
ver=${1:-latest-stable}
user=$(echo ${USERINFO}|cut -f1 -d:);\
uid=$(echo ${USERINFO}|cut -f2 -d:);\
group=$(echo ${USERINFO}|cut -f3 -d:);\
group=$user;\
gid=$(echo ${USERINFO}|cut -f4 -d:);\
img="data/img/alpine-$ver-boot.img"
rm -rf $img
_sudo='sudo'
if [ $(id -u) -eq 0 ]; then
  _sudo=''
fi
$_sudo env APK_OPTS='--verbose' http_proxy=${http_proxy:-} alpine-make-vm-image/alpine-make-vm-image \
 --branch $ver\
 --image-format qcow2\
 --image-size 1G\
 --initfs-features virtio\
 --packages "$(cat $this_dir/packages)"\
 --repositories-file /dev/null\
 --script-chroot\
 --serial-console\
 $img -- $this_dir/configure.sh $user $uid $group $gid "$(cat data/img/id_kvm.pub)"
$_sudo chown $user $img
