#!/bin/bash
set -eu
set -o pipefail
#set -x

cmd="init"
os_ver="ubuntu-20.04"
data_mnt="/opt/data"
data_size="16G"
swap_size="256M"
dryrun=''
id='data/img/id_kvm'
wait=''
proxy=''
port=8022
data_dir=data
base_dir=$data_dir/base
img_dir=$data_dir/img
var_dir=$data_dir/var
ssh_flag=$var_dir/ssh_options

while test $# -gt 0; do
    opt="$1";shift;
    case "$opt" in
        --os)
            os_ver=$1;shift
            ;;
        --data-size)
            data_size=$1;shift
            ;;
        --swap-size)
            swap_size=$1;shift
            ;;
        --base-image)
            base_image=$1;shift
            ;;
        --dryrun)
            dryrun=1
            ;;
        --data-mnt)
            data_mnt="/opt/data"
            ;;
        --debug)
            set -x
            ;;
        --wait)
            wait=1
            ;;
        --port)
            port=$1;shift
            ;;
        --proxy)
            proxy=$1;shift
            ;;
        --boot)
            boot=$1;shift
            ;;
        --swap)
            swap=$1;shift
            ;;
        --data)
            data=$1;shift
            ;;
        --*)
            echo "Not supported option '$opt'" 2>&1
            exit 1
            ;;
        *)
            cmd=$opt
            break
            ;;
    esac
done
ssh_port=$port
ssh_host=localhost
mkdir -p $img_dir $var_dir
boot=${boot:-$img_dir/${os_ver}-boot.img}
data=${data:-$img_dir/${os_ver}-data.img}
swap=${swap:-$img_dir/${os_ver}-swap.img}

do_id() {
    if [ ! -f $id ]; then
        ssh-keygen -f $id -P ''
    fi
}

do_cloud() {
    meta=$img_dir/cloud/meta-data
    udata=$img_dir/cloud/user-data
    mkdir -p $(dirname $meta)
    test -f $id.pub
    ID="$(cat $id.pub)"
    cat >$meta <<_YAML_
instance-id: kvm-docker
local-hostname: kvm-docker
_YAML_
    cat >$udata <<_YAML_
#cloud-config
ssh_authorized_keys:
  - '$ID'
power_state:
  mode: poweroff
  timeout: 60
  condition: True
runcmd:
  - |
    set -eux
    mkdir -p $data_mnt;echo LABEL=KVM-DATA $data_mnt auto defaults 0 2 >>/etc/fstab
    mkdir -p $data_mnt;echo data_mount /mnt 9p trans=virtio 0 2 >>/etc/fstab
_YAML_
    if [ -n "$swap_size" ]; then
        cat >>$udata <<_YAML_
    echo LABEL=KVM-SWAP swap swap defaults 0 0 >>/etc/fstab
_YAML_
    fi
    user=$(id -un)
    group=$(id -gn)
    gid=$(id -g)
    cat >>$udata <<_YAML_
    gname=\$(getent group $group 2>/dev/null|cut -f1 -d:)
    if [ -n "\${gname}" ]; then
        groupmod --new-name \${gname}_old \${gname}
    fi
    gname=\$(getent group $gid 2>/dev/null|cut -f1 -d:)
    if [ -n "\${gname}" ]; then
        groupmod --new-name ${group} \${gname}
    else
        groupadd -g $(id -g) $group
    fi
    useradd -m -u $(id -u) -g $gid $user;usermod -aG sudo $user
    echo '$user ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/$user
    chroot --skip-chdir --userspec=$user:$gid / bash -eux -o pipefail <<_USER_
    echo | ssh-keygen -P ''
    echo "$ID" >/home/$user/.ssh/authorized_keys
    chmod 0600 /home/$user/.ssh/authorized_keys
    _USER_
_YAML_
    cat >>$udata <<_YAML_
    chpasswd <<_PASSWD_
    root:secret
    $user:$user
    _PASSWD_
    echo DONE
_YAML_

}

do_tap() {
    br=kvm_br0
    iface=$(ip route show|awk -c '/default/{print $5;exit(0)}')
    iface_ip=$(ip addr show $iface|awk -F'[/ ]+' '/inet/{print $3;exit 0}')
    iface_mask=$(ip route show|awk -F'[/ ]+' "/dev $iface proto/{print \$2;exit 0}")
    case ${iface_mask} in
        24) iface_mask="255.255.255.0";;
        16) iface_mask="255.255.0.0";;
        *) iface_mask="255.255.255.0";;
    esac
    router=$(ip route show|awk -c '/default/{print $3;exit(0)}')
    dns=$(awk -c '/nameserver/{print $2;exit 0}'</etc/resolv.conf)
    ssh_port=22
    ssh_host=$iface_ip
    sudo bash -eu <<_EOF_
        ip addr flush dev $iface
        ip link add $br type bridge
        ip link set dev $iface master $br
        ip link set dev $iface up
        ip link set dev $br up
        setcap cap_net_admin=eip $1
_EOF_
    cat >/tmp/udhcp.conf <<_EOF_
start $iface_ip
end $iface_ip
interface $br
max_leases 1
option subnet $iface_mask
option router $router
option dns $dns
_EOF_
    sudo bash -eu <<_EOF_
        mkdir -p /var/lib/misc/
        touch /var/lib/misc/udhcpd.leases
        udhcpd -I 10.0.0.1 -f /tmp/udhcp.conf &
_EOF_
}

do_qemu() {
    mode=$1;shift
    qemu=$(which qemu-system-x86_64)
    qemu_options="
    -m 2G \
    -smp 2 \
    -nographic \
    -no-reboot \
    -device virtio-net-pci,netdev=net0 \
    -drive if=virtio,format=qcow2,file=$boot \
    -virtfs local,id=data_dev,path=data,security_model=none,mount_tag=data_mount \
    "
    if [ -f "$data" ]; then
        qemu_options="${qemu_options} -drive if=virtio,format=qcow2,file=$data"
    fi
    if [ -w /dev/net/tun ]; then
        do_tap $qemu
        qemu_options="${qemu_options} -netdev tap,id=net0,script=tap/up,downscript=tap/down"
    else
        qemu_options="${qemu_options} -netdev user,id=net0,hostfwd=tcp::$port-:22"
    fi
    if [ -r /dev/kvm ]; then
        qemu_options="${qemu_options} -accel kvm"
    fi
    if [ -n "$dryrun" ]; then
        qemu_options="${qemu_options} -snapshot"
    fi
    if [ $cmd = "init" -o "$os_ver" = "ubuntu-16.04" ]; then
        qemu_options="${qemu_options} -drive if=virtio,read-only=on,driver=vvfat,file=fat:$img_dir/cloud,label=cidata"
    fi

    if [ -f "$swap" ]; then
        qemu_options="${qemu_options} -drive if=virtio,format=qcow2,file=$swap"
    fi

    case "$mode" in
    background)
        ($qemu ${qemu_options:-} $@ </dev/null | exec tee $log) &
        qemu_job=$!
        ;;
    foreground)
        $qemu ${qemu_options:-} $@
        ;;
    test)
        (
            sleep 30
            qemu_pid=$(cat /tmp/qemu.pid)
            for n in $(seq 0 120); do
                if expr $n % 30 >/dev/null ; then
                    true
                else
                    socat - UNIX-CONNECT:/tmp/qemu.mon << CMD || true
system_powerdown
CMD
                fi
                if [ ! -f /tmp/qemu.pid ]; then
                    exit 0
                fi
                sleep 1
            done
            kill $qemu_pid
            sleep 1
            if kill -0 $qemu_pid; then
                kill -KILL $qemu_pid
            fi
        )&
        fail=1
        if $qemu ${qemu_options:-} \
        -serial stdio \
        -pidfile /tmp/qemu.pid \
        -monitor unix:/tmp/qemu.mon,server,nowait \
        $@ ; then
            fail=0
        fi
        wait || true
        if [ $fail -ne 0 ]; then
            exit $fail
        fi
        ;;
    *)
        echo "Not supported qemu mode '$mpde'" 2>&1
        exit 1
        ;;
    esac
}

cmd_init() {
    if [ ! -f $data ]; then
        qemu-img create -f qcow2 $data $data_size
        virt-format -a $data --filesystem=ext4 --label=KVM-DATA
    fi
    if [ -n "$swap_size" -a ! -f $swap ]; then
        qemu-img create -f qcow2 $swap $swap_size
        guestfish -a $swap <<_EOF_
        run
        mkswap-L KVM-SWAP /dev/sda
_EOF_
    fi
    base_image_abs=$(readlink -f $base_image)
    base_image_name=$(basename $base_image)
    cp $base_dir/images $img_dir
    (
        cd $img_dir
        rm -f $base_image_name
        ln -s $(realpath --relative-to=. $base_image_abs) $base_image_name
        qemu-img create -f qcow2 -b $base_image_name $(basename $boot)
    )
    do_id
    do_cloud
    do_qemu foreground
}

log=/tmp/qemu.log
pidf=/tmp/qemu.pid

cmd_start_ssh() {
    rm -f $pidf /tmp/qemu.mon
    do_qemu background \
     -serial stdio \
     -pidfile /tmp/qemu.pid \
     -monitor unix:/tmp/qemu.mon,server,nowait \

    sleep 1
    pid=$(cat $pidf)
    kill -0 $pid
    fail=1
    for n in $(seq 120); do
        sleep 1
        if grep -q 'login:' $log; then
            fail=''
            break
        fi
    done
    if [ -n "$fail" ]; then
        kill ${pid:-} || true
        exit $fail
    fi
    cat >$ssh_flag.tmp  <<_EOF_
-oBatchmode=yes -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -i$(readlink -f $id) -p $ssh_port $ssh_host
_EOF_
    mv $ssh_flag.tmp $ssh_flag
}

cmd_stop_ssh() {
    touch $ssh_flag.done
    rm -f $ssh_flag.started
    rm -f $ssh_flag
    pid=$(cat $pidf)
    fail=1
    for n in $(seq 120); do
        if [ "$(expr $n % 10 )" -eq 1 ]; then
            socat - UNIX-CONNECT:/tmp/qemu.mon << CMD || true
system_powerdown
CMD
        fi
        if kill -0 $pid 2>/dev/null; then
            tail -1 $log
            sleep 1
        else
            fail=''
            break;
        fi
    done
    if [ -n "$fail" ]; then
        kill $pid
        wait
        exit $fail
    fi
    wait
}

cmd_ssh() {
    cmd_start_ssh

    SSH_OPTIONS="$(cat $ssh_flag)"
    ssh_fail=1
    for n in $(seq 30); do
        if timeout 10s ssh ${SSH_OPTIONS} true; then
            ssh_fail=0
            break
        fi
        sleep 5
    done
    if [ $ssh_fail = 0 ]; then
        ssh_fail=1
        if ssh ${SSH_OPTIONS} $@ ; then
            ssh_fail=0
        fi
    fi

    cmd_stop_ssh
    exit ${ssh_fail}
}

do_wait() {
    disown $qemu_job
    sleep infinity
}

do_autoinstall_cfg() {
    # https://ubuntu.com/server/docs/install/autoinstall-schema
    # https://ubuntu.com/server/docs/install/autoinstall-reference
    user=$(id -un)
    test -f $id.pub
    ID="$(cat $id.pub)"
    password=$(echo $user | mkpasswd --stdin --method=sha-256)
    user_install=$var_dir/user-install.yaml
    cat >$user_install <<_YAML_
#cloud-config
autoinstall:
  version: 1
  storage:
    layout:
      name: direct
  ssh:
    install-server: true
    authorized-keys:
      - '$ID'
  identity:
    username: $user
    password: $password
    hostname: kvm-docker-$user
  late-commands:
    - |
      echo '$user ALL=(ALL) NOPASSWD:ALL' >/target/etc/sudoers.d/$user
    - |
      chroot /target/ bash -eux -o pipefail <<_ROOT_
      apt-get clean; rm -rf /var/lib/apt/lists/*
      _ROOT_
  user-data:
    users:
      - username: $user
        groups: sudo
        ssh_authorized-keys:
          - '$ID'
_YAML_
if [ -n "$proxy" ]; then
    echo "  proxy: $proxy" >>$user_install
fi
    cloud-localds $img_dir/user-install.img  $user_install
}

do_auto_install() {
    cd=$img_dir/ubuntu-20.04.2-live-server-amd64-autoinstall.iso
    rootfs="$img_dir/${os_ver}-rootfs.img"
    rm -rf $rootfs
    test -f $rootfs || qemu-img create -f qcow2 $rootfs 100G
    qemu_options="
    -m 2G \
    -cdrom $cd \
    -smp 2 \
    -no-reboot \
    -device virtio-net-pci,netdev=net0 \
    -drive if=virtio,format=qcow2,file=$rootfs \
    -drive if=virtio,format=raw,file=$img_dir/user-install.img \
    "
    qemu_options="${qemu_options} -netdev user,id=net0,hostfwd=tcp::$port-:22"
    if [ -r /dev/kvm ]; then
        qemu_options="${qemu_options} -accel kvm"
    fi
    qemu_options="${qemu_options} --serial mon:stdio"
    qemu_options="${qemu_options} -display vnc=$(hostname -i):0"

    qemu=$(which qemu-system-x86_64)
    exec $qemu ${qemu_options:-} $@
}



case "$cmd" in
    init)
        cmd_init
        ;;
    run)
        do_qemu foreground
        ;;
    ssh)
        cmd_ssh "$@"
        exit 0
        ;;
    test)
        do_qemu test
        ;;
    start_ssh)
        rm -f $ssh_flag $ssh_flag.done $ssh_flag.verified
        touch $ssh_flag.started
        if [ -n "$wait" ]; then
            trap "echo 'Stopping Linux.... '; cmd_stop_ssh; exit 0" EXIT
        fi
        cmd_start_ssh
        if [ -n "$wait" ]; then
            do_wait
        fi
        ;;
    stop_ssh)
        cmd_stop_ssh
        ;;
    download)
        file=$1
        url=$2
        mkdir -p $(dirname $file) $base_dir
        if wget -O "$file.tmp" --progress=dot:giga "$2" ; then
            mv "$file.tmp" "$file"
            cat >>$base_dir/images <<CMD
$(basename $file) $(md5sum "$file"|cut -f1 -d ' ') $url
CMD
        else
            exit 1
        fi
        ;;
    auto-install)
        do_auto_install
        ;;
    auto-install-cfg)
        do_id
        do_autoinstall_cfg
        ;;
    *)
        echo "Not supported command '$cmd'" 2>&1
        exit 1
esac
