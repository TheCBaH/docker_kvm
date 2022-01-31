#!/bin/sh
set -eux
(
	cat /etc/os-release
	. /etc/os-release
	gpu="/lib/modules/*/kernel/drivers/gpu"
	echo $VERSION_ID
    case "$VERSION_ID" in
	3.15.*)
		find $gpu -type f| awk '/\/drm.ko/ || /\/drm_panel_orientation_quirks.ko/ {next} {print $1}'|xargs rm -f
		find $gpu -type d -empty -delete
		;;
    *)
		rm -rf $gpu
		;;
	esac
)
rm -rf\
 /lib/modules/*/kernel/arch/x86/kvm \
 /lib/modules/*/kernel/drivers/md \
 /lib/modules/*/kernel/drivers/scsi \
 /lib/modules/*/kernel/drivers/usb \
 /lib/modules/*/kernel/fs/btrfs \
 /lib/modules/*/kernel/fs/nls \
 /lib/modules/*/kernel/fs/ocfs2 \
 /lib/modules/*/kernel/fs/xfs \
 /var/cache/apk/* \
 ;

echo 'Update boot'
for n in $(seq 2 6); do
	sed -Ei "s/^(tty$n)/#\1/" /etc/inittab
done
echo 'Disable IPV6'
echo 'net.ipv6.conf.all.disable_ipv6 = 1' >>  /etc/sysctl.conf

sed -iE 's/(GRUB_TIMEOUT=)./\11/' /etc/default/grub
sed -iE 's#(GRUB_CMDLINE_LINUX_DEFAULT=.+)quiet(.+)#\1console=tty0 console=/dev/ttyS0 nomodeset\2#' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
for d in \
 aesni_intel\
 autofs\
 btrfs\
 drm\
 floppy\
 input_leds\
 iscsi_tcp\
 joydev\
 parport_pc\
 psmouse\
 raid0\
 raid10\
 raid1\
 raid456\
 usb_common\
 usb_storage\
 usbcore\
    ; do
        echo "blacklist $d" >>/etc/modprobe.d/blacklist-kvm.conf
    done
