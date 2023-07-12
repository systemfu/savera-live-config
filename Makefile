#!/usr/bin/make -f
# Change the default shell /bin/sh which does not implement 'source'
# source is needed to work in a python virtualenv
SHELL := /bin/bash
LAST_TAG := $(shell git describe --tags --abbrev=0)
LIBVIRT_STORAGE_PATH := /var/lib/libvirt/images/

# remove 'download_extra' to build without third party software/dotfiles
all: install_buildenv download_extra build

.PHONY: download_extra # download third-party components
download_extra:
	make -f Makefile.extra

.PHONY: install_buildenv # install packages required to build the image
install_buildenv:
	sudo apt -y install live-build make build-essential wget git unzip colordiff apt-transport-https rename ovmf rsync python3-venv gnupg

##############################

.PHONY: clean # clear all caches, only required when changing the mirrors/architecture config
clean:
	sudo lb clean --all
	make -f Makefile.extra clean

build:
	# Build the live system/ISO image
	sudo lb clean --all
	sudo lb config
	sudo lb build

##############################

.PHONY: bump_version # bump all version indicators before a new release
bump_version:
	@echo "Please set version to $(LAST_TAG) in doc/md/conf.py config/bootloaders/grub-pc/live-theme/theme.txt config/bootloaders/isolinux/live.cfg.in config/bootloaders/isolinux/menu.cfg auto/config doc/md/download-and-installation.md doc/md/index.md"

.PHONY: release # generate release files
release: checksums sign_checksums release_archive

.PHONY: checksums # generate checksums of the resulting ISO image
checksums:
	@mkdir -p iso/
	mv *.iso iso/
	cd iso/; \
	rename "s/live-image/dlc-$(LAST_TAG)-debian-bookworm/" *; \
	sha512sum *.iso  > SHA512SUMS; \

# the signing key must be present and loaded on the build machine
# gpg --export-secret-keys --armor $MAINTAINER_EMAIL > $MAINTAINER_EMAIL.key
# rsync -avzP $MAINTAINER_EMAIL.key $BUILD_HOST:
# ssh -t $BUILD_HOST gpg --import $MAINTAINER_EMAIL.key
.PHONY: sign_checksums # sign checksums with a GPG private key
sign_checksums:
	cd iso; \
	gpg --detach-sign --armor SHA512SUMS; \
	mv SHA512SUMS.asc SHA512SUMS.sign
	# Export the public GPG key used for signing
	gpg --export --armor nodiscc@gmail.com > iso/dlc-release.key

.PHONY: release_archive # generate a source code archive
release_archive:
	git archive --format=zip -9 HEAD -o $$(basename $$PWD)-$$(git rev-parse HEAD).zip

################################

.PHONY: tests # run all tests
tests: test_imagesize test_kvm_bios test_kvm_uefi

.PHONY: test_imagesize # ensure the image size is less than 2GB
test_imagesize:
	@size=$$(du -b iso/*.iso | cut -f 1); \
	echo "[INFO] ISO image size: $$size bytes"; \
	if [[ "$$size" -gt 2147483648 ]]; then \
		echo '[WARNING] ISO image size is larger than 2GB!'; exit 1; \
	fi

# requirements: iso image must be downloaded from the build machine beforehand
# rsync -avzP $BUILD_HOST:/var/debian-live-config/iso ./
# cp iso/*.iso /var/lib/libvirt/images/
.PHONY: test_kvm_bios # test resulting live image in libvirt VM with legacy BIOS
test_kvm_bios:
	virt-install --name dlc-test --boot cdrom --video virtio --disk path=$(LIBVIRT_STORAGE_PATH)/dlc-test-disk0.qcow2,format=qcow2,size=20,device=disk,bus=virtio,cache=none --cdrom "$(LIBVIRT_STORAGE_PATH)dlc-$(LAST_TAG)-debian-bookworm-amd64.hybrid.iso" --memory 3048 --vcpu 2
	virsh destroy dlc-test
	virsh undefine dlc-test
	rm -f $$PWD/dlc-test-disk0.qcow2

# UEFI support must be enabled in QEMU config for EFI install tests https://wiki.archlinux.org/index.php/Libvirt#UEFI_Support (/usr/share/OVMF/*.fd)
.PHONY: test_kvm_uefi # test resulting live image in libvirt VM with UEFI
test_kvm_uefi:
	virt-install --name dlc-test --boot loader=/usr/share/OVMF/OVMF_CODE.fd --video virtio --disk path=$(LIBVIRT_STORAGE_PATH)/dlc-test-disk0.qcow2,format=qcow2,size=20,device=disk,bus=virtio,cache=none --cdrom "$(LIBVIRT_STORAGE_PATH)dlc-$(LAST_TAG)-debian-bookworm-amd64.hybrid.iso" --memory 3048 --vcpu 2
	virsh destroy dlc-test
	virsh undefine dlc-test
	rm -f $$PWD/dlc-test-disk0.qcow2

##### DOCUMENTATION #####
# requirements: sudo apt install git jq
#               gitea-cli config defined in ~/.config/gitearc:
# GITEA_USER=user
# GITEA_API_TOKEN=token
# GITEA_URL=https://git.example.org
# # Allow self-signed certs
# curl() { command curl --insecure "$@"; }
# gitea.issues() {
# 	split_repo "$1"
# 	auth curl --silent "${GITEA_URL%/}/api/v1/repos/$REPLY/issues"
# }
.PHONY: update_todo # update TODO.md by fetching issues from the main gitea instance API
update_todo:
	git clone https://github.com/bashup/gitea-cli gitea-cli
	echo '<!-- This file is automatically generated by "make update_todo" -->' >| doc/md/TODO.md
	echo -e "\n### nodiscc/debian-live-config\n" >> doc/md/TODO.md; \
	./gitea-cli/bin/gitea issues baron/debian-live-config | jq -r '.[] | "- #\(.number) - \(.title) - **`\(.milestone.title // "-")`** `\(.labels | map(.name) | join(","))`"'  | sed 's/ - `null`//' >> doc/md/TODO.md; \
	rm -rf gitea-cli

.PHONY: doc # run all documentation generation tasks
doc: install_dev_docs doc_package_lists doc_md doc_html

.PHONY: install_dev_docs # install documentation generator (sphinx + markdown + theme)
install_dev_docs:
	python3 -m venv .venv/
	source .venv/bin/activate && pip3 install sphinx recommonmark sphinx_rtd_theme

.PHONY: doc_md # generate markdown documentation
doc_md:
	cp README.md doc/md/index.md
	cp CHANGELOG.md doc/md/
	cp LICENSE doc/md/LICENSE.md
	sed -i 's|doc/md/||g' doc/md/*.md

.PHONY: doc_package_lists # generate markdown package list from config/package-lists/
doc_package_lists:
	./doc/gen_package_lists.py

SPHINXOPTS    ?=
SPHINXBUILD   ?= sphinx-build
SOURCEDIR     = doc/md    # répertoire source (markdown)
BUILDDIR      = doc/html  # répertoire destination (html)
.PHONY: doc_html # manual - HTML documentation generation (sphinx-build --help)
doc_html:
	source .venv/bin/activate && sphinx-build -c doc/md -b html doc/md doc/html

#####

.PHONY: help # generate list of targets with descriptions
help:
	@grep '^.PHONY: .* #' Makefile | sed 's/\.PHONY: \(.*\) # \(.*\)/\1	\2/' | expand -t20
