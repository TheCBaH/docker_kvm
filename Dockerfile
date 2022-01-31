ARG OS_VER
FROM ubuntu:${OS_VER}
ARG USERINFO
RUN set -eux; \
    user=$(echo ${USERINFO}|cut -f1 -d:);\
    uid=$(echo ${USERINFO}|cut -f2 -d:);\
    group=$(echo ${USERINFO}|cut -f3 -d:);\
    group=$user;\
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
 ovmf\
 python3-pexpect\
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
