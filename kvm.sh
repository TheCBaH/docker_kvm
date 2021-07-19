#!/bin/bash
set -eu
set -o pipefail
set -x

cmd="init"
os_ver="ubuntu-20.04"
data_mnt="/opt/data"
data_size="16G"
swap_size="256M"
dryrun=''
id='data/img/id_kvm'
wait=''
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
mkdir -p $img_dir $var_dir
boot=$img_dir/${os_ver}-boot.img
data=$img_dir/${os_ver}-data.img
swap=$img_dir/${os_ver}-swap.img

do_id() {
    if [ ! -f $id ]; then
        ssh-keygen -f $id -P ''
    fi
}

do_cloud() {
    echo 'instance-id: kvm-docker' >/tmp/metadata.yml
    echo 'local-hostname: kvm-docker' >>/tmp/metadata.yml

    cat >/tmp/user.yml <<_EOF_
#cloud-config' >/tmp/user.yml
ssh_authorized_keys:
  - $(cat $id.pub)
power_state:
  mode: poweroff
  timeout: 60
  condition: True
runcmd:
  - |
    set -eux
    mkdir -p $data_mnt;echo LABEL=KVM-DATA $data_mnt auto defaults 0 2 >>/etc/fstab
    mkdir -p $data_mnt;echo data_mount /mnt 9p trans=virtio 0 2 >>/etc/fstab
_EOF_
    if [ -n "$swap_size" ]; then
        cat >>/tmp/user.yml <<_EOF_
    echo LABEL=KVM-SWAP swap swap defaults 0 0 >>/etc/fstab
_EOF_
    fi
    user=$(id -un)
    group=$(id -gn)
    gid=$(id -g)
    cat >>/tmp/user.yml <<_EOF_
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
    echo "$(cat $id.pub)" >/home/$user/.ssh/authorized_keys
    chmod 0600 /home/$user/.ssh/authorized_keys
_EOF_
    cat >>/tmp/user.yml <<_EOF_
    echo DONE
_EOF_

   cloud-localds $img_dir/user.img /tmp/user.yml /tmp/metadata.yml
}

do_qemu() {
    mode=$1;shift
    qemu_options="
    -m 2G \
    -smp 2 \
    -nographic \
    -no-reboot \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::$port-:22 \
    -drive if=virtio,format=qcow2,file=$boot \
    -drive if=virtio,format=qcow2,file=$data \
    -virtfs local,id=data_dev,path=data,security_model=none,mount_tag=data_mount \
    "
    if [ -r /dev/kvm ]; then
        qemu_options="${qemu_options} -accel kvm"
    fi
    if [ -n "$dryrun" ]; then
        qemu_options="${qemu_options} -snapshot"
    fi
    if [ $cmd = "init" -o "$os_ver"="ubuntu-16.04" ]; then
        qemu_options="${qemu_options} -drive if=virtio,format=raw,file=$img_dir/user.img"
    fi

    if [ -n "$swap_size" ]; then
        qemu_options="${qemu_options} -drive if=virtio,format=qcow2,file=$swap"
    fi

    if [ $mode = background ]; then
        qemu-system-x86_64 ${qemu_options:-} $@ </dev/null >$log &
        qemu_job=$!
    else
        qemu-system-x86_64 ${qemu_options:-} $@
    fi
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
     -monitor unix:/tmp/qemu.mon,server,nowait \

    sleep 1
    pid=$(cat $pidf)
    kill -0 $pid
    fail=1
    for n in $(seq 120); do
        tail -1 $log
        if grep -q 'login:' $log; then
            fail=''
            break
        fi
        sleep 1
    done
    if [ -n "$fail" ]; then
        kill ${pid:-} || true
        exit $fail
    fi
    cat >$ssh_flag  <<_EOF_
-oBatchmode=yes -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -i$(readlink -f $id) -p $port localhost
_EOF_
}


cmd_stop_ssh() {
    rm -f $ssh_flag
    pid=$(cat $pidf)
    fail=1
    for n in $(seq 60); do
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
        wait $pid
        exit $fail
    fi
    wait $pid
}

cmd_ssh() {
    cmd_start_ssh

    SSH_OPTIONS="$(cat $var_dir/ssh_options)"
    ssh_fail=1
    if ssh ${SSH_OPTIONS} $@ ; then
        ssh_fail=0
    fi

    cmd_stop_ssh
    exit ${ssh_fail}
}

do_wait() {
    disown $qemu_job
    sleep infinity
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
    start_ssh)
        rm -f $ssh_flag $ssh_flag.done
        if [ -n "$wait" ]; then
            trap "touch $ssh_flag.done; echo 'Stopping Linux.... '; cmd_stop_ssh; exit 0" EXIT
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
    *)
        echo "Not supported command '$cmd'" 2>&1
        exit 1
esac
