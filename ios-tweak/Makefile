THEOS_DEVICE_IP = localhost
THEOS_DEVICE_PORT = 2222
ARCHS = arm64
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = PhoneContextHook

PhoneContextHook_FILES = Tweak.m
PhoneContextHook_CFLAGS = -fobjc-arc
PhoneContextHook_FRAMEWORKS = UIKit Foundation WebKit

include $(THEOS_MAKE_PATH)/library.mk
