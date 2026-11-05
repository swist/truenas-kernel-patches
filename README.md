# truenas-kernel-patches

Intel **AX211**, **BE200** and **BE201** Wi-Fi support for TrueNAS (nothing else). A pipeline
rebuilds the TrueNAS kernel with Wi-Fi enabled for each new TrueNAS release,
and an on-NAS tool installs that kernel into the boot environment you will
boot next.

## What's actually wrong on stock TrueNAS

The driver for all three cards is **already in every TrueNAS kernel** (checked
the 6.12 and 6.18 lines). TrueNAS turns it off on
purpose in `scripts/package/truenas/truenas.config`:

```
# Disable WiFi and Wireless
CONFIG_WLAN=n
CONFIG_WIRELESS=n
```

and the image ships no iwlwifi firmware, no regulatory database and no
`wpa_supplicant`/`iw`. So the "backport" is mostly configuration:

| Piece | Where |
|---|---|
| Re-enable cfg80211 / mac80211 / iwlwifi (MVM + MLD op-modes) | `config/wifi.config` |
| Driver backports, if a future one is ever needed | `patches/linux/` (empty today) |
| Firmware for exactly these cards (AX211 `*-gf-a0`, BE200 `gl-c0-fm-c0`, BE201 `*-fm-c0`), 61 of ~400 iwlwifi files | packaged by `scripts/build.sh` |
| `wireless-regdb`, `iw`, `wpasupplicant` | Debian packages, bundled |

Merged in TrueNAS's own order, the fragment changes **only** these
`=m` options compared with stock: `CFG80211 MAC80211 IWLWIFI IWLMVM`
(+`IWLMLD` on 6.18). That was checked against `stable/goldeye` (6.12) and
`stable/26` (6.18). The 6.18 Wi-Fi stack also compiles cleanly under
TrueNAS's `CONFIG_WERROR=y`.

### Why the whole kernel (and ZFS) has to be rebuilt

- `struct net_device` only has its `ieee80211_ptr` member when
  `CONFIG_CFG80211` is enabled, so you can't load Wi-Fi as out-of-tree
  modules on the stock kernel.
- Enabling Wi-Fi changes `struct net_device`, so modules built for the stock
  kernel (OpenZFS, SCST) no longer match. On 25.10 (`CONFIG_MODVERSIONS=y`)
  the new kernel would refuse the stock ZFS module and your pools wouldn't
  import. On 26.x (`CONFIG_MODVERSIONS` off) it would load them unchecked.
  Either way they are rebuilt from the same release tag.

### Why not rebuild the whole TrueNAS image?

TrueNAS 25.10 and earlier could be rebuilt with `truenas/scale-build`. In
March 2026 that repo was frozen and the build system moved to internal
infrastructure. So for 26.x there is no public way to produce an `.update`
image. This project swaps the kernel inside a **cloned boot environment**
instead, so stock TrueNAS stays one boot-menu entry away.

## How it fits together

```
 GitHub Actions (this repo)                      TrueNAS box
 ───────────────────────────                     ──────────────────────────────
 watch.yml  every 6h                             cron: truenas-wifi sync (15 min)
   new TS-* tag in truenas/{linux,zfs,scst}?       next-boot BE lacks Wi-Fi kernel?
        │                                                │
        ▼                                                ▼
 build.yml  in debian:<bookworm|trixie>          download bundle for that version
   truenas/linux@TS-x  + config/wifi.config      verify sha256
   + patches/linux/*   → kernel .debs            snapshot BE; clone it if it's running
   truenas/zfs@TS-x    → zfs modules             chroot dpkg -i, update-initramfs
   truenas/scst@TS-x   → scst modules            mark BE, activate
   linux-firmware, regdb, iw, wpa_supplicant            │
        │                                                ▼
        ▼                                         POSTINIT: truenas-wifi up
 GitHub Release  wifi-TS-x-rN                      (iwlwifi, wpa_supplicant, DHCP)
   truenas-wifi-TS-x-rN.tar (+ .sha256)
```

- **A new TrueNAS release** creates new `TS-*` tags. The watcher builds a
  bundle for each one.
- **You change a patch or the config** (push to `main`). The newest release
  of each tracked line is rebuilt as `rN+1`, and the NAS picks it up on the
  next sync.
- **A patch stops applying** or the build breaks. The workflow opens an issue
  with the log tail.

Releases tracked and their Debian base: `config/releases.conf` (25.10 →
bookworm, 26+ → trixie; betas/RCs are opt-in).

## Setup

### 1. GitHub

1. Push this repo to GitHub (already `swist/truenas-kernel-patches`).
2. Actions → *watch upstream* → *Run workflow* (or wait for the 6-hourly cron).
   The first run builds `TS-25.10.8`.
3. Optional: a full kernel build takes about 3 h on a hosted runner (limit 6 h).
   For faster or more reliable builds, register a self-hosted runner
   (x86-64 Linux with Docker, ≥ 8 cores, ≥ 16 GB RAM, ≥ 60 GB disk) and set the
   repo variable `BUILD_RUNNER` to `["self-hosted","linux","x64"]`.

### 2. The NAS (once)

Prerequisites: **Secure Boot off** (the kernel isn't signed by iXsystems).
You also need a wired connection for the first install, and any pool to keep
the tool on.

```sh
mkdir -p /mnt/tank/truenas-wifi && cd /mnt/tank/truenas-wifi
for f in truenas-wifi truenas-wifi.env.example wpa_supplicant.conf.example; do
  curl -fsSLO https://raw.githubusercontent.com/swist/truenas-kernel-patches/main/nas/$f
done
chmod +x truenas-wifi
cp truenas-wifi.env.example truenas-wifi.env            # set WIFI_COUNTRY etc.
cp wpa_supplicant.conf.example wpa_supplicant.conf && chmod 600 wpa_supplicant.conf  # SSID/passphrase

./truenas-wifi sync     # clones running BE -> "<ver>-wifi", installs bundle, activates it
./truenas-wifi setup    # adds Init/Shutdown script (POSTINIT "up") + cron job ("sync")
reboot
```

After the reboot, `./truenas-wifi status` should show the running BE with a
`wifi-bundle` value and `iwlwifi loaded: yes`.

### 3. Updating TrueNAS from then on

1. Wait until the Release for the new version exists here (usually a few
   hours after the TrueNAS tag appears).
2. Apply the TrueNAS update with **"reboot after update" unticked**.
3. `truenas-wifi sync` patches the newly installed BE within 15 minutes (or
   run it by hand). `status` will show the bundle on the next-boot BE.
4. Reboot.

If you reboot into an unpatched update anyway, it boots stock TrueNAS without
Wi-Fi. The cron job then clones and patches it, and one more reboot fixes it.
If Wi-Fi is your *only* link, that needs console access, so follow the order
above. If no bundle exists yet, `sync` exits with code 3 and logs a warning.

### Rolling back

Every patched BE is a separate boot environment, and the stock one is left
untouched. Pick the previous entry in the GRUB menu, or run
`midclt call boot.environment.activate '{"id": "25.10.8"}'`. Each
install also takes a `truenas-wifi-pre-*` snapshot of the target BE first.

## Caveats

- AX211 and BE201 are CNVi modules: they only work in boards with a matching
  Intel chipset (AX211: 12th-gen Core or newer; BE201: Meteor Lake or newer).
  BE200 is a normal M.2 PCIe card and works in any board.

- Unsupported by iXsystems. Debug reports from a modified kernel may be
  rejected, and TrueNAS may report the root filesystem as modified.
- Wi-Fi is configured outside the middleware. It won't appear under
  *Network → Interfaces*, so don't use it as the only interface for
  apps/VM bridges.
- Both TrueNAS kernels are rebuilt: production and the **debug kernel**
  (*System → Advanced Settings → Kernel*), each with matching debug ZFS/SCST
  modules, so the toggle keeps working. Bundles from before this change
  (`wifi-TS-25.10.8-r1`) only have the production kernel; the installer
  refuses them while the debug kernel is enabled.
- NVIDIA drivers (system extension) are built by iXsystems against the stock
  kernel. They are untouched; the changed structs aren't used by them, but
  this hasn't been verified.
- Set `SKIP_SCST` on the build only if you never enable iSCSI.

See [docs/MIGRATION.md](docs/MIGRATION.md) for the manual procedure, i.e. what
the tool does step by step and how to do it by hand.

## Repo layout

```
config/wifi.config            kernel config fragment (the actual "port")
config/releases.conf          which TrueNAS releases to build, Debian base per line
patches/linux/                optional source backports (common/ and <major.minor>/)
scripts/build.sh              build one bundle:   build.sh all TS-25.10.8 /out
                              config check only:  build.sh configure <linux tree>
scripts/ci-container.sh       installs build deps in debian:<rel>, runs build.sh
scripts/find-new-releases.sh  emits the build matrix for the watcher
.github/workflows/watch.yml   cron / push / manual trigger
.github/workflows/build.yml   builds + publishes one bundle, opens issue on failure
nas/truenas-wifi              NAS-side installer / updater / Wi-Fi bring-up
```
