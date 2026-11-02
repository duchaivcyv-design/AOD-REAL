ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard backboardd Preferences PosterBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AODREAL
AODREAL_FILES = Tweak.xm
AODREAL_FRAMEWORKS = UIKit Foundation QuartzCore IOKit
AODREAL_PRIVATE_FRAMEWORKS = BacklightServices
AODREAL_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard backboardd Preferences"
