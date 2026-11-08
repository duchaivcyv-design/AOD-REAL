ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AODREALPrefs

AODREALPrefs_FILES = AODREALRootListController.m
AODREALPrefs_FRAMEWORKS = UIKit Foundation
AODREALPrefs_INSTALL_PATH = /Library/PreferenceBundles
AODREALPrefs_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
AODREALPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
