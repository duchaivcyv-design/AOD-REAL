ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AODREALPrefs
AODREALPrefs_FILES = AODREALRootListController.m
AODREALPrefs_FRAMEWORKS = UIKit
AODREALPrefs_INSTALL_PATH = /Library/PreferenceBundles
AODREALPrefs_PRIVATE_FRAMEWORKS = Preferences
AODREALPrefs_RESOURCE_DIR = Resources

include $(THEOS_MAKE_PATH)/bundle.mk
