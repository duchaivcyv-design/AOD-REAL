ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard backboardd Preferences PosterBoard PaperBoard ClockAngel

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AODREAL
AODREAL_FILES = Tweak.xm
AODREAL_FRAMEWORKS = UIKit Foundation QuartzCore IOKit CoreGraphics
AODREAL_PRIVATE_FRAMEWORKS = Preferences BacklightServices PosterKit ClockKit BackBoardServices
AODREAL_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function -Wno-deprecated-declarations -Wno-objc-method-access
AODREAL_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard backboardd Preferences PosterBoard PaperBoard ClockAngel"
