#!/usr/bin/env bash
# Entry point inside the debian:<release> build container (see build.yml).
#   ci-container.sh <TS-tag> <outdir>
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# Kernel deps as listed in scale-build's conf/build.manifest, plus module/package tooling.
apt-get install -y -qq --no-install-recommends \
    build-essential git ca-certificates python3 python3-setuptools python3-dev \
    flex bison bc kmod cpio rsync dwarves libssl-dev devscripts equivs debhelper fakeroot zstd \
    libelf-dev libdw-dev systemtap-sdt-dev libunwind-dev libslang2-dev libperl-dev \
    binutils-dev libiberty-dev liblzma-dev libzstd-dev libcap-dev libnuma-dev \
    libbabeltrace-dev libcapstone-dev llvm-dev default-jdk-headless \
    autoconf automake libtool gawk uuid-dev libblkid-dev libudev-dev libaio-dev \
    libattr1-dev libtirpc-dev zlib1g-dev quilt dh-python lsb-release >/dev/null
git config --global --add safe.directory '*'
exec "$(dirname "$0")/build.sh" all "$@"
