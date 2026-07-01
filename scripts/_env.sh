# Sourced by the build scripts. Ensures a Swift toolchain that includes SwiftUI's macro
# plugins (libSwiftUIMacros, used by @State/@Bindable/etc.). The active developer dir may be
# Command Line Tools, which does NOT ship those plugins, so prefer a full Xcode when present.
_plugin_rel="Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
_has_swiftui_macros() { [ -n "$1" ] && [ -e "$1/$_plugin_rel" ]; }

if _has_swiftui_macros "${DEVELOPER_DIR:-}"; then
  : # already pointing at a suitable toolchain
elif _cur="$(xcode-select -p 2>/dev/null)" && _has_swiftui_macros "$_cur"; then
  export DEVELOPER_DIR="$_cur"
else
  for _app in /Applications/Xcode.app /Applications/Xcode-*.app "$HOME/Applications/Xcode.app"; do
    if _has_swiftui_macros "$_app/Contents/Developer"; then
      export DEVELOPER_DIR="$_app/Contents/Developer"
      break
    fi
  done
fi

if [ -n "${DEVELOPER_DIR:-}" ]; then
  echo "▸ Using toolchain: $DEVELOPER_DIR"
else
  echo "⚠ No toolchain with SwiftUIMacros found — the SwiftUI build will fail." >&2
  echo "  Install full Xcode and run: sudo xcodebuild -license accept" >&2
fi
