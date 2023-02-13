ARG OS_VER
FROM ubuntu:${OS_VER}
ARG USERINFO
RUN set -eux; \
    apt-get update;\
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends\
 udev\
    ; \
    apt-get clean; rm -rf /var/lib/apt/lists/*;\
    user=$(echo ${USERINFO}|cut -f1 -d:);\
    uid=$(echo ${USERINFO}|cut -f2 -d:);\
    group=$(echo ${USERINFO}|cut -f3 -d:);\
    group=$user;\
    gid=$(echo ${USERINFO}|cut -f4 -d:);\
    groupadd -g $gid $group;\
    kvm_gid=$(echo ${USERINFO}|cut -f5 -d:);\
    echo $kvm_gid;\
    if [ -z "$kvm_gid" ]; then\
        kvm_gid=$(expr $gid + 1);\
    fi;\
    old_group=$(getent group kvm|cut -d: -f1);\
    if [ -z "$old_group" ]; then\
        groupadd --system -g $kvm_gid kvm;\
    else\
        groupmod --new-name kvm $old_group;\
    fi;\
    useradd -m -u $uid -g $gid $user;\
    usermod -aG sudo $user;\
    usermod -aG kvm $user;\
    echo DONE
RUN set -eux;\
    apt-get update;\
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends\
 libguestfs-tools\
 linux-image-kvm\
 make\
 openssh-client\
 ovmf\
 python3-pexpect\
 python3-yaml\
 python3\
 qemu-kvm\
 socat\
 sudo\
 udhcpd\
    ; \
    chmod a+r /boot/vmlinuz*;\
    apt-get clean; rm -rf /var/lib/apt/lists/*;\
    echo DONE
RUN set -eux;\
    user=$(echo ${USERINFO}|cut -f1 -d:);\
    echo "$user ALL=(ALL) NOPASSWD:ALL" >>/etc/sudoers;\
    echo DONE
