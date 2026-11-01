ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:latest
INSTALL_TARGET_PROCESSES = SpringBoard backboardd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RealAOD
RealAOD_FILES = Tweak.xm
RealAOD_FRAMEWORKS = UIKit Foundation
RealAOD_PRIVATE_FRAMEWORKS = BacklightServices

include $(THEOS_MAKE_PATH)/tweak.mk
