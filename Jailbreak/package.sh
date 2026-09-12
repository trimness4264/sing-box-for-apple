#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: $1 not found${2:+ ($2)}" >&2; exit 1; }; }
need xcodebuild
need ldid "brew install ldid"
need dpkg-deb "brew install dpkg"
[[ -x /usr/libexec/PlistBuddy ]] || { echo "error: /usr/libexec/PlistBuddy missing" >&2; exit 1; }

BASE_PACKAGE_IDENTIFIER="io.nekohasekai.sfajb"
APP_DISPLAY_NAME="sing-box JB"
PRODUCT_NAME="sing-box"
DERIVED_DATA="$REPO_ROOT/build/jailbreak/DerivedData"
APP_SRC="$DERIVED_DATA/Build/Products/Release-iphoneos/$PRODUCT_NAME.app"
PACKAGE_BUILD_ROOT="$REPO_ROOT/build/jailbreak"
ENT="$REPO_ROOT/Jailbreak"
DAEMON_BIN="$DERIVED_DATA/Build/Products/Release-iphoneos/sfajb-roothelper"
HELPER_PLIST="io.nekohasekai.sfajb.helper.plist"
XCODEBUILD_FLAGS=()
if [[ -n "${XCODEBUILD_CLONED_SOURCE_PACKAGES_DIR_PATH:-}" ]]; then
	XCODEBUILD_FLAGS=(-clonedSourcePackagesDirPath "$XCODEBUILD_CLONED_SOURCE_PACKAGES_DIR_PATH")
fi

echo "Building $PRODUCT_NAME (JAILBREAK, $BASE_PACKAGE_IDENTIFIER)"
build() {
	xcodebuild build \
		${XCODEBUILD_FLAGS[@]+"${XCODEBUILD_FLAGS[@]}"} \
		-scheme SFI \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-derivedDataPath "$DERIVED_DATA" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) JAILBREAK' \
		BASE_PACKAGE_IDENTIFIER="$BASE_PACKAGE_IDENTIFIER" \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_BITCODE=NO
}
if command -v xcbeautify >/dev/null 2>&1; then
	build | xcbeautify
else
	build
fi

if [[ ! -d "$APP_SRC" ]]; then
	echo "error: app not built at $APP_SRC" >&2
	exit 1
fi

# The SFI MARKETING_VERSION is stripped to X.Y.Z for App Store Connect; the SFM.System
# standalone target keeps the full prerelease form (set by sing-box's update_apple_version).
VERSION="$(awk -F' = ' '
	/MARKETING_VERSION = / { v=$2; gsub(/[";]/,"",v) }
	/PRODUCT_BUNDLE_IDENTIFIER = "\$\(BASE_PACKAGE_IDENTIFIER\)\.standalone";/ { print v; exit }
' sing-box.xcodeproj/project.pbxproj)"
[[ -n "$VERSION" ]] || { echo "error: could not read standalone MARKETING_VERSION from project.pbxproj" >&2; exit 1; }
echo "Packaging $PRODUCT_NAME $VERSION"

echo "Building sfajb-roothelper daemon ($VERSION)"
build_daemon() {
	xcodebuild build \
		${XCODEBUILD_FLAGS[@]+"${XCODEBUILD_FLAGS[@]}"} \
		-scheme JailbreakDaemon \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-derivedDataPath "$DERIVED_DATA" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) JAILBREAK JAILBREAK_DAEMON' \
		BASE_PACKAGE_IDENTIFIER="$BASE_PACKAGE_IDENTIFIER" \
		MARKETING_VERSION="$VERSION" \
		CODE_SIGNING_ALLOWED=NO
}
if command -v xcbeautify >/dev/null 2>&1; then
	build_daemon | xcbeautify
else
	build_daemon
fi
if [[ ! -f "$DAEMON_BIN" ]]; then
	echo "error: daemon not built at $DAEMON_BIN" >&2
	exit 1
fi
ldid -S"$REPO_ROOT/JailbreakDaemon/RootHelper.entitlements" "$DAEMON_BIN"

# dpkg sorts '~' before everything, so 1.14.0~alpha.33 < 1.14.0 (the eventual release);
# a literal '-' would parse as a Debian revision and sort *after* it, breaking upgrades.
# A literal '~' in the replacement is tilde-expanded by bash 5, and a quoted or escaped one
# is kept verbatim by the bash 3.2 that macOS ships as /bin/bash; only a variable works in both.
TILDE="~"
DEB_VERSION="${VERSION//-/$TILDE}"
PACKAGE_REVISION="${PACKAGE_REVISION:-}"
if [[ -n "$PACKAGE_REVISION" ]]; then
	[[ "$PACKAGE_REVISION" =~ ^[A-Za-z0-9.+~]+$ ]] \
		|| { echo "error: invalid PACKAGE_REVISION: $PACKAGE_REVISION" >&2; exit 1; }
	DEB_VERSION="$DEB_VERSION-$PACKAGE_REVISION"
fi
THEOS_ROOT="${THEOS:-$HOME/theos-roothide}"
[[ -f "$THEOS_ROOT/makefiles/common.mk" ]] || { echo "error: Theos not found at $THEOS_ROOT" >&2; exit 1; }

THEOS_PACKAGE_DIR="$PACKAGE_BUILD_ROOT/packages"
MAIN="sing-box"
SIGN_TABLE="\
PlugIns/Extension.appex/Extension|Extension.plist
PlugIns/FileProviderExtension.appex/FileProviderExtension|FileProvider.plist
PlugIns/WidgetExtension.appex/WidgetExtension|Widget.plist
PlugIns/ShareExtension.appex/ShareExtension|Share.plist
Extensions/IntentsExtension.appex/IntentsExtension|Intents.plist"

package_variant() {
	local scheme="$1"
	local architecture="$2"
	local install_prefix="$3"
	local deb_root="$PACKAGE_BUILD_ROOT/debroot-$scheme"
	local theos_project="$PACKAGE_BUILD_ROOT/theos-project-$scheme"
	local app_dest="$deb_root/Applications/$PRODUCT_NAME.app"
	local daemon_dest="$deb_root/usr/libexec/sfajb-roothelper"
	local plist_dest="$deb_root/Library/LaunchDaemons/$HELPER_PLIST"
	local installed_app="$install_prefix/Applications/$PRODUCT_NAME.app"
	local installed_plist="$install_prefix/Library/LaunchDaemons/$HELPER_PLIST"
	local installed_daemon="$install_prefix/usr/libexec/sfajb-roothelper"
	local bootstrap_path
	local md5_prefix="${install_prefix#/}"

	if [[ "$scheme" == "rootless" ]]; then
		bootstrap_path="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
	else
		bootstrap_path="/usr/bin:/bin:/usr/sbin:/sbin"
	fi

	echo "Packaging $scheme ($architecture)"
	rm -rf "$deb_root" "$theos_project"
	mkdir -p "$deb_root/Applications" "$deb_root/usr/libexec" "$deb_root/Library/LaunchDaemons" "$deb_root/DEBIAN" "$theos_project"
	cp -R "$APP_SRC" "$app_dest"

	/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_DISPLAY_NAME" "$app_dest/Info.plist" 2>/dev/null \
		|| /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_DISPLAY_NAME" "$app_dest/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app_dest/Info.plist"

	# /Applications apps aren't registered with usernotificationsd by installd; this key is what
	# makes it accept and present local notifications. Redundant for the App Store build.
	/usr/libexec/PlistBuddy -c "Add :SBAppUsesLocalNotifications bool true" "$app_dest/Info.plist" 2>/dev/null \
		|| /usr/libexec/PlistBuddy -c "Set :SBAppUsesLocalNotifications true" "$app_dest/Info.plist"

	rm -rf "$app_dest/SC_Info" "$app_dest/_CodeSignature" "$app_dest/embedded.mobileprovision" "$app_dest/Export.plist"
	find "$app_dest" -name '.DS_Store' -delete

	cp "$DAEMON_BIN" "$daemon_dest"
	chmod 755 "$daemon_dest"
	cp "$REPO_ROOT/JailbreakDaemon/$HELPER_PLIST" "$plist_dest"
	/usr/libexec/PlistBuddy -c "Set :Program $installed_daemon" "$plist_dest"
	/usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:PATH $bootstrap_path" "$plist_dest"

	# ldid signs per-binary: its recursive directory mode can't give nested code
	# (the appexes) distinct entitlement sets.
	sign() { echo "  sign $(basename "$1")"; ldid -S"$2" "$1"; }
	adhoc() { echo "  sign $(basename "$1") (ad-hoc)"; ldid -S "$1"; }
	is_entitled() {
		[[ "$1" == "$app_dest/$MAIN" ]] && return 0
		local rel
		while IFS='|' read -r rel _; do
			[[ -n "$rel" && "$1" == "$app_dest/$rel" ]] && return 0
		done <<< "$SIGN_TABLE"
		return 1
	}

	while IFS= read -r macho; do
		is_entitled "$macho" && continue
		adhoc "$macho"
	done < <(find "$app_dest" -type f -perm +111 -exec sh -c 'file -b "$1" | grep -q "Mach-O" && echo "$1"' _ {} \;)

	while IFS='|' read -r rel ent; do
		[[ -z "$rel" ]] && continue
		if [[ -f "$app_dest/$rel" ]]; then
			sign "$app_dest/$rel" "$ENT/$ent"
		else
			echo "  skip $rel (not built)"
		fi
	done <<< "$SIGN_TABLE"
	sign "$app_dest/$MAIN" "$ENT/App.plist"

	export COPYFILE_DISABLE=1
	find "$deb_root" -print0 | xargs -0 xattr -c 2>/dev/null || true
	find "$deb_root" -name '._*' -delete
	find "$deb_root" -name '.DS_Store' -delete

	cat > "$theos_project/control" <<EOF
Package: $BASE_PACKAGE_IDENTIFIER
Name: sing-box JB
Version: $DEB_VERSION
Architecture: $architecture
Description: The universal proxy platform.
Maintainer: nekohasekai
Author: nekohasekai
Section: Applications
Depends: firmware (>= 15.0)
EOF

	cat > "$deb_root/DEBIAN/postinst" <<EOF
#!/bin/sh
PLIST=$installed_plist
launchctl bootout system "\$PLIST" 2>/dev/null
launchctl bootstrap system "\$PLIST" 2>/dev/null
uicache -p $installed_app
exit 0
EOF

	cat > "$deb_root/DEBIAN/prerm" <<EOF
#!/bin/sh
launchctl bootout system $installed_plist 2>/dev/null
case "\$1" in
	remove | purge)
		uicache -u $installed_app 2>/dev/null
		;;
esac
exit 0
EOF
	chmod 755 "$deb_root/DEBIAN/postinst" "$deb_root/DEBIAN/prerm"

	# Theos converts XML plists for final packages. Do it before calculating
	# md5sums so the checksums describe the files that are actually installed.
	"$THEOS_ROOT/bin/convert_xml_plist.sh" -D "$deb_root"
	( cd "$deb_root" && find . -type f ! -path './DEBIAN/*' | sed 's|^\./||' | LC_ALL=C sort \
		| while IFS= read -r f; do
			if [[ -n "$md5_prefix" ]]; then
				printf '%s  %s/%s\n' "$(md5 -q "$f")" "$md5_prefix" "$f"
			else
				printf '%s  %s\n' "$(md5 -q "$f")" "$f"
			fi
		done ) > "$deb_root/DEBIAN/md5sums"
	chmod 644 "$deb_root/DEBIAN/md5sums"
	if [[ -n "$install_prefix" ]]; then
		mkdir -p "${deb_root}tmp$install_prefix"
	fi

	THEOS="$THEOS_ROOT" make -f "$ENT/theos-package.mk" internal-package-check before-package internal-package \
		THEOS_PACKAGE_SCHEME="$scheme" \
		THEOS_PROJECT_DIR="$theos_project" \
		THEOS_STAGING_DIR="$deb_root" \
		THEOS_PACKAGE_DIR="$THEOS_PACKAGE_DIR" \
		THEOS_PACKAGE_NAME="$BASE_PACKAGE_IDENTIFIER" \
		THEOS_PACKAGE_BASE_VERSION="$DEB_VERSION" \
		FINALPACKAGE=1

	local theos_deb_out="$THEOS_PACKAGE_DIR/${BASE_PACKAGE_IDENTIFIER}_${DEB_VERSION}_${architecture}.deb"
	local deb_out="$PACKAGE_BUILD_ROOT/SFI-${VERSION}${PACKAGE_REVISION:+-$PACKAGE_REVISION}-${architecture}.deb"
	[[ -f "$theos_deb_out" ]] || { echo "error: Theos did not create $theos_deb_out" >&2; exit 1; }
	[[ "$(dpkg-deb --field "$theos_deb_out" Architecture)" == "$architecture" ]] \
		|| { echo "error: unexpected package architecture for $scheme" >&2; exit 1; }

	local package_paths
	package_paths="$(dpkg-deb --contents "$theos_deb_out" | awk '{print $6}')"
	if printf '%s\n' "$package_paths" | grep -Eq '^(\./)?(control|\.theos)(/|$)'; then
		echo "error: Theos metadata leaked into $scheme package" >&2
		exit 1
	fi
	if [[ "$scheme" == "rootless" ]]; then
		printf '%s\n' "$package_paths" | grep -Eq '^(\./)?var/jb/Applications/sing-box\.app(/|$)' \
			|| { echo "error: rootless application layout is missing" >&2; exit 1; }
		if printf '%s\n' "$package_paths" | grep -Eq '^(\./)?(Applications|Library|usr)(/|$)'; then
			echo "error: unprefixed payload leaked into rootless package" >&2
			exit 1
		fi
	else
		printf '%s\n' "$package_paths" | grep -Eq '^(\./)?Applications/sing-box\.app(/|$)' \
			|| { echo "error: RootHide application layout is missing" >&2; exit 1; }
		if printf '%s\n' "$package_paths" | grep -Eq '^(\./)?var/jb(/|$)'; then
			echo "error: /var/jb payload leaked into RootHide package" >&2
			exit 1
		fi
	fi

	mv -f "$theos_deb_out" "$deb_out"
	rm -rf "$deb_root" "$theos_project"
	echo "Built $deb_out"
}

package_variant rootless iphoneos-arm64 /var/jb
package_variant roothide iphoneos-arm64e ""
