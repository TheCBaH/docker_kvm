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

kvm_image:
	docker build --tag ${image} ${DOCKER_BUILD_OPTIONS} -f Dockerfile\
	 --build-arg http_proxy\
	 --build-arg UBUNTU_VER=latest\
	 --build-arg USERINFO=${USER}:${UID}:${GROUP}:${GID}:${KVM}\
	 .

%.print:
	@echo $($(basename $@))

.PRECIOUS: data/base/ubuntu-20.04-minimal-cloudimg-amd64.img
.PRECIOUS: data/base/ubuntu-18.04-minimal-cloudimg-amd64.img
.PRECIOUS: data/base/ubuntu-16.04-minimal-cloudimg-amd64.img

SSH_PORT=9022
USE_TAP=y

NETWORK_OPTIONS.USER=--publish ${SSH_PORT}:${SSH_PORT}
NETWORK_OPTIONS.TAP=--device /dev/net/tun --cap-add NET_ADMIN

NETWORK_OPTIONS=$(if $(filter y,${USE_TAP}),${NETWORK_OPTIONS.TAP},${NETWORK_OPTIONS.USER})

USERSPEC=--user=${UID}:${GID} $(addprefix --group-add=, kvm sudo)

kvm_run:
	docker run --rm --hostname $@ -i${TERMINAL} -w ${WORKSPACE} -v ${WORKSPACE}:${WORKSPACE}\
	 $(if $(wildcard /dev/kvm), --device /dev/kvm)\
	 ${NETWORK_OPTIONS} ${USERSPEC} ${image} ${CMD}

%.img: data/base/%-minimal-cloudimg-amd64.img
	${MAKE} kvm_run CMD='./kvm.sh --base-image $^ --os $(basename $@) init'

%.run: data/base/%-minimal-cloudimg-amd64.img
	${MAKE} kvm_run CMD='./kvm.sh --base-image $^ --os $(basename $@) run'

%.init: %.img
	echo OK

%.ssh.test:
	${MAKE} kvm_run USE_TAP=n CMD='./kvm.sh --debug --os $(basename $(basename $@)) --dryrun ssh id'

%.ssh.start:
	rm -f data/ssh_options*
	docker run --rm --init --detach --name ${USER}_$(basename $@) --rm -w ${WORKSPACE} -v ${WORKSPACE}:${WORKSPACE}\
	 $(if $(wildcard /dev/kvm), --device /dev/kvm)\
	 ${NETWORK_OPTIONS} ${USERSPEC} ${image}\
	 ./kvm.sh ${SSH_START_OPTIONS} --os $(basename $(basename $@)) --port ${SSH_PORT} --wait start_ssh

%.ssh.log:
	docker logs ${USER}_$(basename $@)

%.ssh.qemu-log:
	docker exec ${USER}_$(basename $@) cat /tmp/qemu.log

%.ssh.stop:
	docker stop -t 60 ${USER}_$(basename $@)

clean:
	rm -rf data/img data/var
