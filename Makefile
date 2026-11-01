ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = SpringBoard backboardd Preferences PosterBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AODREAL
AODREAL_FILES = Tweak.xm
AODREAL_FRAMEWORKS = UIKit Foundation QuartzCore
AODREAL_PRIVATE_FRAMEWORKS = BacklightServices
AODREAL_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard backboardd"
