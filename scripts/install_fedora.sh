#!/bin/sh
# install_fedora.sh -- DEsk on Fedora (Workstation or a spin), in one go.
#
# Run it as yourself from the folder you got DEsk in; it asks for sudo
# when it needs to (run as root -- in a container, say -- it needs none).
# It installs what DEsk is built from and what it runs with, the classic
# programs that go with the desk (unless --no-apps), builds DEsk and
# installs it, puts it on the login screen, and clears away what was
# installed under its old name (DeskWM). Run it again after an update to
# rebuild and reinstall; what is there already is left alone.
#
#   --yes          do not ask; take the answers it would suggest
#   --no-apps      only DEsk, what it needs and the programs its Shell Settings
#                  opens, not the other recommended programs
#   --bare         only DEsk and what it needs: no programs (for a container)
#   --prefix DIR   where DEsk goes (default /usr/local)
#   --help         this
#
# DEsk is built on wlroots 0.18. Fedora's own wlroots has moved on (0.19
# on Fedora 43), but it keeps 0.18 alongside as wlroots0.18-devel, so all
# of it comes from dnf.
#
# Fedora's Meson is the one used, always: a newer one installed with pip
# into ~/.local would set up the build as you, and then Fedora's, which
# root has, could not read that build to install it ("Build directory has
# been generated with Meson version ..., which is incompatible").
#
# The build directory is build-install in the source folder (BUILD_DIR=...
# for another). When it is done, log out and pick "DEsk" on the login
# screen.
set -eu

yes=0 apps=1 sets=1 prefix=/usr/local
while [ $# -gt 0 ]; do
	case "$1" in
	--yes|-y) yes=1 ;;
	--no-apps) apps=0 ;;
	--bare) apps=0 sets=0 ;;
	--prefix)
		[ $# -ge 2 ] || { echo "install_fedora.sh: --prefix wants a folder" >&2; exit 2; }
		prefix=$2
		shift
		;;
	--prefix=*) prefix=${1#--prefix=} ;;
	-h|--help) sed -n '2,/^set /s/^# \{0,1\}//p' "$0"; exit 0 ;;
	*) echo "install_fedora.sh: what is $1? (--help says what it takes)" >&2; exit 2 ;;
	esac
	shift
done
case "$prefix" in
/?*) prefix=${prefix%/} ;;
*) echo "install_fedora.sh: the prefix has to be a whole path, like /usr/local" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${BUILD_DIR:-$root/build-install}"

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf 'install_fedora.sh: %s\n' "$*" >&2; exit 1; }

if ! grep -q "^project('desk'" "$root/meson.build" 2>/dev/null; then
	die "$root does not look like DEsk's source folder (no meson.build for it)"
fi
# A copy made for passing round carries SHA256SUMS, and every file is
# checked against it first: a copy damaged on its way (a stick pulled out
# too soon) stops here and says which files, not at some line of the build
# that says nothing of why. install_session.sh checks it before it runs
# this, and says so (DESK_SUMS_CHECKED).
if [ -z "${DESK_SUMS_CHECKED:-}" ] && [ -f "$root/SHA256SUMS" ] \
	&& command -v sha256sum >/dev/null 2>&1; then
	if ! damaged=$(cd "$root" && sha256sum --quiet -c SHA256SUMS 2>&1); then
		printf '%s\n' "this copy of DEsk is damaged -- these files are not what they were" \
			"when it was made:" >&2
		printf '%s\n' "$damaged" | sed 's/^/  /' >&2
		die "copy the folder again; if a fresh copy is damaged too, suspect the machine's memory or disk (memtest86+)"
	fi
	say "DEsk: every file of this copy checked against SHA256SUMS."
fi
command -v dnf >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1 \
	|| die "there is no dnf here, so this is not Fedora (install_session.sh picks the right one)"
if [ "$yes" -eq 0 ] && [ ! -t 0 ]; then
	die "there is nobody to answer its questions here; run it with --yes to take the suggested answers"
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Root's work -- dnf, and putting files under the prefix, /etc and
# /usr/share -- is done through sudo when we are not root already.
if [ "$(id -u)" -eq 0 ]; then
	as_root() { "$@"; }
else
	command -v sudo >/dev/null 2>&1 \
		|| die "installing needs root: run this as root, or install sudo and add yourself to it"
	as_root() { sudo "$@"; }
fi

# The build is done as whoever owns the source folder, even when this is
# run as root: a build directory owned by root in somebody's clone is a
# nuisance ever after.
builder=
if [ "$(id -u)" -eq 0 ]; then
	owner=$(stat -c %u "$root")
	if [ "$owner" -ne 0 ] && id -nu "$owner" >/dev/null 2>&1; then
		builder=$(id -nu "$owner")
	fi
fi
as_builder() {
	if [ -n "$builder" ]; then
		runuser -u "$builder" -- "$@"
	else
		"$@"
	fi
}

ask() {
	# ask "question" -- yes unless the answer is no; --yes answers for us
	[ "$yes" -eq 1 ] && return 0
	printf '%s [Y/n] ' "$1"
	read -r answer || answer=n
	case "$answer" in
	''|y|Y|yes|Yes) return 0 ;;
	*) return 1 ;;
	esac
}

name="this system" version=""
if [ -r /etc/os-release ]; then
	# shellcheck disable=SC1091
	name=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${ID:-this system}}")
	# shellcheck disable=SC1091
	version=$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")
fi

installed() { rpm -q "$1" >/dev/null 2>&1; }
# What dnf has: asked once, for every name on the list together (a name at
# a time would take minutes), and kept in $tmp/known.
known() { grep -qx "$1" "$tmp/known" 2>/dev/null; }
looked=0
look() {
	[ "$looked" -eq 1 ] && return 0
	say "Reading what dnf has (dnf repoquery)..."
	# shellcheck disable=SC2046
	dnf repoquery --quiet --qf '%{name}\n' $(cut -d'|' -f3 "$tmp/wanted" | tr ' ' '\n' \
		| sort -u) 2>/dev/null | sort -u > "$tmp/known" \
		|| say "Note: dnf repoquery had trouble; going on with what it said."
	looked=1
}

# What it needs, by what for: need|what it is for|Fedora packages, the
# first one installed counting, else the first one dnf has. "build" and
# "run" are always installed, and so is "set": what Shell Settings' System
# pad opens, and what those programs need to work (the polkit agent, the
# keyring, printing, IBus), so that every row of it opens something. "app"
# only without --no-apps. The programs are the classic GTK ones of Xfce
# and MATE, as in the other installers: they leave their frame to DEsk, so
# they lie on the desk as sheets of paper, and nothing else. Fedora has no
# Mugshot, nwg-look, poweralertd or Klee: those rows say so, and DEsk
# does without (the memo pad is written in another hand).
LIST='
build|compiler|gcc
build|compiler: the C library headers|glibc-devel
build|build system (Meson)|meson
build|build system: Ninja|ninja-build
build|build system: finding libraries|pkgconf-pkg-config
build|the room shader, made into C (Python)|python3
build|wlroots 0.18|wlroots0.18-devel
build|Wayland|wayland-devel
build|Wayland protocols|wayland-protocols-devel
build|keyboards (xkbcommon)|libxkbcommon-devel
build|touchpads and mice (libinput)|libinput-devel
build|drawing (cairo)|cairo-devel
build|drawing: pixels (pixman)|pixman-devel
build|typefaces (fontconfig)|fontconfig-devel
build|the display (libdrm)|libdrm-devel
build|the room on the GPU (EGL, GLES)|libglvnd-devel
build|the room on the GPU (gbm)|mesa-libgbm-devel
build|the post box and the tray (sd-bus)|systemd-devel
build|sounds (libpulse)|pulseaudio-libs-devel
build|the screen lock (PAM)|pam-devel
build|X11 programs (xcb)|libxcb-devel
build|X11 programs: window hints (xcb-icccm, xcb-ewmh)|xcb-util-wm-devel
run|X11 programs (Xwayland)|xorg-x11-server-Xwayland
run|portals: file choosers, screen sharing|xdg-desktop-portal
run|portals: GTK file chooser|xdg-desktop-portal-gtk
run|portals: screenshots and screen sharing|xdg-desktop-portal-wlr
run|screen sharing: the PipeWire session manager|wireplumber
run|typefaces: Latin and more (Noto Sans)|google-noto-sans-fonts
run|typefaces: Latin and more (Noto Serif)|google-noto-serif-fonts
run|typefaces: Chinese, Japanese, Korean (Noto Sans CJK)|google-noto-sans-cjk-fonts google-noto-sans-cjk-vf-fonts
run|typefaces: Chinese, Japanese, Korean (Noto Serif CJK)|google-noto-serif-cjk-fonts
run|typefaces: emoji (Noto Color Emoji)|google-noto-color-emoji-fonts
run|typefaces: the desk'"'"'s own (URW base 35)|urw-base35-fonts
run|screenshots (Print)|grim
run|screenshots: a part of the screen|slurp
run|screenshots: onto the clipboard|wl-clipboard
run|screenshots: the letter saying where it went|libnotify
run|home folders (Documents, Pictures...)|xdg-user-dirs
run|opening files and links|xdg-utils
run|the weather at the front door (curl)|curl
app|terminal (Xfce Terminal)|xfce4-terminal
app|files (Thunar)|Thunar
app|files: disks, trash and network places|gvfs
app|files: disks and memory sticks|udisks2
app|files: memory sticks opened when put in|thunar-volman
app|files: thumbnails|tumbler
app|text editor (Mousepad)|mousepad
app|pictures (Ristretto)|ristretto
app|PDF and documents (Atril)|atril
app|archives (Engrampa)|engrampa
app|archives: zip|zip
app|archives: unzip|unzip
app|music and video (Parole)|parole
app|web browser (Firefox)|firefox
set|asking for passwords (MATE polkit agent)|mate-polkit
set|keeping passwords (keyring)|gnome-keyring
set|keyring: unlocked at login|gnome-keyring-pam
app|networks (applet)|network-manager-applet
set|networks: connection editor|nm-connection-editor
set|Bluetooth (Blueman)|blueman
app|memory sticks: mounted, with a letter (udiskie)|udiskie
app|tray slips for udiskie and other indicators|libayatana-appindicator-gtk3
app|a letter when the battery runs low|poweralertd
app|sound (PipeWire)|pipewire-pulseaudio
set|sound: devices and levels|pavucontrol
set|printers|system-config-printer
set|printing service|cups
set|disks (GNOME Disks)|gnome-disk-utility
set|disk usage (QDirStat)|qdirstat baobab
set|colour profiles: the service|colord
set|date, time and users (from LXQt)|lxqt-admin
set|your name and picture (Mugshot)|mugshot
set|passwords and keys (Seahorse)|seahorse
set|adding and removing programs|gnome-packagekit gnome-software
set|backups (Back In Time)|backintime-qt deja-dup
set|full-colour icons (Back In Time wants them)|adwaita-icon-theme-legacy
set|what the computer is doing|xfce4-taskmanager
set|about this computer|hardinfo2
set|about this computer: the graphics part|glx-utils mesa-demos
set|Qt 6 programs on Wayland|qt6-qtwayland
set|Qt 5 programs on Wayland|qt5-qtwayland
set|displays (wdisplays)|wdisplays
set|default programs (Xfce MIME settings)|xfce4-settings
set|theme, icons and cursor (nwg-look)|nwg-look gnome-tweaks
'
# IBus, for every desk: Shell Settings' Input method opens its setup, and
# DEsk hands it the keys itself -- unless fcitx5 is here, which someone has
# chosen (and whose own setup that row opens then).
if ! installed fcitx5; then
	LIST="$LIST
set|input method (IBus)|ibus
"
fi
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
ja*)
	if ! installed fcitx5; then
		LIST="$LIST
app|input method: Japanese (Mozc)|ibus-mozc
"
	fi
	;;
esac
# The clipboard history (Super+V), where this copy of DEsk has it: its
# sheet is drawn with GTK 4 from Python, its key kept in the keyring with
# secret-tool, and it falls back to fzf in foot.
if [ -f "$root/scripts/desk-clipboard" ]; then
	LIST="$LIST
run|clipboard history: its sheet (GTK 4 from Python)|python3-gobject
run|clipboard history: GTK 4|gtk4
run|clipboard history: the encryption|python3-cryptography
run|clipboard history: the key in the keyring (secret-tool)|libsecret
run|clipboard history: in a terminal, where GTK is not|fzf
run|clipboard history: the terminal for that|foot
"
fi

say "DEsk for Fedora -- $name"
case "$version" in
''|4[1-9]|[5-9][0-9]) ;;
*) say "Note: this is made for Fedora 41 and later, and $name is older. It is tried"
	say "      anyway: what decides it is whether dnf has wlroots 0.18 (wlroots0.18-devel)." ;;
esac
say
say "  source    $root"
say "  build     $build"
say "  prefix    $prefix"
if [ "$apps" -eq 1 ]; then
	say "  programs  Shell Settings' and the recommended set (--no-apps: only the former)"
else
	if [ "$sets" -eq 1 ]; then
		say "  programs  only what Shell Settings opens (--no-apps)"
	else
		say "  programs  none (--bare): only DEsk and what it needs"
	fi
fi

# -- 1. packages ------------------------------------------------------------
if [ "$apps" -eq 1 ]; then
	step "What DEsk needs, and the programs that go with it (dnf)"
else
	if [ "$sets" -eq 1 ]; then
		step "What DEsk needs, and what its Shell Settings opens (dnf)"
	else
		step "What DEsk needs (dnf)"
	fi
fi
wanted() {
	printf '%s\n' "$LIST" | while IFS='|' read -r need what pkgs; do
		[ -n "$need" ] || continue
		[ "$need" = app ] && [ "$apps" -eq 0 ] && continue
		[ "$need" = set ] && [ "$sets" -eq 0 ] && continue
		printf '%s|%s|%s\n' "$need" "$what" "$pkgs"
	done
}
# the first of the names that is installed, if one is
have() {
	for p in $1; do
		if installed "$p"; then echo "$p"; return 0; fi
	done
	return 1
}

# dnf is asked only when something is to be installed
wanted > "$tmp/wanted"
missing=0
while IFS='|' read -r need what pkgs; do
	have "$pkgs" >/dev/null || { missing=1; break; }
done < "$tmp/wanted"
[ "$missing" -eq 0 ] || look
list=$tmp/install
: > "$list"
short=""
while IFS='|' read -r need what pkgs; do
	if pick=$(have "$pkgs"); then
		printf '  %-52s %s\n' "$what" "$pick (installed)"
		echo "$pick" >> "$tmp/keep"
		continue
	fi
	pick=""
	for p in $pkgs; do
		if known "$p"; then pick=$p; break; fi
	done
	if [ -n "$pick" ]; then
		printf '  %-52s %s\n' "$what" "$pick"
		grep -qx "$pick" "$list" || echo "$pick" >> "$list"
	else
		printf '  %-52s %s\n' "$what" "${pkgs%% *} (not to be had here)"
		case "$need" in app|set) ;; *) short="$short ${pkgs%% *}" ;; esac
	fi
done < "$tmp/wanted"
if [ -n "$short" ]; then
	die "dnf does not have$short, which DEsk cannot do without. It needs wlroots 0.18,
which Fedora has as wlroots0.18-devel from Fedora 41 on; see the README."
fi
if [ -s "$list" ]; then
	pkgs=$(tr '\n' ' ' < "$list")
	n=$(wc -l < "$list")
	say
	if [ "$n" -eq 1 ]; then
		say "To install (1 package, and what it needs in turn):"
	else
		say "To install ($n packages, and what they need in turn):"
	fi
	say "  $pkgs"
	# shellcheck disable=SC2086
	if [ "$yes" -eq 1 ]; then
		as_root dnf install -y $pkgs || die "dnf could not install them; what it said is above"
	else
		# dnf says what else comes with them, and how much, and asks
		as_root dnf install $pkgs || die "dnf did not install them; what it said is above"
	fi
	# and they are all there before anything is built on them
	for pkg in $pkgs; do
		installed "$pkg" || die "$pkg did not get installed, so DEsk is not installed either"
	done
else
	say
	say "Everything is installed already."
fi
# What DEsk counts on that was installed only as something else's
# dependency (a desktop since taken away): marked as wanted for itself, or
# dnf autoremove would take it away with the rest. (dnf5 says "user",
# dnf4 "install".)
touch "$tmp/keep"
if [ -s "$tmp/keep" ]; then
	# shellcheck disable=SC2046
	as_root dnf mark user -q $(cat "$tmp/keep") >/dev/null 2>&1 \
		|| as_root dnf mark install -q $(cat "$tmp/keep") >/dev/null 2>&1 || true
fi
# wlroots 0.18 as Meson will look for it: Fedora's own wlroots-devel is a
# newer one, under another name, which DEsk is not built on
pkg-config --exists wlroots-0.18 \
	|| die "wlroots 0.18 is not to be found (pkg-config wlroots-0.18); install wlroots0.18-devel"

# -- 2. build ---------------------------------------------------------------
step "Building DEsk${builder:+ (as $builder, who owns the source)}"
# Fedora's Meson, by its path, and with no Python packages of the user's:
# a Meson from pip in ~/.local is found first otherwise -- on the PATH, and
# by Python itself even through /usr/bin/meson -- and the build it sets up
# is one root's Meson then cannot install. The same one does both.
[ -x /usr/bin/meson ] || die "Fedora's Meson (/usr/bin/meson) is not here; install meson"
if [ -x "$HOME/.local/bin/meson" ] || { [ -n "$builder" ] \
	&& [ -x "$(getent passwd "$builder" | cut -d: -f6)/.local/bin/meson" ]; }; then
	say "Note: there is a Meson of your own in ~/.local (pip); Fedora's is used instead."
fi
setup() {
	as_builder env PYTHONNOUSERSITE=1 /usr/bin/meson setup "$@" --prefix="$prefix" \
		--buildtype=release "$build" "$root" > "$tmp/setup.log" 2>&1
}
# The last resort, when the build left from an earlier install cannot be set
# up again (another Meson's, or partly root's after a run with sudo): it is
# only a build, so it goes, and is made afresh.
fresh() {
	say "The build left in $build could not be set up again; it is made afresh."
	as_root rm -rf -- "$build" && setup
}
if [ -f "$build/meson-private/coredata.dat" ]; then
	# set up before: the prefix may have changed, or Meson itself, and a
	# directory a different Meson set up cannot be reconfigured, only wiped
	setup --reconfigure || setup --wipe || fresh \
		|| { cat "$tmp/setup.log"; die "Meson could not set up $build"; }
else
	setup || { cat "$tmp/setup.log"; die "Meson could not set up $build"; }
fi
# what Meson found, from its summary
sed -n '/^desk [0-9]/,/^Found ninja/{/^Found ninja/d;p}' "$tmp/setup.log"
as_builder ninja -C "$build" || die "the build failed; what went wrong is above"
[ -x "$build/desk" ] || die "the build left no desk program in $build"

# -- 3. install -------------------------------------------------------------
step "Installing into $prefix"
as_root env PYTHONNOUSERSITE=1 /usr/bin/meson install -C "$build" --no-rebuild --quiet \
	|| die "installing into $prefix failed (above)"
# Meson's note of what it installed belongs with the rest of the build
as_root chown --reference="$build" "$build/meson-logs/install-log.txt" 2>/dev/null || true
data="$prefix/share"
for f in "$prefix/bin/desk" "$prefix/bin/desk-session" /etc/pam.d/desk; do
	[ -e "$f" ] || die "$f is not there after installing"
done
say "  $prefix/bin/desk and the programs that go with it (desk-session, desk-settings...)"
say "  /etc/pam.d/desk (the screen lock checks the password as login does)"
# What was put in /usr/local is labelled for SELinux as the folder it is in
# says, as a file copied there by hand would not always be.
if command -v restorecon >/dev/null 2>&1 && command -v selinuxenabled >/dev/null 2>&1 \
	&& selinuxenabled; then
	as_root restorecon -RF "$prefix/bin" /etc/pam.d/desk 2>/dev/null || true
fi

# The login screen. GDM, SDDM and LightDM all read /usr/share/wayland-sessions,
# and LightDM nothing else, so the entry goes there, saying where
# desk-session is. It stays in one place only: a login screen that reads
# both would list DEsk twice.
sessions=/usr/share/wayland-sessions
if [ "$data" != /usr/share ]; then
	sed -e "s|^Exec=desk-session|Exec=$prefix/bin/desk-session|" \
		-e "s|^TryExec=desk-session|TryExec=$prefix/bin/desk-session|" \
		"$data/wayland-sessions/desk.desktop" > "$tmp/desk.desktop"
	as_root install -D -m 644 "$tmp/desk.desktop" "$sessions/desk.desktop"
	as_root rm -f "$data/wayland-sessions/desk.desktop"
	as_root rmdir "$data/wayland-sessions" 2>/dev/null || true
fi
say "  $sessions/desk.desktop (\"DEsk\" on the login screen)"

# The portals look for desk-portals.conf -- which portal does what on this
# desktop -- in /etc, and in XDG_DATA_DIRS, which is /usr/local/share and
# /usr/share when nothing says otherwise: the prefix's own copy is found
# for /usr and /usr/local, and any other prefix gets one in /usr/share.
case "$prefix" in
/usr|/usr/local) ;;
*) as_root install -D -m 644 "$data/xdg-desktop-portal/desk-portals.conf" \
		/usr/share/xdg-desktop-portal/desk-portals.conf
	say "  /usr/share/xdg-desktop-portal/desk-portals.conf (which portal does what)"
	;;
esac

# A cache already there has to hear about what is new, or it is not found;
# without one, things are looked for as they are, and none is made.
on_path() { command -v "$1" >/dev/null 2>&1; }
if [ -f "$data/icons/hicolor/icon-theme.cache" ] && on_path gtk-update-icon-cache; then
	as_root gtk-update-icon-cache -q -f "$data/icons/hicolor" || true
fi
if [ -f "$data/applications/mimeinfo.cache" ] && on_path update-desktop-database; then
	as_root update-desktop-database -q "$data/applications" || true
fi

# with a DEsk in /usr as well as /usr/local, the one first on the PATH runs
for other in /usr /usr/local; do
	if [ "$other" != "$prefix" ] && [ -x "$other/bin/desk" ]; then
		say
		say "Note: there is another DEsk in $other ($other/bin/desk). With two, the"
		say "      one that runs is the one first on the PATH (usually /usr/local's)."
		say "      \"sudo ninja uninstall\" in the build it came from takes it away."
	fi
done

case "$prefix" in
/usr|/usr/local) ;;
*) say
	say "Note: a DEsk session finds what is in $prefix/share by itself. For other"
	say "      sessions to list DEsk's programs (Shell Settings, the Experience"
	say "      Index) too, add it to XDG_DATA_DIRS -- in /etc/environment, say:"
	say "        XDG_DATA_DIRS=$prefix/share:/usr/local/share:/usr/share"
	;;
esac

# -- 4. the old name --------------------------------------------------------
# DEsk was DeskWM: deskwm, deskwm-session... Only what is named deskwm* is
# touched; what you kept in ~/.config/deskwm and the like is moved over by
# DEsk itself.
old=$tmp/old
for p in "$prefix" /usr/local /usr; do
	[ -d "$p/bin" ] && find "$p/bin" -maxdepth 1 -name 'deskwm*' 2>/dev/null
	[ -d "$p/share" ] && find "$p/share" -maxdepth 5 -name 'deskwm*' -prune 2>/dev/null
done | sort -u > "$old"
[ -e /etc/pam.d/deskwm ] && echo /etc/pam.d/deskwm >> "$old"
if [ -s "$old" ]; then
	step "Clearing away DeskWM, which is what DEsk was called before"
	sed 's/^/  /' "$old"
	if ask "Remove these?"; then
		while IFS= read -r f; do
			as_root rm -rf -- "$f"
		done < "$old"
		say "Removed."
	else
		say "Left as they are."
	fi
fi

# -- what Shell Settings opens ---------------------------------------------
if [ "$sets" -eq 1 ] && [ -x "$prefix/bin/desk-settings" ]; then
	step "Shell Settings: what each row of the System pad opens"
	as_builder "$prefix/bin/desk-settings" --check > "$tmp/check" 2>&1 || true
	sed 's/^/  /' "$tmp/check"
	if grep -q MISSING "$tmp/check"; then
		say "Note: the rows marked MISSING open nothing yet; Fedora has no package for some"
		say "      (Mugshot, nwg-look), and for the rest the package named brings it."
	fi
fi

# -- the graphics this machine starts at -----------------------------------
# A quick look -- desk-index --suggest -- chooses the Graphics level the desk
# starts at here, for every user of the machine (/etc/xdg/desk/shell.conf,
# under each user's own). DESK_GRAPHICS=<level> chooses in place of the look.
if [ "$sets" -eq 1 ] && [ -x "$prefix/bin/desk-index" ]; then
	step "The graphics this machine starts at"
	level="${DESK_GRAPHICS:-}"
	if [ -z "$level" ]; then
		level=$(as_builder "$prefix/bin/desk-index" --suggest 2> "$tmp/suggest" | tail -n 1) \
			|| level=""
		sed -n 's/^desk-index: /  /p' "$tmp/suggest"
	fi
	case "$level" in
	2d | low | medium | high | ultra)
		sysconf=/etc/xdg/desk/shell.conf
		if [ -f "$sysconf" ]; then
			grep -v '^[[:space:]]*graphics[[:space:]]*=' "$sysconf" > "$tmp/sysconf" || true
		else
			{
				echo "# DEsk's settings for every user of this machine, under each user's own"
				echo "# (~/.config/desk/shell.conf). The installer chose the graphics from a"
				echo "# quick look at the machine; Shell Settings changes a user's own."
			} > "$tmp/sysconf"
		fi
		echo "graphics = $level" >> "$tmp/sysconf"
		as_root mkdir -p /etc/xdg/desk
		as_root install -m 644 "$tmp/sysconf" "$sysconf"
		say "  graphics = $level, for every user (Shell Settings: Graphics, to change one's own)"
		;;
	*)
		say "  Left as made (High): the look said nothing it could use."
		;;
	esac
fi

step "Done"
say "DEsk is installed in $prefix."
if [ -e /etc/systemd/system/display-manager.service ]; then
	say "Log out, pick \"DEsk\" on the login screen (on GDM: the gear at the bottom"
	say "right, once your name is chosen), and log in."
else
	say "There is no login screen here. Log in on the console and type"
	case "$prefix" in
	/usr|/usr/local) say "  desk-session" ;;
	*) say "  $prefix/bin/desk-session" ;;
	esac
	say "or install a login screen, which lists DEsk by itself -- LightDM is a light one:"
	say "  sudo dnf install lightdm lightdm-gtk"
fi
