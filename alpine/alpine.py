#!/usr/bin/env python3
import argparse
import io
import logging
import os
import pexpect
import sys

from typing import Optional

class logger(io.StringIO):
    def write(self, data:bytes) -> int:
        text = data.decode(encoding='utf-8', errors='ignore')
        rc = sys.stderr.write(text)
        sys.stderr.flush()
        return rc


def qemu(
    disk: str,
    gid: str,
    group: str,
    image: str,
    key: str,
    uid: str,
    user: str,
    version: str,
    uefi: Optional[bool] = None,
) -> None:
    qemu = 'qemu-system-x86_64'
    boot_disk = [
        '-hda', disk
    ]
    args = boot_disk + [
        '-no-reboot',
        '-m', '1G',
        '-nographic',
    ]
    if uefi:
        args += ['-bios', '/usr/share/ovmf/OVMF.fd']

    key_data = open(key).read()

    install = ['-cdrom', image]

    if os.access('/dev/kvm', os.W_OK):
        args += ['-accel', 'kvm']
        args += ['-cpu', 'host']

    logging.warning(f'Running: {qemu} {" ".join(args + install)}')
    log = logger()
    p = pexpect.spawn(qemu, args + install, logfile=log, timeout=120)

    def prompt():
        p.expect('# ')

    def command(cmd: str):
        p.sendline(f'(set -eux;{cmd}) && echo -="OK"=-')
        p.expect('-=OK=-')
        prompt()

    def login():
        p.expect('login')
        p.sendline('root')
        prompt()
        http_proxy = 'http_proxy'
        if http_proxy in os.environ:
            p.sendline(f'export http_proxy={os.environ[http_proxy]}')

    def boot(install=True):
        if install:
            p.expect('Mounting')
        p.expect('Welcome to Alpine Linux')

    boot()
    login()

    command('setup-keymap us us')
    command('setup-hostname kvm-docker')
    command('setup-interfaces -a')
    command('rc-service networking start')
    command('rc-update add networking boot')
    command(f'echo "http://dl-cdn.alpinelinux.org/alpine/v{version}/main" >> /etc/apk/repositories')
    command(f'echo "http://dl-cdn.alpinelinux.org/alpine/v{version}/community" >> /etc/apk/repositories')
    command('setup-sshd -c openssh')
    command('setup-ntp -c busybox')
    serial='ttyS0'
    p.sendline(f'yes | env KERNELOPTS="console=tty0 console={serial} nomodeset" setup-disk -s 0 -v -m sys /dev/sda')
    p.expect('Installation is complete. Please reboot.',timeout=120)
    command('reboot')

    p.expect(pexpect.EOF)

    logging.warning(f'Running: {qemu} {" ".join(args)}')
    p = pexpect.spawn(qemu, args, logfile=log, timeout=120)
    boot(install=False)
    login()
    command('rc-update add acpid default')
    command(f'set -x;name=$(getent group {gid} | cut -d: -f1);(addgroup -g {gid} {group} || true) && adduser -u {uid} -G ${{name:-{group}}} -D {user}')
    command('addgroup sudo')
    command(f'addgroup {user} sudo')
    command(f'echo "{user}:{user}" | chpasswd')
    command(f'apk --no-cache add openssh-client su-exec')
    command(f'echo | su-exec {user} ssh-keygen -P ""')
    auth=f'/home/{user}/.ssh/authorized_keys'
    command(f'echo "{key_data}" | su-exec {user} tee -a {auth}')
    command(f'apk --no-cache del openssh-client su-exec')
    command(f'chmod a=,u=rw {auth}')
    command(f'echo "{user} ALL=(ALL) NOPASSWD:ALL" >>/etc/sudoers')
    command(f'apk --no-cache add bash sudo')

    command('reboot')
    p.expect(pexpect.EOF)

    return


def main():
    parser = argparse.ArgumentParser(description='Create Alpine disk image')
    parser.add_argument('--disk', help='Path to installation ISO', required=True)
    parser.add_argument('--gid', help='Group id for the user account', required=True)
    parser.add_argument('--group', help='Group name for the user account', required=True)
    parser.add_argument('--image', help='Path to target disk image', required=True)
    parser.add_argument('--key', help='Path to SSH public key', required=True)
    parser.add_argument('--uid', help='User ID for the user account', required=True)
    parser.add_argument('--user', help='User name for the user account', required=True)
    parser.add_argument('--version', help='Alpine version', required=True)
    parser.add_argument('--uefi', help='Enable UEFI firmware')

    args = parser.parse_args()
    qemu(**vars(args))
    return 0

if __name__ == "__main__":
    sys.exit(main())
