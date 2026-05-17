TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PhoneContextHook
PhoneContextHook_FILES = Tweak.x
PhoneContextHook_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
PhoneContextHook_FRAMEWORKS = UIKit Foundation
PhoneContextHook_PRIVATE_FRAMEWORKS = TelephonyUI

include $(THEOS)/makefiles/tweak.mk
