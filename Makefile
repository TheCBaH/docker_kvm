ID_OFFSET=$(or $(shell id -u docker 2>/dev/null),0)
UID=$(shell expr $$(id -u) - ${ID_OFFSET})
GID=$(shell expr $$(id -g) - ${ID_OFFSET})
USER=$(shell id -un)
GROUP=$(shell id -gn)
KVM=$(shell gid=$$(getent group kvm 2>/dev/null|cut -f 3 -d:);test -n $$gid && expr $$gid - ${ID_OFFSET})
WORKSPACE=${CURDIR}
WORKSPACE_ROOT=${CURDIR}
TERMINAL=$(shell test -t 0 && echo t)
DATA_DIR?=$(if $(filter ${WORKSPACE},${CURDIR}),,${WORKSPACE}/)data
DOCKER_NAMESPACE?=${USER}

image=${DOCKER_NAMESPACE}/kvm_image
export DATA_DIR

.SUFFIXES:
MAKEFLAGS += --no-builtin-rules

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

image_name=${DOCKER_NAMESPACE}_$(basename $(1))

kvm_image:
	docker build --tag ${image} ${DOCKER_BUILD_OPTS} -f Dockerfile\
	 --build-arg OS_VER=latest\
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

.PRECIOUS: $(foreach v, 20.04 18.04 16.04, ${DATA_DIR}/base/ubuntu-${v}-minimal-cloudimg-amd64.img)
.PRECIOUS: $(foreach v, 20.04 18.04 16.04, ${DATA_DIR}/base/ubuntu-${v}-server-cloudimg-amd64.img)
.PRECIOUS: ${DATA_DIR}/base/ubuntu-20.04.3-live-server-amd64.iso

SSH_PORT=9022
USE_TAP=n
PORTS=5900

NETWORK_OPTIONS.USER=--publish ${SSH_PORT}:${SSH_PORT}
NETWORK_OPTIONS.TAP=--device /dev/net/tun --cap-add NET_ADMIN

NETWORK_OPTIONS=$(if $(filter y,${USE_TAP}),${NETWORK_OPTIONS.TAP},${NETWORK_OPTIONS.USER}) $(foreach p,${PORTS},--publish=$p:$p)
USERSPEC=--user=${UID}:${GID} $(if ${NO_KVM},,$(addprefix --group-add=, kvm sudo))

${DATA_DIR}:
	mkdir -p $@

kvm_run: ${DATA_DIR}
	docker run --rm --hostname $@ -i${TERMINAL} -w ${WORKSPACE} -v ${WORKSPACE_ROOT}:${WORKSPACE_ROOT}:ro\
	 -v $(realpath ${DATA_DIR}):$(realpath ${DATA_DIR}) --env DATA_DIR\
	 $(if $(wildcard /dev/kvm), --device /dev/kvm)\
	 ${DOCKER_OPTIONS_EXTRA} ${NETWORK_OPTIONS} ${USERSPEC} ${image} ${CMD}

%.image_run: ${DATA_DIR}
	docker run --rm --hostname $@ -i${TERMINAL} -w ${WORKSPACE} -v ${WORKSPACE_ROOT}:${WORKSPACE_ROOT}:ro\
	 -v $(realpath ${DATA_DIR}):$(realpath ${DATA_DIR}) --env DATA_DIR\
	 ${DOCKER_RUN_OPTS}\
	 $(if ${http_proxy},-e http_proxy=${http_proxy})\
	 $(if $(wildcard /dev/kvm), --device /dev/kvm)\
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
	${MAKE} kvm_run CMD='./kvm.sh --base-image $^ --os $(basename $@) run'

%.minimal_init: %.minimal_img
	echo OK

%.server_img: ${DATA_DIR}/base/%-server-cloudimg-amd64.img
	${MAKE} kvm_run CMD='./kvm.sh --base-image $^ --os $(basename $@)-server --no-host-data --data-size 0 --swap-size 0 ${KVM_SSH_OPTS} init'

%.server_run: ${DATA_DIR}/base/%-server-cloudimg-amd64.img
	${MAKE} kvm_run CMD='./kvm.sh --base-image $^ --os $(basename $@)-server run'

%.server_init: %.server_img
	echo OK

%.ssh.test:
	${MAKE} kvm_run USE_TAP=n CMD='./kvm.sh --debug --os $(basename $(basename $@)) --dryrun ssh id'

%.test.boot:
	${MAKE} kvm_run USE_TAP=n CMD='./kvm.sh --debug --os $(basename $(basename $@)) --dryrun test'

%.ssh.start: ${DATA_DIR}
	rm -f ${DATA_DIR}/ssh_options*
	docker run --init --detach --name ${DOCKER_NAMESPACE}_$(basename $@) -w ${WORKSPACE} -v ${WORKSPACE_ROOT}:${WORKSPACE_ROOT}:ro\
	 -v $(realpath ${DATA_DIR}):$(realpath ${DATA_DIR}) ${DOCKER_RUN_OPTS} --env DATA_DIR\
	 $(if $(wildcard /dev/kvm), --device /dev/kvm)\
	 ${DOCKER_OPTIONS_EXTRA} ${NETWORK_OPTIONS} ${USERSPEC} ${image}\
	 $(realpath kvm.sh) ${SSH_START_OPTS} --os $(basename $(basename $@)) --port ${SSH_PORT} --wait start_ssh

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
	${MAKE} $(basename $@).ssh.connect SSH_CONNECT_CMD="--sealed ssh -t sudo env $(if ${http_proxy},http_proxy=${http_proxy}) $${SHELL}"
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
