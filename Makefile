ID_OFFSET=$(or $(shell id -u docker 2>/dev/null),0)
UID=$(shell expr $$(id -u) - ${ID_OFFSET})
GID=$(shell expr $$(id -g) - ${ID_OFFSET})
USER=$(shell id -un)
GROUP=$(shell id -gn)
KVM=$(shell gid=$$(stat -c %g /dev/kvm);test -n "$$gid" && test 0 -ne "$$gid" && expr $$gid - ${ID_OFFSET})
WORKSPACE=${CURDIR}
WORKSPACE_ROOT=${CURDIR}
TERMINAL=$(shell test -t 0 && echo t)
DATA_DIR?=$(if $(filter ${WORKSPACE},${CURDIR}),,${WORKSPACE}/)data
DOCKER_NAMESPACE?=${USER}

image=${DOCKER_NAMESPACE}/kvm_image
export DATA_DIR

.SUFFIXES:
MAKEFLAGS += --no-builtin-rules

ubuntu-22.04.name=jammy
ubuntu-20.04.name=focal
ubuntu-18.04.name=bionic
ubuntu-16.04.name=xenial

${DATA_DIR}/base/%-minimal-cloudimg-amd64.img:
	./kvm.sh download $@ 'https://cloud-images.ubuntu.com/minimal/releases/${$(notdir $*).name}/release/$(notdir $@)'

${DATA_DIR}/base/ubuntu-16.04-minimal-cloudimg-amd64.img:
	./kvm.sh download $@ 'https://cloud-images.ubuntu.com/minimal/releases/xenial/release/ubuntu-16.04-minimal-cloudimg-amd64-uefi1.img'

${DATA_DIR}/base/ubuntu-%-server-cloudimg-amd64.img:
	set -eux;ver=${ubuntu-$*.name};./kvm.sh download $@ "https://cloud-images.ubuntu.com/$$ver/current/$$ver-server-cloudimg-amd64.img"

${DATA_DIR}/base/ubuntu-16.04-server-cloudimg-amd64.img:
	./kvm.sh download $@ 'https://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-uefi1.img'

${DATA_DIR}/base/ubuntu-20.04.3-live-server-amd64.iso:
	./kvm.sh download $@ 'https://releases.ubuntu.com/20.04/$(notdir $@)'

ALPINE_VERSION_MINOR_3.9=6
ALPINE_VERSION_MINOR_3.10=9
ALPINE_VERSION_MINOR_3.11=13
ALPINE_VERSION_MINOR_3.12=12
ALPINE_VERSION_MINOR_3.13=7
ALPINE_VERSION_MINOR_3.14=8
ALPINE_VERSION_MINOR_3.15=6
ALPINE_VERSION_MINOR_3.16=3
ALPINE_VERSION_MINOR_3.17=1

ALPINE_VERSION_FULL=${ALPINE_VERSION}.${ALPINE_VERSION_MINOR_${ALPINE_VERSION}}

${DATA_DIR}/base/alpine-virt-${ALPINE_VERSION_FULL}-x86_64.iso:
	./kvm.sh download $@ 'https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/releases/x86_64/$(notdir $@)'

image_name=${DOCKER_NAMESPACE}_$(basename $(1))

kvm_image:
	docker build --tag ${image} ${DOCKER_BUILD_OPTS} -f Dockerfile\
	 --build-arg OS_VER=$(or ${UBUNTU_VERSION},latest)\
	 --build-arg USERINFO=${USER}:${UID}:${GROUP}:${GID}:${KVM}\
	 --build-arg http_proxy\
	 .

%.image: Dockerfile-%
	docker build --tag $(call image_name,$@) ${DOCKER_BUILD_OPTS} -f $^\
	 --build-arg OS_VER=latest\
	 --build-arg USERINFO=${USER}:${UID}:${GROUP}:${GID}:${KVM}\
	 --build-arg http_proxy\
	 .

%.print:
	@echo $($(basename $@))

.PRECIOUS: $(foreach v, 22.04 20.04 18.04 16.04, ${DATA_DIR}/base/ubuntu-${v}-minimal-cloudimg-amd64.img)
.PRECIOUS: $(foreach v, 22.04 20.04 18.04 16.04, ${DATA_DIR}/base/ubuntu-${v}-server-cloudimg-amd64.img)
.PRECIOUS: ${DATA_DIR}/base/ubuntu-20.04.3-live-server-amd64.iso

SSH_PORT=9022
USE_TAP=n
PORTS=5900

NETWORK_OPTIONS.USER=--publish ${SSH_PORT}:${SSH_PORT}
NETWORK_OPTIONS.TAP=--device /dev/net/tun --cap-add NET_ADMIN
KVM_OPTIONS=$(if $(if ${KVM_DISABLE},,$(realpath /dev/kvm)),--device /dev/kvm)

NETWORK_OPTIONS=$(if $(filter y,${USE_TAP}),${NETWORK_OPTIONS.TAP},${NETWORK_OPTIONS.USER}) $(foreach p,${PORTS},--publish=$p:$p)
USERSPEC=--user=${UID}:${GID} $(if ${KVM_DISABLE},,$(addprefix --group-add=, kvm sudo))

${DATA_DIR}:
	mkdir -p $@

DOCKER_ARGS=--rm --hostname $@ -i${TERMINAL} -w ${WORKSPACE} -v $(or ${LOCAL_WORKSPACE_FOLDER},${WORKSPACE_ROOT}):${WORKSPACE_ROOT}:ro\
 -v $(if ${LOCAL_WORKSPACE_FOLDER},${LOCAL_WORKSPACE_FOLDER}/data,$(realpath ${DATA_DIR})):$(realpath ${DATA_DIR}) --env DATA_DIR\
 --env http_proxy\

kvm_run: ${DATA_DIR}
	docker run ${DOCKER_ARGS}\
	 $(if $(wildcard /dev/kvm), --device /dev/kvm)\
	 ${DOCKER_OPTIONS_EXTRA} ${NETWORK_OPTIONS} ${USERSPEC} ${image} ${CMD}

%.image_run: ${DATA_DIR}
	docker run ${DOCKER_ARGS}\
	 ${DOCKER_RUN_OPTS} ${KVM_OPTIONS}\
	 ${DOCKER_OPTIONS_EXTRA} ${NETWORK_OPTIONS} ${USERSPEC} $(call image_name, $@) ${CMD}

ubuntu-autoinstall: ${DATA_DIR}/base/ubuntu-20.04.3-live-server-amd64.iso
	# --user-data ubuntu-autoinstall-generator/user-data.example --all-in-one
	${MAKE} $@.image_run CMD='bash ubuntu-autoinstall-generator/ubuntu-autoinstall-generator.sh --no-verify\
	 --source $^ --destination ${DATA_DIR}/img/$(basename $(notdir $^))-autoinstall.iso'

ubuntu-autoinstall.cfg:
	${MAKE} $(basename $@).image_run CMD='./kvm.sh --debug ${AUTO_INSTALL_OPTS} $(if ${http_proxy},--proxy ${http_proxy}) auto-install-cfg'

%.minimal_img: ${DATA_DIR}/base/%-minimal-cloudimg-amd64.img
	${MAKE} kvm_run CMD='./kvm.sh --base-image $^ --os $(basename $@) ${KVM_SSH_OPTS} init'

%.minimal_run: ${DATA_DIR}/base/%-minimal-cloudimg-amd64.img
	${MAKE} kvm_run CMD='./kvm.sh --base-image $^ --os $(basename $@) ${KVM_SSH_OPTS} run'

%.minimal_init: %.minimal_img
	echo OK

%.server_img: ${DATA_DIR}/base/%-server-cloudimg-amd64.img
	${MAKE} kvm_run CMD='./kvm.sh --base-image $^ --os $(basename $@)-server --no-host-data --data-size 0 --swap-size 0 ${KVM_SSH_OPTS} init'

%.server_run: ${DATA_DIR}/base/%-server-cloudimg-amd64.img
	${MAKE} kvm_run CMD='./kvm.sh --base-image $^ --os $(basename $@)-server ${KVM_SSH_OPTS} run'

%.server_init: %.server_img
	echo OK

%.ssh.test:
	${MAKE} kvm_run USE_TAP=n CMD='./kvm.sh --debug --os $(basename $(basename $@)) --dryrun ${KVM_SSH_OPTS} ssh $(or ${SSH_TEST_CMD}, id)'

%.test.boot:
	${MAKE} kvm_run USE_TAP=n CMD='./kvm.sh --debug --os $(basename $(basename $@)) --dryrun ${KVM_SSH_OPTS} test'

%.ssh.start: ${DATA_DIR}
	rm -f ${DATA_DIR}/ssh_options*
	docker run --init --detach --name ${DOCKER_NAMESPACE}_$(basename $@) -w ${WORKSPACE} -v ${WORKSPACE_ROOT}:${WORKSPACE_ROOT}:ro\
	 -v $(realpath ${DATA_DIR}):$(realpath ${DATA_DIR}) ${DOCKER_RUN_OPTS} --env DATA_DIR\
	 ${KVM_OPTIONS} ${DOCKER_OPTIONS_EXTRA} ${NETWORK_OPTIONS} ${USERSPEC} ${image}\
	 $(realpath kvm.sh) ${KVM_SSH_OPTS} ${SSH_START_OPTS} --os $(basename $(basename $@)) --port ${SSH_PORT} --wait start_ssh

%.ssh.connect:
	docker exec -i${TERMINAL} $(addprefix --env , ${SSH_CONNECT_ENV}) --env DATA_DIR ${DOCKER_NAMESPACE}_$(basename $@) ./kvm_ssh $(or ${SSH_CONNECT_CMD},ssh -t '$$SHELL')

%.ssh.log:
	docker logs ${DOCKER_NAMESPACE}_$(basename $@)

%.ssh.qemu-log:
	docker exec ${DOCKER_NAMESPACE}_$(basename $@) cat /tmp/qemu.log

%.ssh.stop:
	-docker stop -t 60 ${DOCKER_NAMESPACE}_$(basename $@)
	-docker rm ${DOCKER_NAMESPACE}_$(basename $@)

%.ssh:
	-${MAKE} $(basename $@).ssh.stop
	${MAKE} $(basename $@).ssh.start SSH_START_OPTS='$(if ${DRYRUN},--dryrun) --sealed' NETWORK_OPTIONS.USER= PORTS=
	${MAKE} $(basename $@).ssh.connect SSH_CONNECT_CMD="--sealed ssh -t sudo env $(if ${http_proxy},http_proxy=${http_proxy}) /bin/bash"
	${MAKE} $(basename $@).ssh.stop

clean:
	rm -rf ${DATA_DIR}/img ${DATA_DIR}/var

alpine-make-vm-image.image_run: DOCKER_RUN_OPTS=--userns=host --privileged -v=/lib/modules:/lib/modules:ro
alpine-make-vm-image.image_run: NETWORK_OPTIONS=
alpine-make-vm-image.image_run: USERSPEC=
alpine-make-vm-image.image_run: CMD=env USERINFO=${USER}:${UID}:${GROUP}:${GID} TIMEZONE=$$(cat /etc/timezone) ./alpine/build.sh ${ALPINE_VERSION}
alpine-make-vm-image.image: ID_OFFSET=0

%.ubuntu_cleanup:
	-${MAKE} $(basename $@).ssh.stop
	${MAKE} $(basename $@).ssh.start SSH_START_OPTS='$(if ${DRYRUN},--dryrun) --sealed' NETWORK_OPTIONS.USER= PORTS=
	${MAKE} $(basename $@).ssh.connect SSH_CONNECT_CMD="--sealed ssh sudo env $(if ${http_proxy},http_proxy=${http_proxy}) sh -s ${UBUNTU_CLEANUP_TARGET}" <ubuntu/cleanup.sh
	${MAKE} $(basename $@).ssh.stop

%.hyperv_image:
	${MAKE} $(basename $@).ubuntu_cleanup UBUNTU_CLEANUP_TARGET=azure
	${MAKE} kvm_run CMD='./compact-qcow.sh ${DATA_DIR}/img/${basename $@}-boot.img'
	${MAKE} kvm_run CMD='qemu-img convert -p -f qcow2 -O vhdx ${DATA_DIR}/img/${basename $@}-boot.img ${DATA_DIR}/img/${basename $@}-boot.vhdx'
	zip ${DATA_DIR}/img/${basename $@}-boot.zip ${DATA_DIR}/img/${basename $@}-boot.vhdx

${DATA_DIR}/img/alpine-uefi-${ALPINE_VERSION}-boot.img: ${DATA_DIR}/base/alpine-virt-${ALPINE_VERSION_FULL}-x86_64.iso
	${MAKE} kvm_run CMD='qemu-img create -f qcow2 $@ 2G'
	${MAKE} kvm_run CMD='alpine/alpine.py\
	 --image=data/base/alpine-virt-${ALPINE_VERSION_FULL}-x86_64.iso\
	 --disk=$@\
	 --key=${DATA_DIR}/img/id_kvm.pub\
	 --version=${ALPINE_VERSION}\
	 --user=${USER}\
	 --uid=${UID}\
	 --group=${USER}\
	 --gid=${GID}\
	 --uefi=1'

alpine-uefi-${ALPINE_VERSION}.img: ${DATA_DIR}/img/alpine-uefi-${ALPINE_VERSION}-boot.img

alpine-uefi-${ALPINE_VERSION}.vhdx: ${DATA_DIR}/img/alpine-uefi-${ALPINE_VERSION}-boot.img
	${MAKE} $(basename $@).ssh <alpine/hyperv.sh
	${MAKE} kvm_run CMD='./compact-qcow.sh $^'
	${MAKE} kvm_run CMD='qemu-img convert -p -f qcow2 -O vhdx $^ ${DATA_DIR}/img/$@'
	zip $(basename ${DATA_DIR}/img/$@).zip ${DATA_DIR}/img/$@
	ls -alh $(basename ${DATA_DIR}/img/$@).zip

alpine-uefi.img: alpine-uefi-${ALPINE_VERSION}.img
alpine-uefi.vhdx: alpine-uefi-${ALPINE_VERSION}.vhdx

alpine-uefi-%.cleanup:
	${MAKE} $(basename $@).ssh <alpine/cleanup.sh

parse.actions.kvm:
	${MAKE} kvm_run CMD='${MAKE} $(basename $@)'

parse.actions:
	python3 -c 'import yaml;import sys;print(yaml.safe_load(sys.stdin))' <.github/workflows/build.yml

ci-build.ubuntu:
	${MAKE} ubuntu-18.04.minimal_init
	${MAKE} ubuntu-18.04.test.boot
	${MAKE} ubuntu-18.04.ssh.test

ci-build.alpine:
	${MAKE} alpine-uefi.img ALPINE_VERSION=3.9
	${MAKE} alpine-uefi-3.9.test.boot
	${MAKE} alpine-uefi-3.9.ssh.test

ci-build:
	${MAKE} kvm_image
	${MAKE} $@.ubuntu
	${MAKE} $@.alpine
