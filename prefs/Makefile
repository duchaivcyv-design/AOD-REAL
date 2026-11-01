ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = RealAODPrefs
RealAODPrefs_FILES = RealAODRootListController.m
RealAODPrefs_FRAMEWORKS = UIKit Foundation
RealAODPrefs_INSTALL_PATH = /Library/PreferenceBundles
RealAODPrefs_PRIVATE_FRAMEWORKS = Preferences

# Resource: Root.plist, icon.png, và bất kỳ file nào trong Resources/
RealAODPrefs_RESOURCE_DIR = Resources

include $(THEOS_MAKE_PATH)/bundle.mk
