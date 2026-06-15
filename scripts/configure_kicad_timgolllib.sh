#!/usr/bin/env bash
# Configure KiCad to use TimGollLib symbols, footprints, and 3D models.
#
# Usage:
#   ./scripts/configure_kicad_timgolllib.sh
#   ./scripts/configure_kicad_timgolllib.sh --repo /path/to/kicad_libs
#   ./scripts/configure_kicad_timgolllib.sh --kicad-version 9.0 --dry-run
#
# Close KiCad before running; it may overwrite config files on exit.

set -euo pipefail

LIB_NAME="TimGollLib"
PATH_VAR="TIMGOLLLIB_FOOTPRINTS"
DRY_RUN=0
KICAD_VERSION=""
REPO_ROOT=""

usage() {
  cat <<'EOF'
Configure KiCad global libraries and 3D model path for TimGollLib.

Options:
  --repo PATH           Path to kicad_libs repository (default: repo root)
  --kicad-version VER   KiCad config version, e.g. 9.0 (default: auto-detect)
  --dry-run             Print actions without modifying files
  -h, --help            Show this help
EOF
}

log() {
  printf '[configure_kicad] %s\n' "$*"
}

warn() {
  printf '[configure_kicad] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[configure_kicad] ERROR: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a path"
      REPO_ROOT="$2"
      shift 2
      ;;
    --kicad-version)
      [[ $# -ge 2 ]] || die "--kicad-version requires a value"
      KICAD_VERSION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

SYMBOL_LIB="${REPO_ROOT}/${LIB_NAME}.kicad_sym"
FOOTPRINT_LIB="${REPO_ROOT}/${LIB_NAME}.pretty"
MODELS_DIR="${FOOTPRINT_LIB}/3d"

[[ -f "$SYMBOL_LIB" ]] || die "Symbol library not found: $SYMBOL_LIB"
[[ -d "$FOOTPRINT_LIB" ]] || die "Footprint library not found: $FOOTPRINT_LIB"
[[ -d "$MODELS_DIR" ]] || die "3D models directory not found: $MODELS_DIR"

detect_kicad_base_dir() {
  if [[ "$OSTYPE" == darwin* ]]; then
    printf '%s' "${HOME}/Library/Preferences/kicad"
  else
    printf '%s' "${HOME}/.config/kicad"
  fi
}

detect_kicad_version() {
  local base="$1"
  local latest=""

  [[ -d "$base" ]] || return 1

  while IFS= read -r dir; do
    local name
    name="$(basename "$dir")"
    if [[ "$name" =~ ^[0-9]+\.[0-9]+$ ]]; then
      latest="$name"
    fi
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d | sort -V)

  [[ -n "$latest" ]] || return 1
  printf '%s' "$latest"
}

KICAD_BASE="$(detect_kicad_base_dir)"
if [[ -z "$KICAD_VERSION" ]]; then
  KICAD_VERSION="$(detect_kicad_version "$KICAD_BASE" || true)"
fi
[[ -n "$KICAD_VERSION" ]] || die "Could not detect KiCad version under: $KICAD_BASE"

KICAD_CONFIG_DIR="${KICAD_BASE}/${KICAD_VERSION}"
SYM_TABLE="${KICAD_CONFIG_DIR}/sym-lib-table"
FP_TABLE="${KICAD_CONFIG_DIR}/fp-lib-table"
COMMON_JSON="${KICAD_CONFIG_DIR}/kicad_common.json"

[[ -d "$KICAD_CONFIG_DIR" ]] || die "KiCad config directory not found: $KICAD_CONFIG_DIR"
[[ -f "$SYM_TABLE" ]] || die "Symbol library table not found: $SYM_TABLE"
[[ -f "$FP_TABLE" ]] || die "Footprint library table not found: $FP_TABLE"
[[ -f "$COMMON_JSON" ]] || die "KiCad common settings not found: $COMMON_JSON"

backup_file() {
  local file="$1"
  local backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would back up: $file -> $backup"
  else
    cp "$file" "$backup"
    log "Backed up: $backup"
  fi
}

add_lib_table_entry() {
  local table_path="$1"
  local lib_name="$2"
  local lib_uri="$3"
  local lib_descr="$4"

  python3 - "$table_path" "$lib_name" "$lib_uri" "$lib_descr" "$DRY_RUN" <<'PY'
import re
import sys
from pathlib import Path

table_path, lib_name, lib_uri, lib_descr, dry_run = sys.argv[1:6]
dry_run = dry_run == "1"
content = Path(table_path).read_text(encoding="utf-8")

if re.search(rf'\(name "{re.escape(lib_name)}"\)', content):
    print(f"already-present:{lib_name}")
    sys.exit(0)

entry = (
    f'  (lib (name "{lib_name}")(type "KiCad")(uri "{lib_uri}")'
    f'(options "")(descr "{lib_descr}"))\n'
)

stripped = content.rstrip()
if not stripped.endswith(")"):
    raise SystemExit(f"Unexpected library table format: {table_path}")

updated = stripped[:-1] + entry + ")\n"

if dry_run:
    print(f"would-add:{lib_name}")
else:
    Path(table_path).write_text(updated, encoding="utf-8")
    print(f"added:{lib_name}")
PY
}

set_path_variable() {
  local json_path="$1"
  local var_name="$2"
  local var_value="$3"

  python3 - "$json_path" "$var_name" "$var_value" "$DRY_RUN" <<'PY'
import json
import sys
from pathlib import Path

json_path, var_name, var_value, dry_run = sys.argv[1:5]
dry_run = dry_run == "1"

path = Path(json_path)
data = json.loads(path.read_text(encoding="utf-8"))

environment = data.setdefault("environment", {})
vars_obj = environment.get("vars")
if vars_obj is None:
    vars_obj = {}
    environment["vars"] = vars_obj

current = vars_obj.get(var_name)
if current == var_value:
    print(f"already-set:{var_name}")
    sys.exit(0)

vars_obj[var_name] = var_value

if dry_run:
    print(f"would-set:{var_name}={var_value}")
else:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(f"set:{var_name}={var_value}")
PY
}

log "Repository: $REPO_ROOT"
log "KiCad config: $KICAD_CONFIG_DIR"
log "Symbol library: $SYMBOL_LIB"
log "Footprint library: $FOOTPRINT_LIB"
log "3D models path: $MODELS_DIR"

if [[ "$DRY_RUN" -eq 0 ]]; then
  warn "Close KiCad before continuing; unsaved KiCad settings may overwrite these changes."
fi

backup_file "$SYM_TABLE"
backup_file "$FP_TABLE"
backup_file "$COMMON_JSON"

sym_result="$(add_lib_table_entry \
  "$SYM_TABLE" \
  "$LIB_NAME" \
  "$SYMBOL_LIB" \
  "TimGollLib custom symbols")"

fp_result="$(add_lib_table_entry \
  "$FP_TABLE" \
  "$LIB_NAME" \
  "$FOOTPRINT_LIB" \
  "TimGollLib custom footprints")"

path_result="$(set_path_variable \
  "$COMMON_JSON" \
  "$PATH_VAR" \
  "$MODELS_DIR")"

case "$sym_result" in
  added:*) log "Added symbol library to sym-lib-table." ;;
  would-add:*) log "Would add symbol library to sym-lib-table." ;;
  already-present:*) log "Symbol library already present in sym-lib-table." ;;
  *) die "Unexpected sym-lib-table result: $sym_result" ;;
esac

case "$fp_result" in
  added:*) log "Added footprint library to fp-lib-table." ;;
  would-add:*) log "Would add footprint library to fp-lib-table." ;;
  already-present:*) log "Footprint library already present in fp-lib-table." ;;
  *) die "Unexpected fp-lib-table result: $fp_result" ;;
esac

case "$path_result" in
  set:*) log "Updated ${PATH_VAR} in kicad_common.json." ;;
  would-set:*) log "Would update ${PATH_VAR} in kicad_common.json." ;;
  already-set:*) log "${PATH_VAR} already set in kicad_common.json." ;;
  *) die "Unexpected kicad_common.json result: $path_result" ;;
esac

log "Done. Restart KiCad to load the updated configuration."
