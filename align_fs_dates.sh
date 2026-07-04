#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_EXTENSIONS="ARW,DNG,HEIC,heic"
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"

PHOTO_DIR=""
EXTENSIONS="$DEFAULT_EXTENSIONS"
RECURSIVE=0
DRY_RUN=0
ASSUME_YES=0

LOG_FILE=""
TOTAL_FILES=0
SUCCESS_FILES=0
FAILED_FILES=0

usage() {
  cat <<'EOF'
Uso:
  ./align_fs_dates.sh "/path/foto" [opzioni]

Opzioni:
  --ext LISTA        Estensioni CSV (default: ARW,DNG,HEIC,heic)
  --recursive        Cerca file in modo ricorsivo
  --dry-run          Mostra i comandi senza eseguire modifiche
  --yes              Nessuna conferma interattiva
  --help             Mostra aiuto
EOF
}

ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(ts)" "$level" "$*" | tee -a "$LOG_FILE"
}

die() {
  local msg="$1"
  if [[ -n "$LOG_FILE" ]]; then
    log "ERROR" "$msg"
  else
    printf 'ERROR: %s\n' "$msg" >&2
  fi
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

command_to_string() {
  local output=""
  local token
  for token in "$@"; do
    output+="$(printf '%q ' "$token")"
  done
  printf '%s' "${output% }"
}

init_log() {
  mkdir -p "$LOG_DIR" || die "Impossibile creare directory log: $LOG_DIR"
  LOG_FILE="$LOG_DIR/align_fs_dates_$(date '+%Y%m%d_%H%M%S').log"
  : > "$LOG_FILE" || die "Impossibile scrivere log: $LOG_FILE"
}

validate_inputs() {
  command -v exiftool >/dev/null 2>&1 || die "exiftool non trovato. Installa con: brew install exiftool"
  [[ -n "$PHOTO_DIR" ]] || die "Cartella foto non specificata"
  [[ -d "$PHOTO_DIR" ]] || die "Cartella foto non valida: $PHOTO_DIR"
}

collect_files() {
  local find_cmd=(find "$PHOTO_DIR")
  local raw_ext
  local ext
  local parts=()

  IFS=',' read -r -a parts <<< "$EXTENSIONS"

  if [[ "$RECURSIVE" -eq 0 ]]; then
    find_cmd+=( -maxdepth 1 )
  fi

  find_cmd+=( -type f \( )
  local added=0
  for raw_ext in "${parts[@]}"; do
    ext="$(trim "$raw_ext")"
    ext="${ext#.}"
    if [[ -n "$ext" ]]; then
      if [[ "$added" -eq 1 ]]; then
        find_cmd+=( -o )
      fi
      find_cmd+=( -iname "*.${ext}" )
      added=1
    fi
  done
  find_cmd+=( \) -print0 )

  [[ "$added" -eq 1 ]] || die "Nessuna estensione valida in --ext"

  FILES=()
  local file
  while IFS= read -r -d '' file; do
    FILES+=("$file")
  done < <("${find_cmd[@]}")

  TOTAL_FILES="${#FILES[@]}"
  (( TOTAL_FILES > 0 )) || die "Nessun file trovato"
}

ask_confirmation() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  if [[ ! -t 0 ]]; then
    die "Terminale non interattivo: usa --yes o --dry-run"
  fi
  printf 'Allineare FileCreateDate/FileModifyDate da DateTimeOriginal? [y/N]: '
  local answer
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

run_alignment() {
  local file
  local cmd
  local output
  local status

  for file in "${FILES[@]}"; do
    cmd=(
      exiftool
      -overwrite_original
      '-FileCreateDate<DateTimeOriginal'
      '-FileModifyDate<DateTimeOriginal'
      "$file"
    )

    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRYRUN" "$(command_to_string "${cmd[@]}")"
      SUCCESS_FILES=$((SUCCESS_FILES + 1))
      continue
    fi

    output="$("${cmd[@]}" 2>&1)"
    status=$?

    if [[ -n "$output" ]]; then
      while IFS= read -r line; do
        log "EXIF" "$line"
      done <<< "$output"
    fi

    if [[ "$status" -eq 0 ]]; then
      SUCCESS_FILES=$((SUCCESS_FILES + 1))
    else
      FAILED_FILES=$((FAILED_FILES + 1))
      log "ERROR" "Errore su file: $file"
    fi
  done
}

show_summary() {
  log "INFO" "Riepilogo finale"
  log "INFO" "Totale file: $TOTAL_FILES"
  log "INFO" "Successo: $SUCCESS_FILES"
  log "INFO" "Falliti: $FAILED_FILES"
  log "INFO" "Log salvato in: $LOG_FILE"
}

parse_args() {
  [[ "$#" -gt 0 ]] || {
    usage
    exit 1
  }

  if [[ "${1#-}" == "$1" ]]; then
    PHOTO_DIR="$1"
    shift
  fi

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --ext)
        [[ "$#" -ge 2 ]] || die "Valore mancante per --ext"
        EXTENSIONS="$2"
        shift 2
        ;;
      --recursive)
        RECURSIVE=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Argomento non riconosciuto: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  init_log
  validate_inputs
  collect_files

  log "INFO" "Comando base: $(command_to_string exiftool -overwrite_original '-FileCreateDate<DateTimeOriginal' '-FileModifyDate<DateTimeOriginal' '<FILE>')"
  log "INFO" "Estensioni: $EXTENSIONS"
  log "INFO" "Ricorsivo: $([[ "$RECURSIVE" -eq 1 ]] && printf 'sì' || printf 'no')"
  log "INFO" "File trovati: $TOTAL_FILES"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    ask_confirmation || die "Operazione annullata dall'utente"
  fi

  run_alignment
  show_summary

  if [[ "$FAILED_FILES" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
