include $(TOPDIR)/rules.mk

PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUCI_TITLE:=AbeyyWRT Control Center for Arcadyan AW1000
LUCI_DESCRIPTION:=Dashboard, live topology and SQM/NSS performance engine for Arcadyan AW1000
LUCI_DEPENDS:=+luci-base +luci-mod-status +rpcd +ubus +iw +jsonfilter
LUCI_PKGARCH:=all
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=AbeyyTechXy

define Package/luci-app-abeyywrt/postinst
#!/bin/sh
chmod 0755 "$${IPKG_INSTROOT}/usr/bin/abeyy-dashboard-stats" 2>/dev/null || true
chmod 0755 "$${IPKG_INSTROOT}/usr/libexec/abeyywrt-performance" 2>/dev/null || true
chmod 0755 "$${IPKG_INSTROOT}/usr/libexec/abeyywrt-wifi-assoc" 2>/dev/null || true
if [ -z "$${IPKG_INSTROOT}" ]; then
	rm -f /tmp/luci-indexcache 2>/dev/null || true
	rm -rf /tmp/luci-modulecache 2>/dev/null || true
	/etc/init.d/rpcd restart 2>/dev/null || true
	/etc/init.d/uhttpd restart 2>/dev/null || true
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
