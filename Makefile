export THEOS_PACKAGE_SCHEME = roothide
export ARCHS = arm64e
export TARGET = iphone:clang:15.6:15.0

export DEBUG = 0
export FINALPACKAGE = 1

INSTALL_TARGET_PROCESSES = SpringBoard


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Vedette

Vedette_FILES = $(wildcard *.xm) $(wildcard *.mm)
Vedette_CFLAGS = -fobjc-arc -O2 -DNDEBUG -DDISABLE_ROOTLESS_COMPAT_WARNING
Vedette_CCFLAGS = -O2 -DNDEBUG

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += vedetteprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
