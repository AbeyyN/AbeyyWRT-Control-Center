# AbeyyWRT Control Center

Official public download repository for **luci-app-abeyywrt** — the AbeyyWRT LuCI control center for Arcadyan AW1000.

This repository is intentionally **distribution-only**. Public releases contain the installable package and checksums; development source remains in the private firmware repository.

## Included modules

- **Dashboard** — live CPU, RAM, storage, WAN, RX/TX throughput and latency telemetry.
- **Topology** — LAN/inferred-device view with real Wi-Fi association detection and `iw`/nl80211 fallback.
- **Performance** — functional SQM/CAKE ↔ NSS/ECM runtime switching with capability detection.

## Download

Use the **Releases** section of this repository and download the package matching your OpenWrt generation:

- `luci-app-abeyywrt-*.apk` — current apk-based OpenWrt releases.
- `luci-app-abeyywrt_*.ipk` — older opkg-based OpenWrt releases, when provided.
- `SHA256SUMS` — checksum file for release verification.

## Install

### Current OpenWrt (`apk`)

Copy the downloaded package to the router and run:

```sh
apk add --allow-untrusted ./luci-app-abeyywrt-*.apk
```

### Older OpenWrt (`opkg`)

```sh
opkg install ./luci-app-abeyywrt_*.ipk
```

After installation, reopen LuCI and use:

```text
AbeyyWRT
├── Dashboard
├── Topology
└── Performance
```

## Compatibility

The LuCI package is architecture-independent (`all`) and is designed for Arcadyan AW1000 OpenWrt firmware.

Dashboard and Topology do not require NSS. Performance detects available acceleration/runtime components automatically:

- SQM controls are enabled only when SQM is available.
- NSS/ECM controls are enabled only when the running firmware provides the required QCA NSS/ECM runtime.
- The package does not install or force kernel NSS modules and does not replace the router kernel/network datapath.

## Verify download

When `SHA256SUMS` is included in the release:

```sh
sha256sum -c SHA256SUMS
```

## Versioning

Public releases follow semantic versioning, beginning with **AbeyyWRT Control Center v1.0.0**.

Maintained by **AbeyyTechXy**.
