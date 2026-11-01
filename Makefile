ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = SpringBoard backboardd Preferences PosterBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RealAOD
RealAOD_FILES = Tweak.xm
RealAOD_FRAMEWORKS = UIKit Foundation QuartzCore
RealAOD_PRIVATE_FRAMEWORKS = BacklightServices
RealAOD_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard backboardd"
