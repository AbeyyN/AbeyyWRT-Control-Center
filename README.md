# luci-app-abeyywrt

AbeyyWRT Control Center for Arcadyan AW1000.

One LuCI application containing:

- **Dashboard** — live WAN, CPU, RAM, storage, RX/TX throughput and latency telemetry.
- **Topology** — existing AbeyyWRT LAN/inferred-device view plus real Wi-Fi association detection using `iwinfo` with an `iw`/nl80211 fallback.
- **Performance** — functional SQM/CAKE ↔ NSS/ECM runtime switch with actual kernel/runtime detection.

## Compatibility

The package itself is architecture-independent (`all`) and is designed for Arcadyan AW1000 OpenWrt builds.

Dashboard and Topology work without NSS. The Performance page detects capabilities at runtime:

- SQM controls are available only when SQM is installed/configured.
- NSS/ECM controls are available only when the running firmware provides the matching QCA NSS driver, ECM module and NSS frontend.

The package does **not** install or force kernel NSS modules, so installing it on a non-NSS AW1000 does not replace the kernel or network datapath.

## Build inside an AW1000 firmware tree

Copy or clone this directory to:

```text
package/abeyywrt/luci-app-abeyywrt
```

Then enable:

```text
CONFIG_PACKAGE_luci-app-abeyywrt=y
```

and build normally.

Example:

```sh
make menuconfig
make -j$(nproc)
```

For package-only compilation from an already prepared OpenWrt tree:

```sh
make package/luci-app-abeyywrt/compile V=s
```

The resulting installable package is emitted under `bin/packages/.../luci/` (package format depends on the OpenWrt release: `.apk` on current apk-based releases, `.ipk` on older opkg-based releases).

## Install a prebuilt package

Current apk-based OpenWrt:

```sh
apk add --allow-untrusted ./luci-app-abeyywrt-*.apk
```

Older opkg-based OpenWrt:

```sh
opkg install ./luci-app-abeyywrt_*.ipk
```

After installation, reopen LuCI and use:

```text
AbeyyWRT > Dashboard
AbeyyWRT > Topology
AbeyyWRT > Performance
```

## Runtime safety

The Performance Engine treats SQM/CAKE and NSS/ECM as mutually exclusive managed modes. It does not download arbitrary kmods or bypass kernel ABI checks.
