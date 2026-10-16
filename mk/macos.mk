.PHONY: rel all install clean sign signing-setup install-user uninstall-user check-no-system-install

CFILES=$(shell find src/*.c)
OBJCFILES=$(shell find src/platform/macos -name '*.m')
OBJECTS=$(CFILES:.c=.o) $(OBJCFILES:.m=.o)

RELFLAGS=-framework cocoa -framework carbon -framework UniformTypeIdentifiers -framework QuartzCore

# Code signing identity. Defaults to the private identity created by
# `make signing-setup` if present (keeps the Accessibility permission across
# rebuilds), otherwise ad-hoc signing ('-').
SIGN_IDENTITY?=$(shell security find-certificate -c warpd-dev >/dev/null 2>&1 && echo warpd-dev || echo -)

# The Objective-C code uses automatic reference counting.
OBJCFLAGS=-fobjc-arc

%.o: %.m Makefile mk/*.mk
	$(CC) -c $< -o $@ $(CFLAGS) $(OBJCFLAGS)

USER_PREFIX?=$(HOME)/.local
USER_AGENT=$(HOME)/Library/LaunchAgents/com.warpd.warpd.plist

# A system-wide installation (official release or `sudo make install`) uses
# the same launchd label and lock file, so the two would fight over which one runs.
SYSTEM_BIN?=/usr/local/bin/warpd
SYSTEM_AGENT?=/Library/LaunchAgents/com.warpd.warpd.plist

all: $(OBJECTS)
	-mkdir bin
	$(CC) -o bin/warpd $(OBJECTS) -framework cocoa -framework carbon -framework UniformTypeIdentifiers -framework QuartzCore
	$(MAKE) sign
sign:
	@[ "$(SIGN_IDENTITY)" = "-" ] && echo "Signing ad-hoc (run 'make signing-setup' to keep the Accessibility permission across rebuilds)" || true
	codesign --force --identifier warpd -s "$(SIGN_IDENTITY)" bin/warpd
signing-setup:
	./codesign/setup-identity.sh
rel: clean
	$(CC) -o bin/warpd-arm $(CFILES) $(OBJCFILES) -target arm64-apple-macos $(CFLAGS) $(OBJCFLAGS) $(RELFLAGS)
	$(CC) -o bin/warpd-x86  $(CFILES) $(OBJCFILES) -target x86_64-apple-macos $(CFLAGS) $(OBJCFLAGS) $(RELFLAGS)
	lipo -create bin/warpd-arm bin/warpd-x86 -output bin/warpd && rm -r bin/warpd-*
	$(MAKE) sign
	-rm -rf tmp dist
	mkdir tmp dist
	DESTDIR=tmp make install
	cd tmp && tar czvf ../dist/macos-$(VERSION).tar.gz $$(find . -type f)
	-rm -rf tmp
install:
	mkdir -p $(DESTDIR)/usr/local/bin/ \
		$(DESTDIR)/usr/local/share/man/man1/ \
		$(DESTDIR)/Library/LaunchAgents && \
	install -m644 files/warpd.1.gz $(DESTDIR)/usr/local/share/man/man1 && \
	install -m755 bin/warpd $(DESTDIR)/usr/local/bin/ && \
	install -m644 files/com.warpd.warpd.plist $(DESTDIR)/Library/LaunchAgents
uninstall:
	rm -f $(DESTDIR)/usr/local/share/man/man1/warpd.1.gz \
		$(DESTDIR)/usr/local/bin/warpd \
		$(DESTDIR)/Library/LaunchAgents/com.warpd.warpd.plist
# Per-user install, no sudo required. (Re)starts the warpd agent.
install-user: check-no-system-install
	mkdir -p $(USER_PREFIX)/bin $(USER_PREFIX)/share/man/man1 $(HOME)/Library/LaunchAgents
	install -m644 files/warpd.1.gz $(USER_PREFIX)/share/man/man1
	install -m755 bin/warpd $(USER_PREFIX)/bin/
	sed 's|/usr/local/bin/warpd|$(USER_PREFIX)/bin/warpd|' files/com.warpd.warpd.plist > $(USER_AGENT)
	-launchctl bootout gui/$$(id -u) $(USER_AGENT) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(USER_AGENT)
check-no-system-install:
	@if [ -e $(SYSTEM_BIN) ] || [ -e $(SYSTEM_AGENT) ]; then \
		echo "ERROR: warpd is already installed system-wide ($(SYSTEM_BIN) or $(SYSTEM_AGENT))," >&2; \
		echo "e.g the official release. It would compete with this installation, remove it first:" >&2; \
		echo "" >&2; \
		echo "  launchctl bootout gui/$$(id -u)/com.warpd.warpd" >&2; \
		echo "  sudo rm -f $(SYSTEM_BIN) /usr/local/share/man/man1/warpd.1.gz $(SYSTEM_AGENT)" >&2; \
		echo "" >&2; \
		echo "and remove its entry from System Settings > Privacy & Security > Accessibility." >&2; \
		exit 1; \
	fi
uninstall-user:
	-launchctl bootout gui/$$(id -u) $(USER_AGENT) 2>/dev/null
	rm -f $(USER_AGENT) $(USER_PREFIX)/bin/warpd $(USER_PREFIX)/share/man/man1/warpd.1.gz
clean:
	-rm $(OBJECTS) $(OBJECTS:.o=.d)
