# Migrating a TrueNAS system to the Wi-Fi kernel by hand

This is what `nas/truenas-wifi` and `scripts/build.sh` automate, written out
so you can do it, or debug it, manually.

## Should I build on the live NAS?

**No.** Build anywhere else and only *install* on the NAS:

- The TrueNAS root filesystem is read-only, `apt`/`dpkg` are disabled
  (their exec bits are stripped), and anything you install with developer mode
  is wiped by the next update.
- The build needs about 30 GB of scratch space, a full toolchain and 2–3
  hours of CPU time on 4 cores.
- Building inside the running boot environment means changing the system
  you're running on, with no clean rollback.

Good build hosts: the GitHub Actions workflow in this repo, any Debian
machine with Docker, or a **Debian VM on the NAS itself** (Virtualization →
add a VM with ≥ 8 vCPU / 16 GB / 80 GB zvol). The VM is the closest you get
to "building on the NAS" without touching the host OS. It can also be the
self-hosted Actions runner.

## 1. Build a bundle

The Debian release must match the TrueNAS base: 25.10 = `bookworm`,
26.x = `trixie`.

```sh
git clone https://github.com/swist/truenas-kernel-patches && cd truenas-kernel-patches
docker run --rm -v "$PWD:/src:ro" -v /var/tmp/tnwifi:/work -e WORK=/work/build \
    debian:bookworm /src/scripts/ci-container.sh TS-25.10.8 /work/out
ls /var/tmp/tnwifi/out/   # truenas-wifi-TS-25.10.8-r1.tar (+ .sha256)
```

What `build.sh all` does:

1. `git clone -b TS-25.10.8 https://github.com/truenas/linux` (the exact
   kernel that release shipped).
2. Applies `patches/linux/common/*` and `patches/linux/<maj.min>/*`.
3. Recreates TrueNAS's config: `make defconfig`, then merges
   `debian_amd64.config` → `truenas.config` → `tn-production.config` (the
   same sequence as scale-build's manifest), then **`config/wifi.config`**,
   then `make olddefconfig`. It fails if `CFG80211`/`MAC80211`/`IWLWIFI`/
   `IWLMVM|IWLMLD` aren't `=m` or the BE200 PCI ID is missing.
4. Prepends a changelog entry `<stock>+wifiN`, then runs
   `EXTRAVERSION=-production make bindeb-pkg`. The kernel release string
   (`6.12.x-production+truenas`) and package names stay identical to stock,
   so the packages replace TrueNAS's kernel in place and GRUB entries don't
   change.
5. Installs the new headers and builds OpenZFS (`truenas/zfs@TS-…`, recipe
   from scale-build) and SCST (`truenas/scst@TS-…`) against them.
6. Packages BE200 firmware (`iwlwifi-gl-*`, `*fm-c0*`) from linux-firmware and
   downloads `wireless-regdb`, `iw`, `wpasupplicant` and their libnl
   dependencies from Debian.
7. Writes `manifest.json` (tag, kernel release, per-deb sha256) and tars it
   all up.

## 2. Install into a boot environment (never the running one)

Run as root on the NAS. Replace `25.10.8` with your version and copy the
`.tar` over first.

```sh
# 0. Secure Boot must be off
od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null   # 1 = on

# 1. Clone the running BE
midclt call boot.environment.clone '{"id": "25.10.8", "target": "25.10.8-wifi"}'
DS=boot-pool/ROOT/25.10.8-wifi
zfs snapshot -r $DS@before-wifi

# 2. Mount it with its child datasets (layout from conf/truenas_root_ds.json)
M=$(mktemp -d)
mount -t zfs -o zfsutil $DS $M
python3 -c 'import json,sys
for e in json.load(open(sys.argv[1])):
    f=e["fhs_entry"]; print(f["name"], f.get("mountpoint") or "/"+f["name"])' \
    $M/conf/truenas_root_ds.json | sort -k2 | while read n mp; do
        mount -t zfs -o zfsutil $DS/$n $M$mp; done
zfs get -H -o name,value -s local readonly -r $DS > /tmp/ro-before   # remember exact settings
for d in $(zfs list -H -o name -r $DS); do zfs set readonly=off $d; done
mount -o remount,rw $M; mount -o remount,rw $M/usr
mount --rbind /dev $M/dev; mount -t proc proc $M/proc; mount -t sysfs sysfs $M/sys

# 3. Unlock dpkg, keep kernel hooks / services from firing
chmod 755 $M/usr/bin/dpkg
printf '#!/bin/sh\nexit 101\n' > $M/usr/sbin/policy-rc.d; chmod 755 $M/usr/sbin/policy-rc.d
mv $M/etc/kernel/postinst.d $M/etc/kernel/postinst.d.off

# 4. Install. Skip libnl*/libpcsclite1 if TrueNAS already has them, and
#    linux-headers/libc-dev/perf/scst only if they are installed.
mkdir -p $M/var/tmp/w && tar -C $M/var/tmp/w -xf truenas-wifi-TS-25.10.8-r1.tar
chroot $M /usr/bin/dpkg -i --force-confold \
    /var/tmp/w/linux-image-truenas-production-*.deb \
    /var/tmp/w/openzfs-zfs-modules-*.deb \
    /var/tmp/w/truenas-wifi-firmware-*.deb \
    /var/tmp/w/wireless-regdb_*.deb /var/tmp/w/iw_*.deb /var/tmp/w/wpasupplicant_*.deb \
    /var/tmp/w/libnl-*.deb /var/tmp/w/libpcsclite1_*.deb
KV=$(python3 -c 'import json;print(json.load(open("'$M'/var/tmp/w/manifest.json"))["kernel_release"])')
chroot $M depmod -a $KV
chroot $M update-initramfs -u -k $KV

# 5. Restore and unmount
rm -rf $M/var/tmp/w $M/usr/sbin/policy-rc.d
mv $M/etc/kernel/postinst.d.off $M/etc/kernel/postinst.d
chmod 644 $M/usr/bin/dpkg
umount -R $M/dev $M/proc $M/sys
umount -R $M
while read d v; do zfs set readonly=$v $d; done < /tmp/ro-before

# 6. Boot it
midclt call boot.environment.activate '{"id": "25.10.8-wifi"}'
reboot
```

## 3. Bring Wi-Fi up

```sh
modprobe iwlwifi
dmesg | grep -i iwlwifi          # expect "Detected Intel(R) Wi-Fi 7 BE200 320MHz" + firmware load
iw dev                           # e.g. wlp3s0
iw reg set US
wpa_supplicant -B -D nl80211 -i wlp3s0 -c /mnt/tank/truenas-wifi/wpa_supplicant.conf
dhcpcd -b wlp3s0 || dhclient -nw wlp3s0
```

Make it persistent with *System → Advanced → Init/Shutdown Scripts* (POSTINIT,
command `/mnt/tank/truenas-wifi/truenas-wifi up`), which is what
`truenas-wifi setup` registers.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `iwlwifi: no suitable firmware found` | Firmware too old for the kernel's API range. Rebuild the bundle (it pulls the latest linux-firmware). |
| `Direct firmware load for regulatory.db failed` | `wireless-regdb` not installed in that BE. |
| `zfs: disagrees about version of symbol` / pool won't import | ZFS module not from the same bundle. Boot the previous BE and re-run the install. |
| BE doesn't boot / black screen | Secure Boot is on, or the initramfs wasn't regenerated. Pick the previous BE in GRUB. |
| No `phy80211` interface | `rfkill list`; check that the BIOS hasn't disabled the M.2 Wi-Fi slot. |
