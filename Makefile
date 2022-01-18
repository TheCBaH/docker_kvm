ID_OFFSET=$(or $(shell id -u docker 2>/dev/null),0)
UID=$(shell expr $$(id -u) - ${ID_OFFSET})
GID=$(shell expr $$(id -g) - ${ID_OFFSET})
USER=$(shell id -un)
GROUP=$(shell id -gn)
KVM=$(shell gid=$$(getent group kvm 2>/dev/null|cut -f 3 -d:);test -n $$gid && expr $$gid - ${ID_OFFSET})
WORKSPACE=${CURDIR}
WORKSPACE_ROOT=${CURDIR}
TERMINAL=$(shell test -t 0 && echo t)
DATA_DIR?=${WORKSPACE}/data
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

.PRECIOUS: ${DATA_DIR}/base/ubuntu-20.04-minimal-cloudimg-amd64.img
.PRECIOUS: ${DATA_DIR}/base/ubuntu-18.04-minimal-cloudimg-amd64.img
.PRECIOUS: ${DATA_DIR}/base/ubuntu-16.04-minimal-cloudimg-amd64.img
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
	 -v ${DATA_DIR}:${DATA_DIR} --env DATA_DIR\
	 $(if $(wildcard /dev/kvm), --device /dev/kvm)\
	 ${NETWORK_OPTIONS} ${USERSPEC} ${image} ${CMD}

%.image_run: ${DATA_DIR}
	docker run --rm --hostname $@ -i${TERMINAL} -w ${WORKSPACE} -v ${WORKSPACE_ROOT}:${WORKSPACE_ROOT}:ro\
	 -v ${DATA_DIR}:${DATA_DIR} --env DATA_DIR\
	 ${DOCKER_RUN_OPTS}\
	 $(if ${http_proxy},-e http_proxy=${http_proxy})\
	 $(if $(wildcard /dev/kvm), --device /dev/kvm)\
	 ${USERSPEC} ${NETWORK_OPTIONS} $(call image_name, $@) ${CMD}

ubuntu-autoinstall: ${DATA_DIR}/base/ubuntu-20.04.3-live-server-amd64.iso
	# --user-data ubuntu-autoinstall-generator/user-data.example --all-in-one
	${MAKE} $@.image_run CMD='bash ubuntu-autoinstall-generator/ubuntu-autoinstall-generator.sh --no-verify\
	 --source $^ --destination ${DATA_DIR}/img/$(basename $(notdir $^))-autoinstall.iso'

ubuntu-autoinstall.cfg:
	${MAKE} $(basename $@).image_run CMD='./kvm.sh --debug ${AUTO_INSTALL_OPTS} $(if ${http_proxy},--proxy ${http_proxy}) auto-install-cfg'

%.img: ${DATA_DIR}/base/%-minimal-cloudimg-amd64.img
	${MAKE} kvm_run CMD='./kvm.sh --base-image $^ --os $(basename $@) init'

%.run: ${DATA_DIR}/base/%-minimal-cloudimg-amd64.img
	${MAKE} kvm_run CMD='./kvm.sh --base-image $^ --os $(basename $@) run'

%.init: %.img
	echo OK

%.ssh.test:
	${MAKE} kvm_run USE_TAP=n CMD='./kvm.sh --debug --os $(basename $(basename $@)) --dryrun ssh id'

%.test.boot:
	${MAKE} kvm_run USE_TAP=n CMD='./kvm.sh --debug --os $(basename $(basename $@)) --dryrun test'

%.ssh.start: ${DATA_DIR}
	rm -f ${DATA_DIR}/ssh_options*
	docker run --init --detach --name ${DOCKER_NAMESPACE}_$(basename $@) -w ${WORKSPACE} -v ${WORKSPACE_ROOT}:${WORKSPACE_ROOT}:ro\
	 -v ${DATA_DIR}:${DATA_DIR} --env DATA_DIR\
	 $(if $(wildcard /dev/kvm), --device /dev/kvm)\
	 ${NETWORK_OPTIONS} ${USERSPEC} ${image}\
	 $(realpath kvm.sh) ${SSH_START_OPTS} --os $(basename $(basename $@)) --port ${SSH_PORT} --wait start_ssh

%.ssh.connect:
	docker exec -i${TERMINAL} $(addprefix --env , ${SSH_CONNECT_ENV}) --env DATA_DIR ${DOCKER_NAMESPACE}_$(basename $@) ./kvm_ssh ${SSH_CONNECT_CMD}

%.ssh.log:
	docker logs ${DOCKER_NAMESPACE}_$(basename $@)

%.ssh.qemu-log:
	docker exec ${DOCKER_NAMESPACE}_$(basename $@) cat /tmp/qemu.log

%.ssh.stop:
	docker stop -t 60 ${DOCKER_NAMESPACE}_$(basename $@)
	docker rm ${DOCKER_NAMESPACE}_$(basename $@)

clean:
	rm -rf ${DATA_DIR}/img ${DATA_DIR}/var

alpine-make-vm-image.image_run: DOCKER_RUN_OPTS=--userns=host --privileged -v=/lib/modules:/lib/modules:ro
alpine-make-vm-image.image_run: NETWORK_OPTIONS=
alpine-make-vm-image.image_run: USERSPEC=
alpine-make-vm-image.image_run: CMD=env USERINFO=${USER}:${UID}:${GROUP}:${GID} TIMEZONE=$$(cat /etc/timezone) ./alpine/build.sh ${ALPINE_VERSION}
alpine-make-vm-image.image: ID_OFFSET=0
