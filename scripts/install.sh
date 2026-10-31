#!/usr/bin/env bash
# Builds a release Minuteer and installs it as ~/Applications/Minuteer.app.
#
# Usage:
#   scripts/install.sh
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then sed -n '2,5p' "$0"; exit 0; fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
source "$HERE/lib.sh"
detect_build_target
"$HERE/build.sh" Release
INSTALL_DIR="$HOME/Applications"; DEST="$INSTALL_DIR/${SPM_EXECUTABLE}.app"
SRC="$(spm_bin_path release)"
[[ -f "$SRC" ]] || die "Binary not found at $SRC"
mkdir -p "$INSTALL_DIR"
[[ -d "$DEST" ]] && { log "Removing previous install at $DEST"; rm -rf "$DEST"; }
log "Assembling $SPM_EXECUTABLE.app"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$SRC" "$DEST/Contents/MacOS/$SPM_EXECUTABLE"
ICON_NAME=""
if [[ -f "$REPO_ROOT/Resources/AppIcon.icns" ]]; then
  cp "$REPO_ROOT/Resources/AppIcon.icns" "$DEST/Contents/Resources/AppIcon.icns"; ICON_NAME="AppIcon"
fi
spm_write_app_info_plist "$DEST/Contents/Info.plist" "$ICON_NAME"
IDENTITY="${MINUTEER_SIGN_IDENTITY:-${INJESTAUDIO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}}"
if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" --identifier com.ragingcoders.Minuteer "$DEST" 2>/dev/null; then
  log "Signed with: $IDENTITY"
else
  codesign --force --sign - "$DEST" 2>/dev/null || true
  log "Signed ad-hoc"
fi
log "Installed $SPM_EXECUTABLE to $DEST"
