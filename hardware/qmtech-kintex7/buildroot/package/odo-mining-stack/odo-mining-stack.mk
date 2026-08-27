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
	# Login prompt on the USB CDC-ACM gadget (mini-USB J14). The pin-based
	# UART is unavailable: GPIO14/15 are FPGA data bus bits 14/15.
	mkdir -p $(TARGET_DIR)/etc/systemd/system/getty.target.wants
	ln -sf /usr/lib/systemd/system/serial-getty@.service \
		$(TARGET_DIR)/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service
	# Login prompt on HDMI (console=tty1). systemd's own preset says
	# "enable getty@.service", but preset-all cannot instantiate a template for
	# a given instance, so getty@tty1 was never enabled and the board booted to
	# "Reached target Multi-User System" and then sat there with no prompt --
	# with no UART, that left HDMI showing a dead end.
	ln -sf /usr/lib/systemd/system/getty@.service \
		$(TARGET_DIR)/etc/systemd/system/getty.target.wants/getty@tty1.service
	# WiFi association is am01-wifi.service (a plain unit in the overlay,
	# enabled via 00-am01.preset). Mask the wpa_supplicant package's own
	# service so two supplicants cannot contend for wlan0.
	mkdir -p $(TARGET_DIR)/etc/systemd/system
	ln -sf /dev/null $(TARGET_DIR)/etc/systemd/system/wpa_supplicant.service
endef

# The gpio group is created first, then miner joins it, so that the udev rule
# in the overlay can hand /dev/gpiochip* to the daemon without running it as
# root. Fields: user uid group gid password home shell groups comment.
define ODO_MINING_STACK_USERS
	- -1 gpio -1 * - - - GPIO character device access
	miner -1 miner -1 * /var/lib/odo-miner - gpio AM01 mining daemon
endef

define ODO_MINING_STACK_PERMISSIONS
	/var/lib/odo-miner d 755 miner miner - - - - -
endef

$(eval $(generic-package))
