#!/usr/bin/env bash
# Synchronize Browsermaxxing theme with active GTK/Qt desktop colors (one-shot),
# or reset to the built-in fallback palette.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: ./run.sh [OPTIONS]

Synchronizes the installed Browsermaxxing theme with your current GTK/Qt colors
once, or resets it to a built-in fallback palette.

Options:
  -p, --profile <PATH>       Browser profile directory (auto-detected if omitted)
  -b, --browser <NAME>       Browser for auto-detection: librewolf (default) or firefox
      --librewolf            Shorthand for --browser librewolf
      --firefox              Shorthand for --browser firefox
  -s, --source <SOURCE>      Desktop color source: auto (default), gtk, or qt
  -m, --mode <MODE>          Set palette mode: desktop, dark, light, or auto
  -d, --default [MODE]       Reset to default fallback palette (dark, light, or auto; default: dark)
      --print-palette        Print the extracted desktop palette CSS to stdout and exit
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

# List candidate profile directories from profiles.ini files
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
          if (in_profile && path != "") {
            if (is_rel == 0 || path ~ /^\//) print path
            else print path
          }
          in_profile = ($0 ~ /^\[Profile/)
          path = ""
          is_rel = 1
          next
        }
        in_profile && /^[[:space:]]*Path[[:space:]]*=/ {
          sub(/^[[:space:]]*Path[[:space:]]*=[[:space:]]*/, "")
          sub(/[[:space:]]*$/, "")
          path = $0
        }
        in_profile && /^[[:space:]]*IsRelative[[:space:]]*=/ {
          sub(/^[[:space:]]*IsRelative[[:space:]]*=[[:space:]]*/, "")
          sub(/[[:space:]]*$/, "")
          is_rel = ($0 == "0") ? 0 : 1
        }
        END {
          if (in_profile && path != "") print path
        }
      ' "$ini"
    )
  done
}

is_initialized_profile() {
  local dir="$1"
  [[ -d "$dir" && -f "$dir/prefs.js" ]]
}

resolve_profile() {
  local raw="${1:-}"
  local browser="${2:-librewolf}"

  if [[ -n "$raw" ]]; then
    [[ -d "$raw" ]] || die "Profile directory not found: $raw"
    (cd "$raw" && pwd)
    return 0
  fi

  # If run.sh is invoked from inside <profile>/chrome/browsermaxxing/run.sh
  if [[ -f "$SCRIPT_DIR/state.env" ]] && [[ "$(basename "$SCRIPT_DIR")" == "browsermaxxing" ]]; then
    local candidate
    candidate="$(cd "$SCRIPT_DIR/../.." && pwd)"
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  local -a initialized=()
  local -a installed=()
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if is_initialized_profile "$p"; then
      initialized+=("$p")
      if [[ -f "$p/chrome/browsermaxxing/state.env" ]]; then
        installed+=("$p")
      fi
    fi
  done < <(find_profiles "$browser")

  if [[ ${#installed[@]} -eq 1 ]]; then
    printf '%s\n' "${installed[0]}"
    return 0
  elif [[ ${#initialized[@]} -eq 1 ]]; then
    printf '%s\n' "${initialized[0]}"
    return 0
  elif [[ ${#initialized[@]} -gt 1 ]]; then
    local -a rel_candidates=()
    for p in "${initialized[@]}"; do
      [[ "$p" == *.default-release ]] && rel_candidates+=("$p")
    done
    if [[ ${#rel_candidates[@]} -eq 1 ]]; then
      printf '%s\n' "${rel_candidates[0]}"
      return 0
    fi
    die "Multiple profiles found. Use --profile <PATH> to select one."
  else
    die "No initialized $browser profile found. Use --profile <PATH>."
  fi
}

# Extract and normalize colors from a file using awk.
# Modes passed to awk via -v parser="gtk"|"qt"|"kde"
extract_palette_from_file() {
  local parser_type="$1"
  local file_path="$2"
  [[ -f "$file_path" ]] || return 1

  # Reject files larger than 1 MiB
  local size
  size="$(wc -c < "$file_path")"
  (( size <= 1048576 )) || return 1

  awk -v parser="$parser_type" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }

    function hex_val(h,    i, c, v, res) {
      res = 0
      h = tolower(h)
      for (i = 1; i <= length(h); i++) {
        c = substr(h, i, 1)
        v = index("0123456789abcdef", c) - 1
        if (v < 0) return -1
        res = res * 16 + v
      }
      return res
    }

    function parse_color(raw,    s, r, g, b, n, parts) {
      s = trim(raw)
      if (s ~ /^#[0-9a-fA-F]{3}$/) {
        r = substr(s, 2, 1); g = substr(s, 3, 1); b = substr(s, 4, 1)
        return tolower("#" r r g g b b)
      }
      if (s ~ /^#[0-9a-fA-F]{6}$/) {
        return tolower(s)
      }
      if (s ~ /^#[0-9a-fA-F]{8}$/) {
        # Qt ARGB (#aarrggbb) -> #rrggbb
        return tolower("#" substr(s, 4, 6))
      }
      if (s ~ /^[0-9]{1,3},[[:space:]]*[0-9]{1,3},[[:space:]]*[0-9]{1,3}$/) {
        n = split(s, parts, ",")
        r = int(trim(parts[1]))
        g = int(trim(parts[2]))
        b = int(trim(parts[3]))
        if (r >= 0 && r <= 255 && g >= 0 && g <= 255 && b >= 0 && b <= 255) {
          return sprintf("#%02x%02x%02x", r, g, b)
        }
      }
      return ""
    }

    function chan_r(hex) { return hex_val(substr(hex, 2, 2)) }
    function chan_g(hex) { return hex_val(substr(hex, 4, 2)) }
    function chan_b(hex) { return hex_val(substr(hex, 6, 2)) }

    function round_int(x) { return int(x + 0.5) }

    function mix_color(a, b, amount,    r, g, bl) {
      r  = round_int(chan_r(a) * (1.0 - amount) + chan_r(b) * amount)
      g  = round_int(chan_g(a) * (1.0 - amount) + chan_g(b) * amount)
      bl = round_int(chan_b(a) * (1.0 - amount) + chan_b(b) * amount)
      return sprintf("#%02x%02x%02x", r, g, bl)
    }

    function srgb_linear(c,    v) {
      v = c / 255.0
      if (v <= 0.04045) return v / 12.92
      return exp(2.4 * log((v + 0.055) / 1.055))
    }

    function luminance(hex,    r, g, b) {
      r = srgb_linear(chan_r(hex))
      g = srgb_linear(chan_g(hex))
      b = srgb_linear(chan_b(hex))
      return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    function contrast(a, b,    la, lb, hi, lo) {
      la = luminance(a)
      lb = luminance(b)
      if (la > lb) { hi = la; lo = lb } else { hi = lb; lo = la }
      return (hi + 0.05) / (lo + 0.05)
    }

    function min_val(a, b) { return (a < b) ? a : b }

    function readable(bg, fg,    c_black, c_white) {
      if (contrast(bg, fg) >= 4.5) return fg
      c_black = contrast(bg, "#000000")
      c_white = contrast(bg, "#ffffff")
      return (c_white >= c_black) ? "#ffffff" : "#000000"
    }

    function resolve_gtk(name,    seen, val) {
      delete seen
      while (!(name in seen)) {
        seen[name] = 1
        if (!(name in gtk_map)) return ""
        val = trim(gtk_map[name])
        if (substr(val, 1, 1) != "@") return parse_color(val)
        name = substr(val, 2)
      }
      return ""
    }

    function emit_normalized(raw_bg, raw_surface, raw_text, raw_accent, raw_accent_text, raw_border,
                             bg, surface, text, accent, accent_text, border, muted, scheme, c_black, c_white) {
      bg = parse_color(raw_bg)
      surface = parse_color(raw_surface)
      text = parse_color(raw_text)
      accent = parse_color(raw_accent)
      accent_text = parse_color(raw_accent_text)

      if (bg == "" || surface == "" || text == "" || accent == "" || accent_text == "") {
        exit 1
      }

      if (min_val(contrast(bg, text), contrast(surface, text)) < 4.5) {
        c_black = min_val(contrast(bg, "#000000"), contrast(surface, "#000000"))
        c_white = min_val(contrast(bg, "#ffffff"), contrast(surface, "#ffffff"))
        text = (c_white >= c_black) ? "#ffffff" : "#000000"
      }

      muted = mix_color(text, bg, 0.25)
      if (raw_border != "") {
        border = parse_color(raw_border)
        if (border == "") exit 1
      } else {
        border = mix_color(bg, text, 0.30)
      }
      accent_text = readable(accent, accent_text)
      scheme = (luminance(bg) < 0.35) ? "dark" : "light"

      print "/* Generated from desktop exports. No extension required. */"
      print "@import url(\"palette-static.css\");"
      print ":root {"
      printf "  color-scheme: %s !important;\n", scheme
      printf "  --bmx-bg: %s;\n", bg
      printf "  --bmx-surface: %s;\n", surface
      printf "  --bmx-text: %s;\n", text
      printf "  --bmx-muted: %s;\n", muted
      printf "  --bmx-border: %s;\n", border
      printf "  --bmx-selected: %s;\n", accent
      printf "  --bmx-selected-text: %s;\n", accent_text
      print "  --bmx-hover: color-mix(in srgb, var(--bmx-text) 12%, var(--bmx-surface));"
      print "}"
      exit 0
    }

    {
      if (parser == "gtk") {
        line = trim($0)
        if (line ~ /^@define-color[[:space:]]+[A-Za-z0-9_]+[[:space:]]+.+;$/) {
          stmt = line
          sub(/^@define-color[[:space:]]+/, "", stmt)
          sub(/;$/, "", stmt)
          sp = index(stmt, " ")
          tab = index(stmt, "\t")
          if (tab > 0 && (sp == 0 || tab < sp)) sp = tab
          if (sp > 0) {
            k = substr(stmt, 1, sp - 1)
            v = trim(substr(stmt, sp + 1))
            gtk_map[k] = v
          }
        }
      } else if (parser == "qt") {
        if ($0 ~ /^\[/) {
          section = $0
          gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", section)
        } else if (section == "ColorScheme" && $0 ~ /^[[:space:]]*active_colors[[:space:]]*=/) {
          val = $0
          sub(/^[[:space:]]*active_colors[[:space:]]*=[[:space:]]*/, "", val)
          qt_colors = trim(val)
        }
      } else if (parser == "kde") {
        if ($0 ~ /^\[/) {
          section = $0
          gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", section)
        } else if ($0 ~ /=/) {
          eq = index($0, "=")
          k = trim(substr($0, 1, eq - 1))
          v = trim(substr($0, eq + 1))
          kde_map[section ":" k] = v
        }
      }
    }

    END {
      if (parser == "gtk") {
        bg = resolve_gtk("window_bg_color")
        surf = resolve_gtk("headerbar_bg_color")
        txt = resolve_gtk("window_fg_color")
        acc = resolve_gtk("accent_bg_color")
        acc_txt = resolve_gtk("accent_fg_color")
        if (bg == "" || surf == "" || txt == "" || acc == "" || acc_txt == "") exit 1
        emit_normalized(bg, surf, txt, acc, acc_txt, "")
      } else if (parser == "qt") {
        n = split(qt_colors, arr, ",")
        if (n < 17) exit 1
        # QPalette: Window(11), Button(2), WindowText(1), Highlight(13), HighlightedText(14), Mid(6) in 1-based indexing
        emit_normalized(arr[11], arr[2], arr[1], arr[13], arr[14], arr[6])
      } else if (parser == "kde") {
        bg = kde_map["Colors:Window:BackgroundNormal"]
        surf = kde_map["Colors:Header:BackgroundNormal"]
        if (surf == "") surf = kde_map["Colors:Button:BackgroundNormal"]
        txt = kde_map["Colors:Window:ForegroundNormal"]
        acc = kde_map["Colors:Selection:BackgroundNormal"]
        acc_txt = kde_map["Colors:Selection:ForegroundNormal"]
        if (bg == "" || surf == "" || txt == "" || acc == "" || acc_txt == "") exit 1
        emit_normalized(bg, surf, txt, acc, acc_txt, "")
      }
    }
  ' "$file_path"
}

# Read an INI key from a given [Section]
ini_get() {
  local file="$1"
  local target_section="$2"
  local target_key="$3"
  [[ -f "$file" ]] || return 1
  awk -v sec="$target_section" -v key="$target_key" '
    /^\[/ {
      s = $0
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", s)
      in_sec = (s == sec)
      next
    }
    in_sec && $0 ~ /^[[:space:]]*[^#;][^=]*=/ {
      eq = index($0, "=")
      k = substr($0, 1, eq - 1)
      v = substr($0, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (k == key) {
        val = v
      }
    }
    END {
      if (val != "") print val
      else exit 1
    }
  ' "$file"
}

# Discover and generate the desktop palette CSS.
# Sets GENERATED_CSS and DETECTED_SOURCE on success.
generate_desktop_palette() {
  local source="${1:-auto}"
  local cfg data
  cfg="$(config_root)"
  data="$(data_root)"

  case "$source" in
    auto|gtk|qt) ;;
    *) die "Unknown palette source: $source (expected auto, gtk, or qt)" ;;
  esac

  local out=""

  # 1. Try GTK (gtk-3.0, gtk-4.0)
  if [[ "$source" == "auto" || "$source" == "gtk" ]]; then
    local ver folder css noctalia colors_css
    for ver in 3.0 4.0; do
      folder="$cfg/gtk-$ver"
      css="$folder/gtk.css"
      noctalia="$folder/noctalia.css"
      colors_css="$folder/colors.css"

      if [[ "$source" == "gtk" ]]; then
        for candidate in "$noctalia" "$colors_css" "$css"; do
          if [[ -f "$candidate" ]] && out="$(extract_palette_from_file gtk "$candidate" 2>/dev/null)"; then
            GENERATED_CSS="$out"
            DETECTED_SOURCE="gtk${ver%%.*}"
            return 0
          fi
        done
      else
        # In auto mode, check imported noctalia.css / colors.css or direct @define-color in gtk.css
        if [[ -f "$css" ]]; then
          if grep -q "noctalia\.css" "$css" 2>/dev/null && [[ -f "$noctalia" ]]; then
            if out="$(extract_palette_from_file gtk "$noctalia" 2>/dev/null)"; then
              GENERATED_CSS="$out"
              DETECTED_SOURCE="gtk${ver%%.*}"
              return 0
            fi
          fi
          if grep -q "colors\.css" "$css" 2>/dev/null && [[ -f "$colors_css" ]]; then
            if out="$(extract_palette_from_file gtk "$colors_css" 2>/dev/null)"; then
              GENERATED_CSS="$out"
              DETECTED_SOURCE="gtk${ver%%.*}"
              return 0
            fi
          fi
          if grep -q "@define-color" "$css" 2>/dev/null; then
            if out="$(extract_palette_from_file gtk "$css" 2>/dev/null)"; then
              GENERATED_CSS="$out"
              DETECTED_SOURCE="gtk${ver%%.*}"
              return 0
            fi
          fi
        fi
      fi
    done
  fi

  # 2. Try Qt (qt6ct, qt5ct) and KDE (kdeglobals)
  if [[ "$source" == "auto" || "$source" == "qt" ]]; then
    local ver folder settings custom_pal scheme_path
    for ver in 6 5; do
      folder="$cfg/qt${ver}ct"
      settings="$folder/qt${ver}ct.conf"
      if [[ -f "$settings" ]]; then
        custom_pal="$(ini_get "$settings" "Appearance" "custom_palette" || true)"
        if [[ "${custom_pal,,}" == "true" || "$custom_pal" == "1" ]]; then
          scheme_path="$(ini_get "$settings" "Appearance" "color_scheme_path" || true)"
          if [[ -n "$scheme_path" ]]; then
            scheme_path="${scheme_path/#\~/$HOME}"
            [[ "$scheme_path" == /* ]] || scheme_path="$folder/$scheme_path"
            if [[ -f "$scheme_path" ]] && out="$(extract_palette_from_file qt "$scheme_path" 2>/dev/null)"; then
              GENERATED_CSS="$out"
              DETECTED_SOURCE="qt${ver}"
              return 0
            fi
          fi
        fi
      fi
    done

    local globals_path="$cfg/kdeglobals"
    if [[ -f "$globals_path" ]]; then
      local selected
      selected="$(ini_get "$globals_path" "General" "ColorScheme" || true)"
      if [[ -n "$selected" && "$selected" =~ ^[A-Za-z0-9_-]+$ ]]; then
        local kde_scheme="$data/color-schemes/${selected}.colors"
        if [[ -f "$kde_scheme" ]] && out="$(extract_palette_from_file kde "$kde_scheme" 2>/dev/null)"; then
          GENERATED_CSS="$out"
          DETECTED_SOURCE="kde"
          return 0
        fi
      fi
      # Fallback: KDE often writes [Colors:*] directly into kdeglobals
      if out="$(extract_palette_from_file kde "$globals_path" 2>/dev/null)"; then
        GENERATED_CSS="$out"
        DETECTED_SOURCE="kde"
        return 0
      fi
    fi
  fi

  return 1
}

atomic_write() {
  local target="$1"
  local content="$2"
  local dir
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  local tmp="${target}.browsermaxxing-tmp.$$"
  umask 077
  printf '%s\n' "$content" > "$tmp"
  mv -f "$tmp" "$target"
}

update_checksum() {
  local profile="$1"
  local rel_path="$2"
  local checksum_file="$profile/chrome/browsermaxxing/checksums.sha256"
  [[ -f "$checksum_file" ]] || return 0
  local full_path="$profile/$rel_path"
  [[ -f "$full_path" ]] || return 0

  local new_hash
  new_hash="$(sha256sum "$full_path" | awk '{print $1}')"
  local tmp="${checksum_file}.tmp.$$"
  awk -v rel="$rel_path" -v hash="$new_hash" '
    $2 == rel { print hash "  " rel; found = 1; next }
    { print }
    END { if (!found) print hash "  " rel }
  ' "$checksum_file" > "$tmp"
  mv -f "$tmp" "$checksum_file"
}

verify_managed_files() {
  local profile="$1"
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
      die "Managed file is missing: $rel_path. Reinstall or check profile."
    fi
    actual_hash="$(sha256sum "$full_path" | awk '{print $1}')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
      die "File was modified after installation: $rel_path. Back up your changes before syncing."
    fi
  done < "$checksum_file"
}

set_userchrome_palette_import() {
  local profile="$1"
  local mode="$2"
  local userchrome="$profile/chrome/userChrome.css"
  [[ -f "$userchrome" ]] || return 0
  [[ ! -L "$userchrome" ]] || die "Managed file is a symlink: $userchrome"

  local updated
  updated="$(sed -E "s|@import url\(\"browsermaxxing/palette-[a-z]+\.css\"\);|@import url(\"browsermaxxing/palette-${mode}.css\");|g" "$userchrome")"
  if [[ "$updated" != "$(cat "$userchrome")" ]]; then
    atomic_write "$userchrome" "$updated"
    update_checksum "$profile" "chrome/userChrome.css"
  fi
}

update_state_var() {
  local state_file="$1"
  local key="$2"
  local val="$3"
  [[ -f "$state_file" ]] || return 0
  local tmp="${state_file}.tmp.$$"
  awk -v k="$key" -v v="$val" '
    BEGIN { found = 0 }
    index($0, k "=") == 1 {
      print k "=" v
      found = 1
      next
    }
    { print }
    END {
      if (!found) print k "=" v
    }
  ' "$state_file" > "$tmp"
  mv -f "$tmp" "$state_file"
}

main() {
  local profile_arg=""
  local browser="librewolf"
  local source_arg=""
  local mode_arg=""
  local reset_default=0
  local default_mode="dark"
  local print_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--profile)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        profile_arg="$2"
        shift 2
        ;;
      -b|--browser)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        browser="$2"
        shift 2
        ;;
      --librewolf)
        browser="librewolf"
        shift
        ;;
      --firefox)
        browser="firefox"
        shift
        ;;
      -s|--source)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        source_arg="$2"
        shift 2
        ;;
      -m|--mode)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        mode_arg="$2"
        shift 2
        ;;
      -d|--default|--reset)
        reset_default=1
        if [[ $# -ge 2 && "$2" =~ ^(dark|light|auto)$ ]]; then
          default_mode="$2"
          shift 2
        else
          shift
        fi
        ;;
      --print-palette)
        print_only=1
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

  if (( print_only )); then
    local src="${source_arg:-auto}"
    if generate_desktop_palette "$src"; then
      printf '%s\n' "$GENERATED_CSS"
      exit 0
    else
      die "No supported active GTK/Qt export found."
    fi
  fi

  local profile
  profile="$(resolve_profile "$profile_arg" "$browser")"
  local bmx_dir="$profile/chrome/browsermaxxing"
  local state_file="$bmx_dir/state.env"

  if [[ ! -d "$bmx_dir" || ! -f "$state_file" ]]; then
    die "Browsermaxxing is not installed in profile: $profile. Run ./install.sh first."
  fi

  verify_managed_files "$profile"

  # Load saved state
  local saved_mode="desktop"
  local saved_source="auto"
  # shellcheck disable=SC1090
  source "$state_file"
  saved_mode="${BMX_MODE:-desktop}"
  saved_source="${BMX_SOURCE:-auto}"

  # Handle reset to default fallback palette
  if (( reset_default )); then
    mode_arg="$default_mode"
  fi

  if [[ -n "$mode_arg" ]]; then
    case "$mode_arg" in
      dark|light|auto)
        local fallback_css='/* Desktop palette is generated by install.sh or run.sh. */
@import url("palette-dark.css");'
        atomic_write "$bmx_dir/palette-desktop.css" "$fallback_css"
        update_checksum "$profile" "chrome/browsermaxxing/palette-desktop.css"
        set_userchrome_palette_import "$profile" "$mode_arg"
        update_state_var "$state_file" "BMX_MODE" "$mode_arg"
        printf 'Palette reset to fallback (%s). Reopen the browser to apply.\n' "$mode_arg"
        exit 0
        ;;
      desktop)
        saved_mode="desktop"
        ;;
      *)
        die "Unsupported mode: $mode_arg (expected desktop, dark, light, or auto)"
        ;;
    esac
  fi

  local active_source="${source_arg:-$saved_source}"
  if ! generate_desktop_palette "$active_source"; then
    die "No supported active GTK/Qt export found."
  fi

  local target_css="$bmx_dir/palette-desktop.css"
  local changed=1
  if [[ -f "$target_css" ]] && [[ "$(cat "$target_css")" == "$GENERATED_CSS" ]]; then
    changed=0
  fi

  if (( changed )); then
    atomic_write "$target_css" "$GENERATED_CSS"
    update_checksum "$profile" "chrome/browsermaxxing/palette-desktop.css"
  fi

  if [[ "$saved_mode" != "desktop" ]]; then
    set_userchrome_palette_import "$profile" "desktop"
    update_state_var "$state_file" "BMX_MODE" "desktop"
    changed=1
  fi
  update_state_var "$state_file" "BMX_SOURCE" "$active_source"

  if (( changed )); then
    printf 'Palette: %s. Updated; reopen the browser to load it.\n' "$DETECTED_SOURCE"
  else
    printf 'Palette: %s. Already up to date.\n' "$DETECTED_SOURCE"
  fi
}

main "$@"
