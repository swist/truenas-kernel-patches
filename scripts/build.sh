#!/usr/bin/env bash
# Build a "Wi-Fi bundle" for one TrueNAS release:
#   * the TrueNAS kernel at that release's TS-* tag, with config/wifi.config
#     merged on top and patches/linux/* applied
#   * OpenZFS + SCST kernel modules rebuilt against that kernel (enabling
#     CFG80211 changes struct net_device; 25.10 has MODVERSIONS on and would
#     reject the stock modules, 26.x has it off and would load them unchecked)
#   * iwlwifi firmware for AX211 / BE200 / BE201 only, wireless-regdb, iw, wpa_supplicant
#
# Both TrueNAS kernel flavours are built: "production" (the default) and
# "debug" (System > Advanced Settings > Kernel > Enable Debug Kernel), each
# with its own ZFS/SCST modules, mirroring scale-build's kernel/kernel-dbg,
# openzfs/openzfs-dbg and scst/scst-dbg recipes.
#
# Usage (as root, inside a Debian container matching the release, see
# config/releases.conf):
#   scripts/build.sh all     TS-25.10.8 /out        # everything, sequentially
#   FLAVOR=debug \
#   scripts/build.sh kernel  TS-25.10.8 /debs       # one flavour: kernel+ZFS+SCST
#   scripts/build.sh extras  /debs                  # firmware + userspace
#   scripts/build.sh bundle  TS-25.10.8 /debs /out  # manifest + tar
#   FLAVOR=debug \
#   scripts/build.sh configure /path/to/truenas-linux-tree   # config check only
#
# Output: /out/truenas-wifi-<TS tag>-r<N>.tar  (+ .sha256)
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${WORK:-/var/tmp/tnwifi-build}
JOBS=${JOBS:-$(nproc)}
BUNDLE_REV=${BUNDLE_REV:-1}
FLAVOR=${FLAVOR:-production}
case $FLAVOR in production|debug) ;; *) echo "FLAVOR must be production or debug" >&2; exit 2 ;; esac
LINUX_FIRMWARE_REPO=${LINUX_FIRMWARE_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git}
TN_GH=${TN_GH:-https://github.com/truenas}

log() { printf '\n=== %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Kernel
# --------------------------------------------------------------------------

# Apply patches/linux/common/*.patch and patches/linux/<major.minor>/*.patch.
apply_patches() {
    local src=$1 kv
    kv=$(make -s -C "$src" kernelversion | cut -d. -f1,2)
    local p
    for p in "$REPO_DIR"/patches/linux/common/*.patch "$REPO_DIR"/patches/linux/"$kv"/*.patch; do
        [ -e "$p" ] || continue
        log "applying $(basename "$p")"
        if ! (cd "$src" && git apply --check "$p" 2>/dev/null); then
            # Try a fuzzy apply before giving up; CI turns a failure into an issue.
            (cd "$src" && patch -p1 --forward --fuzz=3 --no-backup-if-mismatch < "$p") \
                || die "patch $(basename "$p") does not apply to $kv - needs a manual rebase"
        else
            (cd "$src" && git apply "$p")
        fi
    done
}

# Reproduce TrueNAS's config sequence (from scale-build conf/build.manifest),
# then merge our fragment last.
configure_kernel() {
    local src=$1
    local tn="$src/scripts/package/truenas"
    [ -f "$tn/truenas.config" ] || die "$src is not a truenas/linux tree"
    (
        cd "$src"
        make -s defconfig
        ./scripts/kconfig/merge_config.sh -m .config "$tn/debian_amd64.config"
        ./scripts/kconfig/merge_config.sh -m .config "$tn/truenas.config"
        ./scripts/kconfig/merge_config.sh -m .config "$tn/tn-$FLAVOR.config"
        ./scripts/kconfig/merge_config.sh -m .config "$REPO_DIR/config/wifi.config"
        make -s olddefconfig
    ) >&2
    verify_config "$src"
}

verify_config() {
    local src=$1 cfg="$1/.config" bad=0 opt
    for opt in CONFIG_WIRELESS=y CONFIG_WLAN=y CONFIG_CFG80211=m CONFIG_MAC80211=m CONFIG_IWLWIFI=m; do
        grep -qx "$opt" "$cfg" || { echo "missing $opt" >&2; bad=1; }
    done
    # AX211 always uses iwlmvm; BE200/BE201 use iwlmld on kernels that have it.
    if grep -q '^config IWLMLD' "$src/drivers/net/wireless/intel/iwlwifi/Kconfig"; then
        grep -qx CONFIG_IWLMLD=m "$cfg" || { echo "missing CONFIG_IWLMLD=m" >&2; bad=1; }
    else
        grep -qx CONFIG_IWLMVM=m "$cfg" || { echo "missing CONFIG_IWLMVM=m" >&2; bad=1; }
    fi
    local card
    for card in "AX211" "BE200" "BE201"; do
        grep -rqE "Wi-Fi [67]E? $card " "$src/drivers/net/wireless/intel/iwlwifi/cfg/" \
            || { echo "iwlwifi in this tree does not know the $card - add a backport under patches/linux/" >&2; bad=1; }
    done
    [ $bad = 0 ] || die "kernel config verification failed"
    log "kernel config OK: $(grep -E '^CONFIG_(CFG80211|MAC80211|IWLWIFI|IWLMVM|IWLMLD)=' "$cfg" | tr '\n' ' ')"
}

build_kernel() {
    local src=$1 out=$2
    (
        cd "$src"
        # TrueNAS's mkdebian only sets srctree itself when KDEB_PKGVERSION is
        # unset, and we leave that unset (see the version stamp below).
        export EXTRAVERSION=-$FLAVOR PYTHON=python3 srctree=.
        rm -rf .git .gitattributes .gitignore   # as scale-build does: keeps KERNELRELEASE clean
        make syncconfig
        make archprepare
        # Same package names / kernel release as stock, but the Debian version
        # gets "+wifiN" so ours is distinguishable and sorts above TrueNAS's.
        # TrueNAS's mkdebian sets the version with `dch --newversion <release>-1`
        # ($version on 25.10, ${KERNELRELEASE} on 26+) and bindeb-pkg re-runs
        # mkdebian (which wipes debian/), so the only place a suffix survives
        # is that dch line itself.
        local vre='--newversion (\$version|\$\{KERNELRELEASE\})-1 '
        grep -qE -- "$vre" scripts/package/mkdebian \
            || die "TrueNAS mkdebian changed: cannot find 'dch --newversion <release>-1' to version-stamp"
        sed -i -E "s/$vre/--newversion \\1-1+wifi${BUNDLE_REV} /" scripts/package/mkdebian
        ./scripts/package/mkdebian
        echo "kernel package version: $(head -1 debian/changelog)"
        rm -f .config.old
        make -j"$JOBS" bindeb-pkg
    ) >&2
    # bindeb-pkg drops the .debs next to the source tree; skip the multi-GB
    # symbol package (*-dbg_*). Both flavours produce an identical
    # linux-perf-truenas; keep only the production one.
    find "$(dirname "$src")" -maxdepth 1 -name '*.deb' ! -name '*-dbg_*' -exec mv -t "$out" {} +
    [ "$FLAVOR" = production ] || rm -f "$out"/linux-perf-truenas_*.deb
}

kernel_release_of() {  # kernel release string from the image .deb
    # Read the whole listing (no `| head`): with pipefail, closing the pipe
    # early kills dpkg-deb with SIGPIPE and fails the build.
    dpkg-deb -c "$1" | awk 'k == "" && match($0, /lib\/modules\/[^\/]+\//) {
        k = substr($0, RSTART + 12, RLENGTH - 13) } END { print k }'
}

# --------------------------------------------------------------------------
# Out-of-tree modules (mirrors scale-build's openzfs / scst recipes)
# --------------------------------------------------------------------------

build_zfs() {
    local tag=$1 kver=$2 out=$3 d="$WORK/$FLAVOR/zfs"
    rm -rf "$d"; git clone -q --depth 1 -b "$tag" "$TN_GH/zfs" "$d"
    (
        cd "$d"
        cp -r contrib/debian debian
        mk-build-deps -i -r -t 'apt-get -y --no-install-recommends' debian/control
        local ksrc; ksrc=$(readlink -f "/lib/modules/$kver/build")
        [ -d "$ksrc" ] || die "kernel headers for $kver not installed"
        export KVERS="$kver" KSRC="$ksrc" KOBJ="$ksrc"
        sh autogen.sh
        ./configure --with-linux="$ksrc" --with-linux-obj="$ksrc"
        cp contrib/debian/changelog debian/changelog
        local cfgopts=--enable-debuginfo
        if [ "$FLAVOR" = debug ]; then
            cfgopts="--enable-debug --enable-debuginfo"
            sed -i 's/Provides: openzfs-zfs-modules/Provides: openzfs-zfs-modules-dbg/' debian/control.modules.in
        fi
        sed "s/@CFGOPTS@/$cfgopts/g" debian/rules.in > debian/rules
        chmod +x debian/rules
        ./scripts/make_gitrev.sh
        debian/rules override_dh_binary-modules
    ) >&2
    find "$WORK/$FLAVOR" -maxdepth 2 -name "openzfs-zfs-modules-${kver}_*.deb" -exec mv -t "$out" {} +
    ls "$out"/openzfs-zfs-modules-"$kver"_*.deb >/dev/null 2>&1 || die "ZFS module package was not produced"
}

build_scst() {
    local tag=$1 kver=$2 out=$3 d="$WORK/$FLAVOR/scst"
    rm -rf "$d"; git clone -q --depth 1 -b "$tag" "$TN_GH/scst" "$d"
    (
        cd "$d"
        export KVER="$kver" KDIR="/lib/modules/$kver/build"
        local mode=2perf
        if [ "$FLAVOR" = debug ]; then
            # scale-build's scst-dbg: debug modules only, packaged as scst-dbg
            # (the Makefile switches to scst-dbg.install when KVER is a debug kernel).
            mode=2debug; export PKG_BUILD_MODE=2debug
            cat debian/control.dbgmodules > debian/control
        fi
        sed -i 's/^DEBIAN_REVISION=.*/DEBIAN_REVISION=~truenas+1/g' Makefile
        # SCST's Build-Depends name all four TrueNAS kernel packages (production
        # + debug, image + headers) purely for scale-build's ordering; only the
        # production headers at $KDIR are actually used. Drop them so debuild's
        # build-dependency check doesn't fail.
        sed -i -E '/^ linux-(headers|image)-truenas-[a-z]+-amd64,?$/d' debian/control
        awk '/^Build-Depends/,/^[A-Z][a-z-]+:/' debian/control | grep -q 'linux-.*-truenas' \
            && die "SCST Build-Depends still names TrueNAS kernel packages"
        make debian/changelog
        make "$mode"
        make scst-dist-gzip
        make dpkg DEBEMAIL=no-reply@localhost DEBFULLNAME=truenas-kernel-patches
    ) >&2
    find "$d" "$WORK/$FLAVOR" -maxdepth 3 -name '*.deb' -path '*scst*' ! -name '*dbgsym*' -exec mv -t "$out" {} + || true
    if [ "$FLAVOR" = debug ]; then
        ls "$out"/scst-dbg_*.deb >/dev/null 2>&1 || die "scst-dbg package was not produced"
    else
        ls "$out"/scst_*.deb >/dev/null 2>&1 || die "SCST packages were not produced"
    fi
}

# --------------------------------------------------------------------------
# Firmware + userspace
# --------------------------------------------------------------------------

build_firmware_deb() {
    local out=$1 d="$WORK/linux-firmware" stage="$WORK/fw-stage" pkg="$WORK/fw-pkg"
    rm -rf "$d" "$stage" "$pkg"
    git clone -q --depth 1 "$LINUX_FIRMWARE_REPO" "$d"
    local fwver; fwver=$(cd "$d" && git log -1 --format=%cd --date=format:%Y%m%d)
    mkdir -p "$stage"
    (cd "$d" && ./copy-firmware.sh "$stage") >/dev/null
    # iwlwifi firmware is named <MAC>-<RF>. Keep files and symlinks, wherever linux-firmware puts them.
    #   AX211 (CNVi):    RF gf-a0, MAC so (ADL/RPL), ma (MTL), bz (ARL/LNL), sc (PTL)
    #   BE200 (M.2):     gl-c0-fm-c0
    #   BE201 (CNVi):    RF fm-c0, MAC bz (MTL/ARL/LNL), sc (PTL)
    # Deliberately excluded: ty-a0-gf-a0 (AX210) and every other Intel card.
    mkdir -p "$pkg/DEBIAN" "$pkg/usr/lib/firmware"
    (cd "$stage" && find . \( -name 'iwlwifi-so-a0-gf-a0*' -o -name 'iwlwifi-ma-b0-gf-a0*' \
                              -o -name 'iwlwifi-bz-b0-gf-a0*' -o -name 'iwlwifi-sc-a0-gf-a0*' \
                              -o -name 'iwlwifi-gl-c0-fm-c0*' -o -name 'iwlwifi-bz-b0-fm-c0*' \
                              -o -name 'iwlwifi-sc-a0-fm-c0*' \) -print0 \
        | xargs -0 -r cp -a --parents -t "$pkg/usr/lib/firmware")
    [ -n "$(find "$pkg/usr/lib/firmware" -name '*.ucode' -print -quit)" ] || die "no AX211/BE200/BE201 firmware found in linux-firmware"
    cat > "$pkg/DEBIAN/control" <<EOF
Package: truenas-wifi-firmware-iwlwifi
Version: ${fwver}
Architecture: all
Maintainer: truenas-kernel-patches <noreply@localhost>
Description: Intel AX211/BE200/BE201 iwlwifi firmware from linux-firmware ${fwver}
EOF
    dpkg-deb --root-owner-group -b "$pkg" "$out/truenas-wifi-firmware-iwlwifi_${fwver}_all.deb" >&2
}

download_userspace() {
    local out=$1 d="$WORK/apt"
    rm -rf "$d"; mkdir -p "$d"; chmod 777 "$d"
    apt-get update -qq
    # Only what TrueNAS doesn't ship. The NAS-side installer skips any library
    # that is already installed, so TrueNAS's own libs are never replaced.
    (cd "$d" && apt-get download -qq wpasupplicant iw wireless-regdb \
        libnl-3-200 libnl-genl-3-200 libnl-route-3-200 libpcsclite1)
    mv "$d"/*.deb "$out"/
}

# --------------------------------------------------------------------------

write_manifest() {
    local tag=$1 out=$2 f
    local -A kv=()
    for f in production debug; do
        local -a imgs=("$out"/linux-image-truenas-"$f"-amd64_*.deb)
        [ -f "${imgs[0]}" ] && kv[$f]=$(kernel_release_of "${imgs[0]}")
    done
    [ -n "${kv[production]:-}" ] || die "no production kernel package in $out"
    python3 - "$tag" "${kv[production]}" "${kv[debug]:-}" "$BUNDLE_REV" "$out" <<'PY'
import hashlib, json, os, subprocess, sys
tag, kprod, kdebug, rev, out = sys.argv[1:]
kernels = {"production": kprod}
if kdebug:
    kernels["debug"] = kdebug
debs = []
for f in sorted(os.listdir(out)):
    if not f.endswith(".deb"):
        continue
    p = os.path.join(out, f)
    fields = subprocess.run(["dpkg-deb", "-f", p, "Package", "Version"], capture_output=True, text=True, check=True).stdout
    meta = dict(l.split(": ", 1) for l in fields.strip().splitlines())
    debs.append({"file": f, "package": meta["Package"], "version": meta["Version"],
                 "sha256": hashlib.sha256(open(p, "rb").read()).hexdigest()})
json.dump({"format": 2, "truenas_tag": tag, "truenas_version": tag.removeprefix("TS-"),
           "kernel_release": kprod, "kernel_releases": kernels,
           "bundle_rev": int(rev), "debs": debs},
          open(os.path.join(out, "manifest.json"), "w"), indent=2)
PY
}

# One kernel flavour: kernel + its ZFS and SCST modules, into $out.
cmd_kernel() {
    local tag=$1 out=$2
    [ "$(id -u)" = 0 ] || die "run as root (inside the build container)"
    local w="$WORK/$FLAVOR"
    mkdir -p "$w" "$out"

    # REUSE_KERNEL=1 keeps this flavour's kernel .debs from a previous run in
    # $out and redoes only the module builds (CI restores them from cache).
    if [ "${REUSE_KERNEL:-0}" = 1 ] && ls "$out"/linux-image-truenas-"$FLAVOR"-amd64_*.deb >/dev/null 2>&1; then
        log "[$FLAVOR] reusing kernel packages from a previous run"
        find "$out" -maxdepth 1 -type f ! -name 'linux-*' -delete
    else
        rm -rf "$out"; mkdir -p "$out"
        log "[$FLAVOR] kernel $tag"
        rm -rf "$w/linux"; mkdir -p "$w/linux"
        git clone -q --depth 1 -b "$tag" "$TN_GH/linux" "$w/linux/src"
        apply_patches "$w/linux/src"
        configure_kernel "$w/linux/src"
        build_kernel "$w/linux/src" "$out"
        rm -rf "$w/linux"   # reclaim disk before the module builds
    fi

    local -a imgs=("$out"/linux-image-truenas-"$FLAVOR"-amd64_*.deb)
    [ -f "${imgs[0]}" ] || die "kernel image package not found in $out"
    local kver; kver=$(kernel_release_of "${imgs[0]}")
    log "[$FLAVOR] kernel release $kver"
    dpkg -i "$out"/linux-headers-truenas-"$FLAVOR"-amd64_*.deb >&2

    log "[$FLAVOR] openzfs $tag"; build_zfs "$tag" "$kver" "$out"
    if [ "${SKIP_SCST:-0}" = 1 ]; then
        log "[$FLAVOR] scst skipped (SKIP_SCST=1): do not enable the iSCSI service on this kernel"
    else
        log "[$FLAVOR] scst $tag"; build_scst "$tag" "$kver" "$out"
    fi
}

cmd_extras() {
    local out=$1
    mkdir -p "$WORK" "$out"
    log "firmware";  build_firmware_deb "$out"
    log "userspace"; download_userspace "$out"
}

cmd_bundle() {
    local tag=$1 out=$2 dest=$3
    mkdir -p "$dest"
    rm -f "$out/manifest.json"
    write_manifest "$tag" "$out"
    local name="truenas-wifi-${tag}-r${BUNDLE_REV}"
    tar -C "$out" -cf "$dest/$name.tar" .
    (cd "$dest" && sha256sum "$name.tar" > "$name.tar.sha256")
    log "done: $dest/$name.tar"
    cat "$out/manifest.json"
}

cmd_all() {
    local tag=$1 dest=$2 f
    local out="$WORK/bundle"
    mkdir -p "$out"
    for f in ${FLAVORS:-production debug}; do
        FLAVOR=$f cmd_kernel "$tag" "$WORK/$f-debs"
        cp "$WORK/$f-debs"/*.deb "$out"/
    done
    cmd_extras "$out"
    cmd_bundle "$tag" "$out" "$dest"
}

case ${1:-} in
    all)        shift; cmd_all "$@" ;;
    kernel)     shift; cmd_kernel "$@" ;;
    extras)     shift; cmd_extras "$@" ;;
    bundle)     shift; cmd_bundle "$@" ;;
    configure)  shift; src=$(cd "$1" && pwd); apply_patches "$src"; configure_kernel "$src" ;;
    *) echo "usage: $0 all <TS-tag> <outdir> | kernel <TS-tag> <debdir> | extras <debdir> | bundle <TS-tag> <debdir> <outdir> | configure <linux-src>" >&2; exit 2 ;;
esac
