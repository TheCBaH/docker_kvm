#!/bin/bash
set -eu
set -x

apt_install="env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --quiet"
apt_remove="with_retry 10 env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge --quiet"

iface=ens3

with_retry() {
    _n=$1;shift
    _rc=-1
    for i in $(seq $_n); do
        if "$@"; then
            _rc=0
            break;
        else
            _rc=$?
        fi
        sleep $(expr 1 +  $(od -vAn -N1 -tu1 < /dev/urandom) / 10 )
    done
    test $_rc -eq 0
}

if_installed() {
    _tmp_1=$(mktemp -t)
    trap 'rc=$?;rm -f $_tmp_1;exit $rc' EXIT
    apt list --installed $1 >$_tmp_1
    if grep -q $1 $_tmp_1; then
        rc=0
    else
        rc=$?
    fi
    rm -f $_tmp_1
    trap - EXIT
    return $rc
}

do_network () {
    $apt_install --download-only ifupdown isc-dhcp-client
    _hostname="$(hostname)"

    systemctl disable systemd-resolved.service
    systemctl stop systemd-resolved
    ip addr show

    if if_installed netplan.io ; then
        env DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge --quiet \
 netplan.io\
 networkd-dispatcher\

        rm -rf /etc/network/interfaces
    else
        $apt_remove cloud-init
    fi
    $apt_install ifupdown
    _suffix=''
    _configs=$(find /etc/network/interfaces.d/ -name \*.cfg)
    if [ -n "$_configs" ]; then
        _suffix=".cfg"
        rm -f $_configs
    fi
    cat >/etc/network/interfaces.d/eth0$_suffix << _EOF_
auto $iface
iface $iface inet dhcp
_EOF_
    echo "127.0.0.1 $_hostname" >>/etc/hosts

    ifup $iface
    ip addr show

    $apt_remove bind9-host

}

do_autoupdate () {
    $apt_remove \
 cron \
 popularity-contest \
 ubuntu-advantage-tools \
 ubuntu-release-upgrader-core \
 unattended-upgrades \
 update-manager-core \

}

do_apt_remove() {
    _pkgs=$(apt list --installed "$1" 2>/dev/null | awk -F'/' 'NR>1{print $1}')
    if [ -n "$_pkgs" ]; then
        $apt_remove $_pkgs
    fi
}

do_misc() {
    $apt_remove \
 accountsservice \
 btrfs-progs \
 command-not-found \
 curl \
 irqbalance \
 libx11-6 \
 lxcfs \
 open-iscsi \
 policykit-1 \
 python3 \
 sound-theme-freedesktop \
 ssh-import-id \
 vim \
 ;
    if [ -f /usr/bin/editor ]; then
        update-alternatives --install /usr/bin/editor editor /usr/bin/vim.tiny 99
    fi
    do_apt_remove 'cryptsetup*'
    do_apt_remove 'linux-headers-*'
    do_apt_remove 'tcl*'
    do_apt_remove lxd-client
}

do_server () {
    $apt_remove ubuntu-server
}

do_snapd() {
    if which snap; then
        _tmp=$(mktemp -t)
        trap 'rc=$?;rm -f $_tmp;exit $rc' EXIT
        snap list >$_tmp
        if [ -s $_tmp ]; then
            cat $_tmp
            while read name ver rest; do
                case $name in
                Name) ;;
                snapd) ;;
                bare) ;;
                core*) ;;
                *)
                    snap remove --purge $name
                    ;;
                esac
            done <$_tmp
            snap list >$_tmp
            while read name ver rest; do
                case $name in
                Name) ;;
                snapd) ;;
                *)
                    snap remove --purge $name
                    ;;
                esac
            done <$_tmp
            snap list >$_tmp
            while read name ver rest; do
                case $name in
                Name) ;;
                *)
                    snap remove --purge $name
                    ;;
                esac
            done <$_tmp
        fi
        rm -rf /var/cache/snapd/
        do_apt_remove gnome-software-plugin-snap
        $apt_remove snapd
        apt-mark hold snapd
        rm -f $_tmp
        trap - EXIT
    fi
}

do_modules() {
    rm -f /etc/modprobe.d/blacklist-kvm.conf
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
    ; do
        echo "blacklist $d" >>/etc/modprobe.d/blacklist-kvm.conf
    done
    if which update-initramfs >/dev/null; then
        update-initramfs -u
    fi
}

do_azure () {
    _images=$(apt list --installed linux-image-\*|cut -d/ -f1)
    _modules=$(apt list --installed linux-modules-\*|cut -d/ -f1)
    _headers=$(apt list --installed linux-headers\*|cut -d/ -f1)

    $apt_install linux-azure

    $apt_remove $_images $_modules

    _headers=$(apt list --installed linux-headers\*|cut -d/ -f1)
    env DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge --quiet $_headers

    if [ -f /etc/network/interfaces.d/eth0 ]; then
        sed -i "s/$iface/eth0/" /etc/network/interfaces.d/eth0
    else
        sed -i "s/$iface/eth0/" /etc/network/interfaces.d/eth0.cfg
    fi
}

if [ $# -eq 0 ]; then
    apt-get update
    do_autoupdate
    do_snapd
    do_server
    do_modules
    do_network
    do_misc
else 
    while test $# -gt 0; do
        cmd="$1";shift;
        if [ -z ${_update:-} ]; then
            apt-get update
            _update=1
        fi
        case "$cmd" in
        autoupdate) do_autoupdate;;
        azure) do_azure;;
        misc) do_misc;;
        modules) do_modules;;
        network) do_network;;
        server) do_server;;
        snapd) do_snapd;;
        *)
            echo "Unknown command '$cmd'" 2>&1
            exit 1
        esac
    done
fi
apt-get clean
rm -rf /var/lib/apt/lists/*
df -h
