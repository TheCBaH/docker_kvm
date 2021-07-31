#!/bin/sh
set -x
set -eu

_step_counter=0
step() {
	_step_counter=$(( _step_counter + 1 ))
	printf '\n\033[1;36m%d) %s\033[0m\n' $_step_counter "$@" >&2  # bold cyan
}


step 'Set up timezone'
setup-timezone -z ${TIMEZONE:-UTC}

step 'Set up networking'
cat > /etc/network/interfaces <<-EOF
	iface lo inet loopback
	iface eth0 inet dhcp
EOF
ln -s networking /etc/init.d/net.lo
ln -s networking /etc/init.d/net.eth0

step 'Adjust rc.conf'
sed -Ei \
	-e 's/^[# ](rc_depend_strict)=.*/\1=NO/' \
	-e 's/^[# ](rc_logger)=.*/\1=YES/' \
	-e 's/^[# ](unicode)=.*/\1=YES/' \
	/etc/rc.conf

step 'Enable services'
rc-update add acpid default
rc-update add net.eth0 default
rc-update add net.lo boot

step 'Remove extra files'
rm -rf\
 /lib/modules/*/kernel/arch/x86/kvm \
 /lib/modules/*/kernel/drivers/gpu \
 /lib/modules/*/kernel/drivers/md \
 /lib/modules/*/kernel/drivers/scsi \
 /lib/modules/4.19.118-0-virt/kernel/fs/btrfs \
 /lib/modules/4.19.118-0-virt/kernel/fs/nls \
 /lib/modules/4.19.118-0-virt/kernel/fs/ocfs2 \
 /lib/modules/4.19.118-0-virt/kernel/fs/xfs \
 /var/cache/apk/* \
 ;

step 'Update boot'
for n in $(seq 2 6); do
	sed -Ei "s/^(tty$n)/#\1/" /etc/inittab
done
sed -i s/timeout=3/timeout=1/ /etc/update-extlinux.conf
update-extlinux --warn-only
rc-update add dropbear boot

step 'Disable IPV6'
echo 'net.ipv6.conf.all.disable_ipv6 = 1' >>  /etc/sysctl.conf

step 'Add user account'
user=$1;shift
uid=$1;shift
group=$1;shift
gid=$1;shift
key=$1;shift
addgroup -g $gid $group
adduser -u $uid -G $group -D $user
addgroup sudo
addgroup $user sudo
chpasswd <<_PASSWD_
root:$user-root
$user:$user
_PASSWD_
apk --no-cache add openssh-client su-exec
echo | su-exec $user ssh-keygen -P ''
auth=/home/$user/.ssh/authorized_keys
echo "$key" | su-exec $user tee -a $auth
apk --no-cache del openssh-client su-exec
chmod a=,u=rw $auth
echo "$user ALL=(ALL) NOPASSWD:ALL" >>/etc/sudoers
