ARG UBUNTU_VER
FROM ubuntu:${UBUNTU_VER}
ARG USERINFO
RUN set -eux; \
    user=$(echo ${USERINFO}|cut -f1 -d:);\
    uid=$(echo ${USERINFO}|cut -f2 -d:);\
    group=$(echo ${USERINFO}|cut -f3 -d:);\
    gid=$(echo ${USERINFO}|cut -f4 -d:);\
    kvm_gid=$(echo ${USERINFO}|cut -f5 -d:);\
    groupadd -g $gid $group;\
    if [ -z "$kvm_gid" ]; then\
        kvm_gid=$(expr $gid + 1);\
    fi;\
    groupadd -g $kvm_gid kvm;\
    useradd -m -u $uid -g $gid $user;\
    usermod -aG sudo $user;\
    usermod -aG kvm $user;\
    echo DONE
RUN set -eux;\
    apt-get update;\
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends\
 libguestfs-tools\
 linux-image-kvm\
 openssh-client\
 qemu-kvm\
 socat\
    ; \
    chmod a+r /boot/vmlinuz*;\
    apt-get clean; rm -rf /var/lib/apt/lists/*;\
    echo DONE
