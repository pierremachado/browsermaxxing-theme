#!/usr/bin/env bash
# Automated test suite for Browsermaxxing install.sh and run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
RUN="$ROOT/run.sh"

pass_count=0

assert_eq() {
  local actual="$1"
  local expected="$2"
  local msg="${3:-assertion failed}"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\n  Expected: %s\n  Actual:   %s\n' "$msg" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-expected substring not found}"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'FAIL: %s\n  Missing: %s\n  In:      %s\n' "$msg" "$needle" "$haystack" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-unexpected substring found}"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'FAIL: %s\n  Unexpected: %s\n' "$msg" "$needle" >&2
    exit 1
  fi
}

test_install_modes_and_restore() {
  local tmp
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" RETURN

  local profile="$tmp/profile"
  local systemd_dir="$tmp/systemd"
  mkdir -p "$profile/chrome" "$systemd_dir"
  printf '// fixture\n' > "$profile/prefs.js"

  local orig_css=':root { --existing: 1; }'
  local orig_prefs='user_pref("existing", true);'
  printf '%s\n' "$orig_css" > "$profile/chrome/userChrome.css"
  printf '%s\n' "$orig_prefs" > "$profile/user.js"

  local mode
  for mode in dark light auto; do
    SYSTEMD_USER_DIR="$systemd_dir" "$INSTALL" --profile "$profile" --mode "$mode" --no-daemon >/dev/null
    assert_contains "$(cat "$profile/chrome/userChrome.css")" "palette-${mode}.css" "userChrome mode $mode"
  done

  local pref_count
  pref_count="$(grep -c "toolkit.legacyUserProfileCustomizations.stylesheets" "$profile/user.js")"
  assert_eq "$pref_count" "1" "legacy stylesheet pref should appear once"

  SYSTEMD_USER_DIR="$systemd_dir" "$INSTALL" -r --profile "$profile" >/dev/null
  assert_eq "$(cat "$profile/chrome/userChrome.css")" "$orig_css" "restored userChrome.css matches original"
  assert_eq "$(cat "$profile/user.js")" "$orig_prefs" "restored user.js matches original"
  [[ ! -d "$profile/chrome/browsermaxxing" ]] || { echo "FAIL: browsermaxxing dir still exists"; exit 1; }
  pass_count=$((pass_count + 1))
}

test_modified_files_preserved() {
  local tmp
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" RETURN

  local profile="$tmp/profile"
  mkdir -p "$profile"
  printf '// fixture\n' > "$profile/prefs.js"

  "$INSTALL" --profile "$profile" --default --no-daemon >/dev/null
  printf '/* local edit */\n' >> "$profile/chrome/browsermaxxing/theme.css"

  if "$INSTALL" -r --profile "$profile" 2>/dev/null; then
    echo "FAIL: uninstall should refuse when managed file was edited"
    exit 1
  fi
  assert_contains "$(cat "$profile/chrome/browsermaxxing/theme.css")" "/* local edit */" "local edit preserved"
  pass_count=$((pass_count + 1))
}

test_gtk_qt_sync_fallback_and_watcher() {
  local tmp
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" RETURN

  local cfg="$tmp/config"
  local systemd_dir="$cfg/systemd/user"
  local gtk_dir="$cfg/gtk-3.0"
  local qt_dir="$cfg/qt6ct"
  local profile="$tmp/profile"
  mkdir -p "$gtk_dir" "$qt_dir" "$profile"
  printf '// fixture\n' > "$profile/prefs.js"

  cat > "$gtk_dir/gtk.css" <<'EOF'
@import url("noctalia.css");
EOF

  cat > "$gtk_dir/noctalia.css" <<'EOF'
@define-color window_bg_color #15121a;
@define-color window_fg_color #e7e0ec;
@define-color headerbar_bg_color #211e26;
@define-color accent_bg_color #d3bbff;
@define-color accent_fg_color #40008d;
EOF

  XDG_CONFIG_HOME="$cfg" SYSTEMD_USER_DIR="$systemd_dir" \
    "$INSTALL" --profile "$profile" --mode desktop >/dev/null

  [[ -f "$systemd_dir/browsermaxxing.path" ]] || { echo "FAIL: browsermaxxing.path not created"; exit 1; }
  [[ -f "$systemd_dir/browsermaxxing.service" ]] || { echo "FAIL: browsermaxxing.service not created"; exit 1; }

  local desktop_css="$profile/chrome/browsermaxxing/palette-desktop.css"
  assert_contains "$(cat "$desktop_css")" "#d3bbff" "initial GTK accent color synced"
  assert_not_contains "$(cat "$desktop_css")" "--lwt-" "no direct lwt tokens in palette-desktop.css"

  # Second run without changes should report Already up to date
  local out
  out="$(XDG_CONFIG_HOME="$cfg" "$RUN" --profile "$profile")"
  assert_contains "$out" "Already up to date." "idempotent sync"

  # Update GTK export and run one-shot sync
  sed -i 's/#d3bbff/#aabbcc/' "$gtk_dir/noctalia.css"
  out="$(XDG_CONFIG_HOME="$cfg" "$RUN" --profile "$profile")"
  assert_contains "$out" "Updated" "detects updated GTK export"
  assert_contains "$(cat "$desktop_css")" "#aabbcc" "updated GTK accent color written"

  # Test Qt palette source
  cat > "$qt_dir/qt6ct.conf" <<EOF
[Appearance]
custom_palette=true
color_scheme_path=$qt_dir/scheme.conf
EOF
  cat > "$qt_dir/scheme.conf" <<'EOF'
[ColorScheme]
active_colors=#e7e0ec,#15121a,#ffffff,#ffffff,#ffffff,#444444,#ffffff,#ffffff,#ffffff,#ffffff,#15121a,#ffffff,#a576fd,#1b0043,#ffffff,#ffffff,#ffffff,#ffffff,#ffffff,#ffffff
EOF
  out="$(XDG_CONFIG_HOME="$cfg" "$RUN" --profile "$profile" --source qt)"
  assert_contains "$out" "Palette: qt6." "syncs from Qt6 scheme"
  assert_contains "$(cat "$desktop_css")" "#a576fd" "Qt accent color written"

  # Reset to default fallback palette via run.sh --default
  out="$(XDG_CONFIG_HOME="$cfg" "$RUN" --profile "$profile" --default)"
  assert_contains "$out" "fallback (dark)" "reset to fallback dark palette"
  assert_contains "$(cat "$profile/chrome/userChrome.css")" "palette-dark.css" "userChrome points to palette-dark.css"
  assert_contains "$(cat "$desktop_css")" '@import url("palette-dark.css");' "palette-desktop reset to fallback import"

  # Uninstall with -r removes files and systemd watcher units
  XDG_CONFIG_HOME="$cfg" SYSTEMD_USER_DIR="$systemd_dir" \
    "$INSTALL" -r --profile "$profile" >/dev/null
  [[ ! -f "$profile/chrome/userChrome.css" ]] || { echo "FAIL: userChrome.css should be removed"; exit 1; }
  [[ ! -f "$profile/user.js" ]] || { echo "FAIL: user.js should be removed"; exit 1; }
  [[ ! -f "$systemd_dir/browsermaxxing.path" ]] || { echo "FAIL: browsermaxxing.path should be removed"; exit 1; }
  [[ ! -f "$systemd_dir/browsermaxxing.service" ]] || { echo "FAIL: browsermaxxing.service should be removed"; exit 1; }
  pass_count=$((pass_count + 1))
}

test_invalid_palette_rejected() {
  local tmp
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" RETURN

  local cfg="$tmp/config"
  local gtk_dir="$cfg/gtk-3.0"
  local profile="$tmp/profile"
  mkdir -p "$gtk_dir" "$profile"
  printf '// fixture\n' > "$profile/prefs.js"

  cat > "$gtk_dir/gtk.css" <<'EOF'
@import url("noctalia.css");
EOF
  cat > "$gtk_dir/noctalia.css" <<'EOF'
@define-color window_bg_color #123456; color: red;
@define-color window_fg_color #e7e0ec;
@define-color headerbar_bg_color #211e26;
@define-color accent_bg_color #d3bbff;
@define-color accent_fg_color #40008d;
EOF

  if XDG_CONFIG_HOME="$cfg" "$INSTALL" --profile "$profile" --mode desktop --no-daemon 2>/dev/null; then
    echo "FAIL: invalid color export should be rejected when --mode desktop is explicit"
    exit 1
  fi
  [[ ! -f "$profile/chrome/userChrome.css" ]] || { echo "FAIL: userChrome.css should not be created on failed install"; exit 1; }
  pass_count=$((pass_count + 1))
}

test_nested_xdg_profile_discovery() {
  local tmp
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" RETURN

  local root="$tmp/librewolf/librewolf"
  mkdir -p "$root/test-profile"
  printf '// fixture\n' > "$root/test-profile/prefs.js"
  cat > "$root/profiles.ini" <<'EOF'
[Profile0]
IsRelative=1
Path=test-profile
EOF

  local listed
  listed="$(HOME="$tmp/empty-home" XDG_CONFIG_HOME="$tmp" "$INSTALL" --list-profiles)"
  assert_contains "$listed" "$root/test-profile" "discovers nested XDG LibreWolf profile"
  pass_count=$((pass_count + 1))
}

test_install_modes_and_restore
test_modified_files_preserved
test_gtk_qt_sync_fallback_and_watcher
test_invalid_palette_rejected
test_nested_xdg_profile_discovery

printf 'All %d test suites passed.\n' "$pass_count"
