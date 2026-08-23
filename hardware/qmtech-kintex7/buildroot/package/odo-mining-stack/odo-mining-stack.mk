################################################################################
#
# odo-mining-stack
#
################################################################################

ODO_MINING_STACK_VERSION = local
ODO_MINING_STACK_SITE = $(BR2_EXTERNAL_AM01_PATH)/../sw
ODO_MINING_STACK_SITE_METHOD = local
ODO_MINING_STACK_LICENSE = GPL-3.0
ODO_MINING_STACK_DEPENDENCIES = \
	host-pkgconf libgpiod libpng freetype fontconfig

# odo-miner-cyclonev is a sibling checkout of this repository, not a submodule.
ODO_MINING_STACK_ODO_REPO = \
	$(BR2_EXTERNAL_AM01_PATH)/../../../../odo-miner-cyclonev
ODO_MINING_STACK_GPIO_BUS = $(BR2_EXTERNAL_AM01_PATH)/../cm4-firmware

ODO_MINING_STACK_MAKE_OPTS = \
	CC="$(TARGET_CC)" \
	PKG_CONFIG="$(HOST_DIR)/bin/pkg-config" \
	CFLAGS="$(TARGET_CFLAGS)" \
	LDFLAGS="$(TARGET_LDFLAGS)" \
	ODO_REPO="$(ODO_MINING_STACK_ODO_REPO)" \
	GPIO_BUS="$(ODO_MINING_STACK_GPIO_BUS)"

define ODO_MINING_STACK_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) $(ODO_MINING_STACK_MAKE_OPTS) all
endef

define ODO_MINING_STACK_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) $(ODO_MINING_STACK_MAKE_OPTS) \
		DESTDIR="$(TARGET_DIR)" PREFIX=/usr install
	$(INSTALL) -D -m 0644 $(BR2_EXTERNAL_AM01_PATH)/../linux/am01-fpga-gpio.dts \
		$(TARGET_DIR)/boot/overlays/am01-fpga-gpio.dts
endef

define ODO_MINING_STACK_USERS
	miner -1 miner -1 * /var/lib/odo-miner - - AM01 mining daemon
endef

define ODO_MINING_STACK_PERMISSIONS
	/var/lib/odo-miner d 755 miner miner - - - - -
endef

$(eval $(generic-package))
