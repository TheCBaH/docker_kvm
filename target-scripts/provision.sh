#!/bin/bash
set -x
set -eu
set -o pipefail

with_root() {
    "$@"
}

do_apt_get() {
    cmd=$1;shift
    case "$cmd" in
    clean)
        with_root env DEBIAN_FRONTEND=noninteractive apt-get clean -y
        ;;
    install)
        with_root env DEBIAN_FRONTEND=noninteractive apt-get $cmd -y --no-install-recommends "$@" </dev/null
        ;;
    update)
        with_root apt-get $cmd </dev/null
        ;;
    esac
}

cmd_clean() {
    do_apt_get clean
}

cmd_repositories() {
    do_apt_get update
    do_apt_get install software-properties-common
    with_root add-apt-repository universe
    with_root add-apt-repository multiverse
    do_apt_get update
}

cmd_docker() {
    do_apt_get install docker.io
}

cmd_dist_upgrade () {
    do_apt_get update
    do_apt_get upgrade
}

while test $# -gt 0; do
    cmd=$1;shift
    cmd_$cmd
done
