# Installing warpd on a Mac

This guide sets up this fork of warpd on a Mac from scratch, e.g a second or a
work machine. It takes about five minutes and does not require administrator
rights.

warpd is built from source on each Mac. That avoids Gatekeeper warnings for
downloaded binaries and lets every Mac sign its build with its own private key
(see [Why a signing identity?](#why-a-signing-identity)).

## 1. Check whether the Mac is managed

warpd reads all keyboard input and controls the pointer. If the Mac is managed
by your company (System Settings → General → Device Management lists a
profile), check that tools like this are allowed before installing. Some
companies block or pre-approve Accessibility permissions centrally.

## 2. Install Apple's command line tools

```
xcode-select --install
```

Skip this if `git --version` already works. A full Xcode installation also
works.

## 3. Download and build

```
git clone https://github.com/mwhaubold/warpd.git ~/warpd
cd ~/warpd
make signing-setup
make
make install-user
```

- `make signing-setup` creates a private code signing identity called
  `warpd-dev` in your login keychain (once per Mac). On the first `make`
  afterwards macOS may ask whether `codesign` may use the key: enter your login
  password and choose **Always Allow**.
- `make install-user` installs warpd to `~/.local/bin/warpd`, the man page to
  `~/.local/share/man` and a launch agent that starts warpd at login, and
  starts it right away.

## 4. Grant Accessibility access

macOS asks for Accessibility access as soon as warpd starts. Open
System Settings → Privacy & Security → Accessibility and enable **warpd**. If
it isn't listed, click **+**, press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>G</kbd>, enter
`~/.local/bin/warpd` and add it.

warpd notices the permission within a second, no restart is needed.

> **Don't start warpd from a terminal** (e.g `warpd -f`). macOS then checks
> the *terminal app's* Accessibility permission instead of warpd's and warpd
> keeps waiting. Granting the terminal access would work, but would also let
> every program run in it read your keystrokes.

## 5. Check that it works

- A cursor icon appears in the menu bar.
- <kbd>⌥</kbd><kbd>⌘</kbd><kbd>X</kbd> shows hints, type one to move the
  pointer, <kbd>Esc</kbd> exits.
- With several displays, <kbd>⌥</kbd><kbd>⌘</kbd><kbd>S</kbd> switches
  between them.

See `man warpd` (or [warpd.1.md](warpd.1.md)) for all modes and keys.

## Bring your configuration along

The configuration lives in `~/.config/warpd/config` (menu bar icon → **Open
Config…**). Copy it from your other Mac to the same path on the new one, it is
reloaded automatically when saved.

Optionally add `~/.local/bin` to your `PATH` to use `warpd` on the command
line (e.g `warpd --list-options`), add this to `~/.zshrc`:

```
export PATH="$HOME/.local/bin:$PATH"
```

## Updating

```
cd ~/warpd
git pull
make && make install-user
```

The Accessibility permission is kept because the binary stays at the same path
and is signed with the same identity.

## Uninstalling

```
cd ~/warpd
make uninstall-user
```

Then remove warpd from System Settings → Privacy & Security → Accessibility.
To also remove the signing identity, delete the `warpd-dev` certificate and key
in Keychain Access (login keychain → My Certificates).

## Replacing an upstream installation

If the Mac has the official warpd release (or a `sudo make install` build)
installed, remove it first so two copies don't compete for the same keys:

```
launchctl unload /Library/LaunchAgents/com.warpd.warpd.plist
sudo rm /usr/local/bin/warpd /usr/local/share/man/man1/warpd.1.gz /Library/LaunchAgents/com.warpd.warpd.plist
```

Also remove its entry from the Accessibility list. The official releases are
signed with a certificate whose private key is public, so any program signed
with it would inherit that permission.

## Troubleshooting

| Problem | Fix |
|---|---|
| Nothing happens on <kbd>⌥</kbd><kbd>⌘</kbd><kbd>X</kbd> | Check that warpd is enabled in the Accessibility list for `~/.local/bin/warpd`. Toggle it off and on after rebuilding without a signing identity. |
| warpd isn't running | `launchctl print gui/$(id -u)/com.warpd.warpd` shows its state; `make install-user` (re)starts it. Quitting from the menu bar keeps it stopped until the next login. |
| Shortcuts stopped working | warpd may be paused, check the menu bar icon (a crossed out cursor). |
| Keys don't reach warpd in a terminal | Some terminals (e.g iTerm) have a "secure keyboard entry" mode which hides keystrokes from other apps, turn it off. |
| Logs | `log stream --process warpd` |

## Why a signing identity?

macOS remembers the Accessibility permission by the program's code signature.
Without a stable signature every rebuild looks like a new program and the
permission has to be granted again. `make signing-setup` generates a key pair
on the Mac itself, so the signature stays the same across rebuilds and nobody
else can sign programs that macOS would mistake for your warpd. Builds still
work without it (they are signed ad hoc), you just have to re-grant access
after every update.

Notes: Intel Macs are supported by the build but haven't been tested with this
fork. `make rel` builds a universal (Apple Silicon + Intel) release tarball.
