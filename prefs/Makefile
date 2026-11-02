ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AODREAL

AODREAL_FILES = AODREALRootListController.m
AODREAL_FRAMEWORKS = UIKit Foundation
AODREAL_PRIVATE_FRAMEWORKS = Preferences
AODREAL_INSTALL_PATH = /Library/PreferenceBundles
AODREAL_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/bundle.mk
