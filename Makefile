export ARCHS = arm64e

THEOS_PACKAGE_SCHEME = roothide

export DEBUG = 0
export FINALPACKAGE = 1

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
TARGET := iphone:clang:16.5:15.0
else
TARGET := iphone:clang:latest:7.0
endif
INSTALL_TARGET_PROCESSES = SpringBoard


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Vedette

Vedette_FILES = $(wildcard *.xm) $(wildcard *.mm)
Vedette_CFLAGS = -fobjc-arc -O2 -DNDEBUG -I$(THEOS_PROJECT_DIR)
Vedette_CCFLAGS = -O2 -DNDEBUG

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += vedetteprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
