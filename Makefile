APP := muon-pdf
ZIG ?= zig
ARCH ?= native
OPT ?= ReleaseSmall
STATIC ?= false
PREFIX ?= /usr
BINDIR ?= $(PREFIX)/bin
APPDIR ?= $(PREFIX)/share/applications
ICONDIR ?= $(PREFIX)/share/icons/hicolor/256x256/apps
DESKTOP_FILE := muon-pdf.desktop
ICON_FILE := icon/256x256.png

TARGET_native :=
TARGET_amd64 := x86_64-linux-musl
TARGET_aarch64 := aarch64-linux-musl

ifeq ($(ARCH),native)
TARGET_ARG :=
else ifeq ($(ARCH),amd64)
TARGET_ARG := -Dtarget=$(TARGET_amd64)
else ifeq ($(ARCH),aarch64)
TARGET_ARG := -Dtarget=$(TARGET_aarch64)
else
$(error Unsupported ARCH=$(ARCH), use native|amd64|aarch64)
endif

COMMON_FLAGS := -Doptimize=$(OPT) -Dstatic=$(STATIC)
ifeq ($(STATIC),true)
PKG_CONFIG_CMD := pkg-config --static
else
PKG_CONFIG_CMD := pkg-config
endif

BUILD_CMD = PKG_CONFIG="$(PKG_CONFIG_CMD)" $(ZIG) build $(COMMON_FLAGS) $(TARGET_ARG)

.PHONY: all build run clean install uninstall

all: build

build:
	$(BUILD_CMD)

run:
	$(BUILD_CMD) run -- $(ARGS)

install:
	$(BUILD_CMD)
	install -Dm755 zig-out/bin/$(APP) "$(DESTDIR)$(BINDIR)/$(APP)"
	install -Dm644 $(DESKTOP_FILE) "$(DESTDIR)$(APPDIR)/$(DESKTOP_FILE)"
	install -Dm644 $(ICON_FILE) "$(DESTDIR)$(ICONDIR)/$(APP).png"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(APP)"
	rm -f "$(DESTDIR)$(APPDIR)/$(DESKTOP_FILE)"
	rm -f "$(DESTDIR)$(ICONDIR)/$(APP).png"

clean:
	rm -rf .zig-cache zig-out
