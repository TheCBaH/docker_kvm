ID_OFFSET=$(or $(shell id -u docker 2>/dev/null),0)
UID=$(shell expr $$(id -u) - ${ID_OFFSET})
GID=$(shell expr $$(id -g) - ${ID_OFFSET})
USER=$(shell id -un)
GROUP=$(shell id -gn)
KVM=$(shell gid=$$(getent group kvm 2>/dev/null|cut -f 3 -d:);test -n $$gid && expr $$gid - ${ID_OFFSET})
WORKSPACE=${CURDIR}
TERMINAL=$(shell test -t 0 && echo t)

image=${USER}_kvm_image

.SUFFIXES:
MAKEFLAGS += --no-builtin-rules

ubuntu-20.04.name=focal
ubuntu-18.04.name=bionic
ubuntu-16.04.name=xenial

data/base/%-minimal-cloudimg-amd64.img:
	./kvm.sh download $@ 'https://cloud-images.ubuntu.com/minimal/releases/${$(notdir $*).name}/release/$(notdir $@)'

data/base/ubuntu-16.04-minimal-cloudimg-amd64.img:
	./kvm.sh download $@ 'https://cloud-images.ubuntu.com/minimal/releases/xenial/release/ubuntu-16.04-minimal-cloudimg-amd64-uefi1.img'

data/base/ubuntu-20.04.2-live-server-amd64.iso:
	./kvm.sh download $@ 'https://releases.ubuntu.com/20.04/$(notdir $@)'

image_name=${USER}_$(basename $(1))

kvm_image:
	docker build --tag ${image} ${DOCKER_BUILD_OPTS} -f Dockerfile\
	 --build-arg OS_VER=latest\
	 --build-arg USERINFO=${USER}:${UID}:${GROUP}:${GID}:${KVM}\
	 .

%.image: Dockerfile-%
	docker build --tag $(call image_name,$@) ${DOCKER_BUILD_OPTS} -f $^\
	 --build-arg OS_VER=latest\
	 --build-arg USERINFO=${USER}:${UID}:${GROUP}:${GID}:${KVM}\
	 .

%.print:
	@echo $($(basename $@))

.PRECIOUS: data/base/ubuntu-20.04-minimal-cloudimg-amd64.img
.PRECIOUS: data/base/ubuntu-18.04-minimal-cloudimg-amd64.img
.PRECIOUS: data/base/ubuntu-16.04-minimal-cloudimg-amd64.img
.PRECIOUS: data/base/ubuntu-20.04.2-live-server-amd64.iso

SSH_PORT=9022
USE_TAP=n
PORTS=5900

NETWORK_OPTIONS.USER=--publish ${SSH_PORT}:${SSH_PORT}
NETWORK_OPTIONS.TAP=--device /dev/net/tun --cap-add NET_ADMIN

NETWORK_OPTIONS=$(if $(filter y,${USE_TAP}),${NETWORK_OPTIONS.TAP},${NETWORK_OPTIONS.USER}) $(foreach p,${PORTS},--publish=$p:$p)
USERSPEC=--user=${UID}:${GID} $(if ${NO_KVM},,$(addprefix --group-add=, kvm sudo))

kvm_run:
	docker run --rm --hostname $@ -i${TERMINAL} -w ${WORKSPACE} -v ${WORKSPACE}:${WORKSPACE}\
	 $(if $(wildcard /dev/kvm), --device /dev/kvm)\
	 ${NETWORK_OPTIONS} ${USERSPEC} ${image} ${CMD}

%.image_run:
	docker run --rm --hostname $@ -i${TERMINAL} -w ${WORKSPACE} -v ${WORKSPACE}:${WORKSPACE}\
	 ${DOCKER_RUN_OPTS}\
	 $(if ${http_proxy},-e http_proxy=${http_proxy})\
	 $(if $(wildcard /dev/kvm), --device /dev/kvm)\
	 ${USERSPEC} ${NETWORK_OPTIONS} $(call image_name, $@) ${CMD}

ubuntu-autoinstall: data/base/ubuntu-20.04.2-live-server-amd64.iso
	# --user-data ubuntu-autoinstall-generator/user-data.example --all-in-one
	${MAKE} $@.image_run CMD='bash ubuntu-autoinstall-generator/ubuntu-autoinstall-generator.sh --no-verify\
	 --source $^ --destination data/img/$(basename $(notdir $^))-autoinstall.iso'

ubuntu-autoinstall.cfg:
	${MAKE} $(basename $@).image_run CMD='./kvm.sh --debug ${AUTO_INSTALL_OPTS} $(if ${http_proxy},--proxy ${http_proxy}) auto-install-cfg'

%.img: data/base/%-minimal-cloudimg-amd64.img
	${MAKE} kvm_run CMD='./kvm.sh --base-image $^ --os $(basename $@) init'

%.run: data/base/%-minimal-cloudimg-amd64.img
	${MAKE} kvm_run CMD='./kvm.sh --base-image $^ --os $(basename $@) run'

%.init: %.img
	echo OK

%.ssh.test:
	${MAKE} kvm_run USE_TAP=n CMD='./kvm.sh --debug --os $(basename $(basename $@)) --dryrun ssh id'

%.test.boot:
	${MAKE} kvm_run USE_TAP=n CMD='./kvm.sh --debug --os $(basename $(basename $@)) --dryrun test'

%.ssh.start:
	rm -f data/ssh_options*
	docker run --rm --init --detach --name ${USER}_$(basename $@) --rm -w ${WORKSPACE} -v ${WORKSPACE}:${WORKSPACE}\
	 $(if $(wildcard /dev/kvm), --device /dev/kvm)\
	 ${NETWORK_OPTIONS} ${USERSPEC} ${image}\
	 ./kvm.sh ${SSH_START_OPTS} --os $(basename $(basename $@)) --port ${SSH_PORT} --wait start_ssh

%.ssh.log:
	docker logs ${USER}_$(basename $@)

%.ssh.qemu-log:
	docker exec ${USER}_$(basename $@) cat /tmp/qemu.log

%.ssh.stop:
	docker stop -t 60 ${USER}_$(basename $@)

clean:
	rm -rf data/img data/var
