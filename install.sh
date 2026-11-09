#!/usr/bin/env bash
# Install or remove the Browsermaxxing CSS theme and its GTK/Qt color watcher.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET_DIR="$SCRIPT_DIR/browsermaxxing"
RUN_SCRIPT="$SCRIPT_DIR/run.sh"
PREF_LINE='user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'

usage() {
  cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Installs the Browsermaxxing userChrome theme into a LibreWolf or Firefox profile,
syncs current GTK/Qt colors, and installs a systemd user path watcher to keep the
palette updated whenever your desktop theme changes.

Options:
  -r, --remove, --uninstall  Uninstall the theme, stop the watcher, and restore backups
  -p, --profile <PATH>       Target browser profile root directory
  -b, --browser <NAME>       Auto-select single initialized profile for: librewolf (default) or firefox
      --librewolf            Shorthand for --browser librewolf
      --firefox              Shorthand for --browser firefox
  -l, --list-profiles        List discovered browser profiles and exit
  -m, --mode <MODE>          Palette mode: desktop (default), dark, light, or auto
  -d, --default [MODE]       Use built-in fallback palette (dark, light, or auto; default: dark)
  -s, --source <SOURCE>      Desktop color source: auto (default), gtk, or qt
      --no-daemon            Do not install the systemd user file-watcher unit
  -f, --force                Overwrite or uninstall even if managed files were edited locally
  -h, --help                 Show this help message
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

config_root() {
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    printf '%s\n' "$XDG_CONFIG_HOME"
  else
    printf '%s/.config\n' "$HOME"
  fi
}

data_root() {
  if [[ -n "${XDG_DATA_HOME:-}" ]]; then
    printf '%s\n' "$XDG_DATA_HOME"
  else
    printf '%s/.local/share\n' "$HOME"
  fi
}

systemd_user_dir() {
  if [[ -n "${SYSTEMD_USER_DIR:-}" ]]; then
    printf '%s\n' "$SYSTEMD_USER_DIR"
  else
    printf '%s/systemd/user\n' "$(config_root)"
  fi
}

find_profiles() {
  local browser="${1:-librewolf}"
  local cfg
  cfg="$(config_root)"
  local -a roots=()

  if [[ "$browser" == "librewolf" || "$browser" == "all" ]]; then
    roots+=(
      "$HOME/.librewolf"
      "$cfg/librewolf"
      "$cfg/librewolf/librewolf"
      "$HOME/.mozilla/librewolf"
      "$HOME/.var/app/io.gitlab.librewolf-community/.librewolf"
      "$HOME/.var/app/io.gitlab.librewolf-community/.config/librewolf"
      "$HOME/.var/app/io.gitlab.librewolf-community/.config/librewolf/librewolf"
    )
  fi
  if [[ "$browser" == "firefox" || "$browser" == "all" ]]; then
    roots+=(
      "$HOME/.mozilla/firefox"
      "$cfg/mozilla/firefox"
      "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
    )
  fi

  local -A seen=()
  local root ini rel_path full_path
  for root in "${roots[@]}"; do
    ini="$root/profiles.ini"
    [[ -f "$ini" ]] || continue
    while IFS= read -r rel_path; do
      [[ -n "$rel_path" ]] || continue
      if [[ "$rel_path" == /* ]]; then
        full_path="$rel_path"
      else
        full_path="$root/$rel_path"
      fi
      if [[ -d "$full_path" ]]; then
        full_path="$(cd "$full_path" && pwd)"
        if [[ -z "${seen[$full_path]:-}" ]]; then
          seen["$full_path"]=1
          printf '%s\n' "$full_path"
        fi
      fi
    done < <(
      awk '
        /^\[/ {
          if (in_profile && path != "") print path
          in_profile = ($0 ~ /^\[Profile/)
          path = ""
          next
        }
        in_profile && /^[[:space:]]*Path[[:space:]]*=/ {
          sub(/^[[:space:]]*Path[[:space:]]*=[[:space:]]*/, "")
          sub(/[[:space:]]*$/, "")
          path = $0
        }
        END {
          if (in_profile && path != "") print path
        }
      ' "$ini"
    )
  done
}

# Find default profile relative paths marked in [Install*] or Default=1 in profiles.ini
find_default_profiles() {
  local browser="${1:-librewolf}"
  local cfg
  cfg="$(config_root)"
  local -a roots=()

  if [[ "$browser" == "librewolf" || "$browser" == "all" ]]; then
    roots+=(
      "$HOME/.librewolf"
      "$cfg/librewolf"
      "$cfg/librewolf/librewolf"
      "$HOME/.mozilla/librewolf"
      "$HOME/.var/app/io.gitlab.librewolf-community/.librewolf"
      "$HOME/.var/app/io.gitlab.librewolf-community/.config/librewolf"
      "$HOME/.var/app/io.gitlab.librewolf-community/.config/librewolf/librewolf"
    )
  fi
  if [[ "$browser" == "firefox" || "$browser" == "all" ]]; then
    roots+=(
      "$HOME/.mozilla/firefox"
      "$cfg/mozilla/firefox"
      "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
    )
  fi

  local -A seen=()
  local root ini rel_path full_path
  for root in "${roots[@]}"; do
    ini="$root/profiles.ini"
    [[ -f "$ini" ]] || continue
    while IFS= read -r rel_path; do
      [[ -n "$rel_path" ]] || continue
      if [[ "$rel_path" == /* ]]; then
        full_path="$rel_path"
      else
        full_path="$root/$rel_path"
      fi
      if [[ -d "$full_path" ]]; then
        full_path="$(cd "$full_path" && pwd)"
        if [[ -z "${seen[$full_path]:-}" ]]; then
          seen["$full_path"]=1
          printf '%s\n' "$full_path"
        fi
      fi
    done < <(
      awk '
        /^\[/ {
          in_install = ($0 ~ /^\[Install/)
          next
        }
        in_install && /^[[:space:]]*Default[[:space:]]*=/ {
          sub(/^[[:space:]]*Default[[:space:]]*=[[:space:]]*/, "")
          sub(/[[:space:]]*$/, "")
          if ($0 != "") print $0
        }
      ' "$ini"
    )
  done
}

is_initialized_profile() {
  local dir="$1"
  [[ -d "$dir" && -f "$dir/prefs.js" ]]
}

has_theme_installed() {
  local dir="$1"
  [[ -f "$dir/chrome/browsermaxxing/state.env" || -f "$dir/chrome/browsermaxxing/state.json" ]]
}

check_browser_not_running() {
  local profile="$1"
  local lock_file="$profile/.parentlock"
  if [[ -f "$lock_file" ]] && command -v flock >/dev/null 2>&1; then
    if ! flock -n "$lock_file" true 2>/dev/null; then
      die "The browser is currently open with this profile. Close it before modifying the theme."
    fi
  fi
}

atomic_write_file() {
  local target="$1"
  local src_file="$2"
  local dir
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  local mode="0600"
  if [[ -f "$target" ]]; then
    mode="$(stat -c '%a' "$target" 2>/dev/null || printf '0600')"
  fi
  local tmp="${target}.browsermaxxing-tmp.$$"
  cp -f "$src_file" "$tmp"
  chmod "$mode" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$target"
}

verify_managed_files() {
  local profile="$1"
  local force="${2:-0}"
  (( force )) && return 0

  local checksum_file="$profile/chrome/browsermaxxing/checksums.sha256"
  [[ -f "$checksum_file" ]] || return 0

  local expected_hash rel_path full_path actual_hash
  while read -r expected_hash rel_path; do
    [[ -n "$expected_hash" && -n "$rel_path" ]] || continue
    full_path="$profile/$rel_path"
    if [[ -L "$full_path" ]]; then
      die "Managed file is a symlink: $full_path"
    fi
    if [[ ! -f "$full_path" ]]; then
      die "Managed file changed or missing after installation: $rel_path. Use --force to override."
    fi
    actual_hash="$(sha256sum "$full_path" | awk '{print $1}')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
      die "File was modified after installation: $rel_path. Preserved; back up your changes or pass --force."
    fi
  done < "$checksum_file"
}

install_watcher() {
  local profile="$1"
  local source="$2"
  local unit_dir
  unit_dir="$(systemd_user_dir)"
  mkdir -p "$unit_dir"

  local cfg data
  cfg="$(config_root)"
  data="$(data_root)"
  local runner="$profile/chrome/browsermaxxing/run.sh"

  cat > "$unit_dir/browsermaxxing.path" <<EOF
[Unit]
Description=Monitor GTK/Qt color schemes for Browsermaxxing theme

[Path]
PathChanged=$cfg/gtk-3.0/gtk.css
PathChanged=$cfg/gtk-3.0/noctalia.css
PathChanged=$cfg/gtk-3.0/colors.css
PathChanged=$cfg/gtk-4.0/gtk.css
PathChanged=$cfg/gtk-4.0/noctalia.css
PathChanged=$cfg/gtk-4.0/colors.css
PathChanged=$cfg/qt5ct/qt5ct.conf
PathChanged=$cfg/qt5ct/colors
PathChanged=$cfg/qt6ct/qt6ct.conf
PathChanged=$cfg/qt6ct/colors
PathChanged=$cfg/kdeglobals
PathChanged=$data/color-schemes
Unit=browsermaxxing.service

[Install]
WantedBy=default.target
EOF

  cat > "$unit_dir/browsermaxxing.service" <<EOF
[Unit]
Description=Synchronize Browsermaxxing theme palette with GTK/Qt colors

[Service]
Type=oneshot
ExecStart="$runner" --profile "$profile" --source "$source"
EOF

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable --now browsermaxxing.path >/dev/null 2>&1 || true
  fi
}

remove_watcher() {
  local unit_dir
  unit_dir="$(systemd_user_dir)"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now browsermaxxing.path >/dev/null 2>&1 || true
    systemctl --user stop browsermaxxing.service >/dev/null 2>&1 || true
  fi

  rm -f "$unit_dir/browsermaxxing.path" "$unit_dir/browsermaxxing.service"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
}

uninstall_theme() {
  local profile="$1"
  local force="$2"
  local bmx_dir="$profile/chrome/browsermaxxing"
  local state_file="$bmx_dir/state.env"
  local legacy_state="$bmx_dir/state.json"

  if [[ ! -d "$bmx_dir" ]] || { [[ ! -f "$state_file" ]] && [[ ! -f "$legacy_state" ]]; }; then
    die "This profile does not have a managed Browsermaxxing installation: $profile"
  fi

  verify_managed_files "$profile" "$force"
  remove_watcher

  if [[ -f "$state_file" ]]; then
    local ORIG_USERCHROME_EXISTED=0
    local ORIG_USERJS_EXISTED=0
    # shellcheck disable=SC1090
    source "$state_file"

    if [[ "${ORIG_USERCHROME_EXISTED:-0}" == "1" && -f "$bmx_dir/backup/userChrome.css.bak" ]]; then
      atomic_write_file "$profile/chrome/userChrome.css" "$bmx_dir/backup/userChrome.css.bak"
    else
      rm -f "$profile/chrome/userChrome.css"
    fi

    if [[ "${ORIG_USERJS_EXISTED:-0}" == "1" && -f "$bmx_dir/backup/user.js.bak" ]]; then
      atomic_write_file "$profile/user.js" "$bmx_dir/backup/user.js.bak"
    else
      rm -f "$profile/user.js"
    fi
  elif [[ -f "$legacy_state" ]]; then
    # Support cleanly removing an installation created by the older install.py
    local rel b64
    for rel in "chrome/userChrome.css" "user.js"; do
      b64="$(awk -v k="\"$rel\"" '
        $0 ~ k { in_file = 1; next }
        in_file && /"original":/ {
          if ($0 ~ /null/) { print "NULL"; exit }
          gsub(/^.*"original":[[:space:]]*"|"[[:space:]]*,?[[:space:]]*$/, "")
          print $0
          exit
        }
      ' "$legacy_state")"
      if [[ -n "$b64" && "$b64" != "NULL" ]]; then
        printf '%s' "$b64" | base64 -d > "$bmx_dir/legacy_restore.tmp"
        atomic_write_file "$profile/$rel" "$bmx_dir/legacy_restore.tmp"
        rm -f "$bmx_dir/legacy_restore.tmp"
      else
        rm -f "$profile/$rel"
      fi
    done
  fi

  rm -rf "$bmx_dir"
  rmdir "$profile/chrome" 2>/dev/null || true

  printf 'Previous CSS, user.js, and systemd watcher removed/restored for: %s\n' "$profile"
}

main() {
  local profile_arg=""
  local browser="librewolf"
  local browser_explicit=0
  local list_only=0
  local remove_only=0
  local mode=""
  local mode_explicit=0
  local source="auto"
  local no_daemon=0
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--remove|--uninstall)
        remove_only=1
        shift
        ;;
      -p|--profile)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        profile_arg="$2"
        shift 2
        ;;
      -b|--browser)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        browser="$2"
        browser_explicit=1
        shift 2
        ;;
      --librewolf)
        browser="librewolf"
        browser_explicit=1
        shift
        ;;
      --firefox)
        browser="firefox"
        browser_explicit=1
        shift
        ;;
      -l|--list-profiles)
        list_only=1
        shift
        ;;
      -m|--mode)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        mode="$2"
        mode_explicit=1
        shift 2
        ;;
      -d|--default)
        mode_explicit=1
        if [[ $# -ge 2 && "$2" =~ ^(dark|light|auto)$ ]]; then
          mode="$2"
          shift 2
        else
          mode="dark"
          shift
        fi
        ;;
      -s|--source)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        source="$2"
        shift 2
        ;;
      --no-daemon|--no-watch)
        no_daemon=1
        shift
        ;;
      -f|--force)
        force=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1 (use --help for usage)"
        ;;
    esac
  done

  case "$source" in
    auto|gtk|qt) ;;
    *) die "Unsupported source: $source (expected auto, gtk, or qt)" ;;
  esac

  if [[ -n "$mode" ]]; then
    case "$mode" in
      desktop|dark|light|auto) ;;
      *) die "Unsupported mode: $mode (expected desktop, dark, light, or auto)" ;;
    esac
  else
    mode="desktop"
  fi

  if (( list_only )); then
    local search_target="all"
    (( browser_explicit )) && search_target="$browser"
    local -A is_def_map=()
    local d
    while IFS= read -r d; do
      [[ -n "$d" ]] && is_def_map["$d"]=1
    done < <(find_default_profiles "$search_target")

    local -a found=()
    local p
    while IFS= read -r p; do
      [[ -n "$p" ]] && found+=("$p")
    done < <(find_profiles "$search_target")
    if [[ ${#found[@]} -gt 0 ]]; then
      for p in "${found[@]}"; do
        local -a tags=()
        [[ -n "${is_def_map[$p]:-}" || "$p" == *.default-release ]] && tags+=("active")
        if is_initialized_profile "$p"; then
          tags+=("initialized")
        else
          tags+=("unused/empty")
        fi
        has_theme_installed "$p" && tags+=("theme installed")
        local IFS=", "
        printf '%s  [%s]\n' "$p" "${tags[*]}"
      done
    else
      printf 'No browser profiles found. Open and close LibreWolf or Firefox once first.\n'
    fi
    exit 0
  fi

  local profile=""
  if [[ -n "$profile_arg" ]]; then
    [[ -d "$profile_arg" ]] || die "Profile directory does not exist: $profile_arg"
    profile="$(cd "$profile_arg" && pwd)"
  else
    local -a candidates=()
    local -a installed_candidates=()
    local -A is_def_map=()
    local d p
    while IFS= read -r d; do
      [[ -n "$d" ]] && is_def_map["$d"]=1
    done < <(find_default_profiles "$browser")

    while IFS= read -r p; do
      if is_initialized_profile "$p"; then
        candidates+=("$p")
        has_theme_installed "$p" && installed_candidates+=("$p")
      fi
    done < <(find_profiles "$browser")

    if [[ ${#candidates[@]} -eq 0 && $browser_explicit -eq 0 ]]; then
      while IFS= read -r d; do
        [[ -n "$d" ]] && is_def_map["$d"]=1
      done < <(find_default_profiles "firefox")
      while IFS= read -r p; do
        if is_initialized_profile "$p"; then
          candidates+=("$p")
          has_theme_installed "$p" && installed_candidates+=("$p")
        fi
      done < <(find_profiles "firefox")
    fi

    if [[ ${#installed_candidates[@]} -eq 1 ]]; then
      profile="${installed_candidates[0]}"
    elif [[ ${#candidates[@]} -eq 1 ]]; then
      profile="${candidates[0]}"
    elif [[ ${#candidates[@]} -gt 1 ]]; then
      local -a active_candidates=()
      for p in "${candidates[@]}"; do
        if [[ -n "${is_def_map[$p]:-}" ]]; then
          active_candidates+=("$p")
        fi
      done
      if [[ ${#active_candidates[@]} -eq 0 ]]; then
        for p in "${candidates[@]}"; do
          if [[ "$p" == *.default-release ]]; then
            active_candidates+=("$p")
          fi
        done
      fi
      if [[ ${#active_candidates[@]} -eq 1 ]]; then
        profile="${active_candidates[0]}"
      else
        die "Multiple initialized profiles found. Run './install.sh -l' and pass '-p <PATH>'."
      fi
    else
      die "No initialized profile found. Open and close the browser once, or pass '-p <PATH>'."
    fi
  fi

  if ! is_initialized_profile "$profile"; then
    die "Directory does not look like an initialized profile: $profile. Open and close the browser first."
  fi

  check_browser_not_running "$profile"

  if (( remove_only )); then
    uninstall_theme "$profile" "$force"
    exit 0
  fi

  # Check for symlink attacks on target paths before doing anything
  local rel
  for rel in "chrome/userChrome.css" "user.js"; do
    if [[ -L "$profile/$rel" ]]; then
      die "Managed file is a symlink: $profile/$rel"
    fi
  done
  for asset in "$ASSET_DIR"/*.css; do
    rel="chrome/browsermaxxing/$(basename "$asset")"
    if [[ -L "$profile/$rel" ]]; then
      die "Managed file is a symlink: $profile/$rel"
    fi
  done

  local bmx_dir="$profile/chrome/browsermaxxing"
  local state_file="$bmx_dir/state.env"
  local backup_dir="$bmx_dir/backup"

  # If already installed, verify managed files haven't been hand-edited
  if [[ -f "$state_file" ]]; then
    verify_managed_files "$profile" "$force"
  fi

  # If mode is desktop, validate or generate palette BEFORE mutating profile files
  local desktop_css=""
  if [[ "$mode" == "desktop" ]]; then
    if desktop_css="$("$RUN_SCRIPT" --source "$source" --print-palette 2>/dev/null)"; then
      :
    elif (( mode_explicit )); then
      die "No supported active GTK/Qt export found."
    else
      # Graceful fallback to default dark mode when --mode was not explicitly forced
      mode="dark"
    fi
  fi

  mkdir -p "$backup_dir"

  # Preserve original files on first installation only
  local orig_userchrome_existed=0
  local orig_userjs_existed=0
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file"
    orig_userchrome_existed="${ORIG_USERCHROME_EXISTED:-0}"
    orig_userjs_existed="${ORIG_USERJS_EXISTED:-0}"
  else
    if [[ -f "$profile/chrome/userChrome.css" ]]; then
      cp -f "$profile/chrome/userChrome.css" "$backup_dir/userChrome.css.bak"
      orig_userchrome_existed=1
    fi
    if [[ -f "$profile/user.js" ]]; then
      cp -f "$profile/user.js" "$backup_dir/user.js.bak"
      orig_userjs_existed=1
    fi
  fi

  # Build chrome/userChrome.css from original backup + managed header
  local tmp_userchrome="$bmx_dir/userChrome.css.staging"
  {
    printf '/* Browsermaxxing: managed imports. */\n'
    printf '@import url("browsermaxxing/palette-%s.css");\n' "$mode"
    printf '@import url("browsermaxxing/theme.css");\n'
    if (( orig_userchrome_existed )) && [[ -f "$backup_dir/userChrome.css.bak" ]]; then
      cat "$backup_dir/userChrome.css.bak"
    fi
  } > "$tmp_userchrome"
  atomic_write_file "$profile/chrome/userChrome.css" "$tmp_userchrome"
  rm -f "$tmp_userchrome"

  # Build user.js from original backup + legacy stylesheets pref
  local tmp_userjs="$bmx_dir/user.js.staging"
  : > "$tmp_userjs"
  if (( orig_userjs_existed )) && [[ -f "$backup_dir/user.js.bak" ]]; then
    cat "$backup_dir/user.js.bak" > "$tmp_userjs"
  fi
  if ! grep -Fq "toolkit.legacyUserProfileCustomizations.stylesheets" "$tmp_userjs" 2>/dev/null; then
    {
      printf '\n// Browsermaxxing: browser UI CSS only.\n'
      printf '%s\n' "$PREF_LINE"
    } >> "$tmp_userjs"
  fi
  atomic_write_file "$profile/user.js" "$tmp_userjs"
  rm -f "$tmp_userjs"

  # Copy CSS assets and self-contained run.sh into profile
  local asset
  for asset in "$ASSET_DIR"/*.css; do
    atomic_write_file "$bmx_dir/$(basename "$asset")" "$asset"
  done
  if [[ "$mode" == "desktop" && -n "$desktop_css" ]]; then
    local tmp_pal="$bmx_dir/palette-desktop.css.staging"
    printf '%s\n' "$desktop_css" > "$tmp_pal"
    atomic_write_file "$bmx_dir/palette-desktop.css" "$tmp_pal"
    rm -f "$tmp_pal"
  fi
  atomic_write_file "$bmx_dir/run.sh" "$RUN_SCRIPT"
  chmod +x "$bmx_dir/run.sh"

  # Record installation state and SHA-256 checksums of managed files
  cat > "$state_file" <<EOF
BMX_VERSION=1
BMX_MODE=$mode
BMX_SOURCE=$source
ORIG_USERCHROME_EXISTED=$orig_userchrome_existed
ORIG_USERJS_EXISTED=$orig_userjs_existed
EOF

  local checksum_file="$bmx_dir/checksums.sha256"
  : > "$checksum_file"
  local rel_file
  for rel_file in "chrome/userChrome.css" "user.js"; do
    printf '%s  %s\n' "$(sha256sum "$profile/$rel_file" | awk '{print $1}')" "$rel_file" >> "$checksum_file"
  done
  for asset in "$ASSET_DIR"/*.css; do
    rel_file="chrome/browsermaxxing/$(basename "$asset")"
    printf '%s  %s\n' "$(sha256sum "$profile/$rel_file" | awk '{print $1}')" "$rel_file" >> "$checksum_file"
  done

  if (( ! no_daemon )); then
    if [[ "$mode" == "desktop" ]]; then
      install_watcher "$profile" "$source"
    else
      remove_watcher
    fi
  fi

  printf 'Browsermaxxing installed (%s): %s\nOpen or restart the browser to load the theme.\n' "$mode" "$profile"
}

main "$@"
