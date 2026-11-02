ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AODREALPrefs

AODREALPrefs_FILES = AODREALRootListController.m
AODREALPrefs_FRAMEWORKS = UIKit
AODREALPrefs_PRIVATE_FRAMEWORKS = Preferences
AODREALPrefs_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-unused-function
AODREALPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
