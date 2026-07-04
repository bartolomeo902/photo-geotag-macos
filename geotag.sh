#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_EXTENSIONS="ARW,DNG,HEIC,heic"
DEFAULT_GEO_MAX_EXT_SECS=3600
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"

PHOTO_DIR=""
GPX_INPUT=""
declare -a GPX_FILES=()
EXTENSIONS="$DEFAULT_EXTENSIONS"
GEO_MAX_EXT_SECS="$DEFAULT_GEO_MAX_EXT_SECS"
RECURSIVE=0
DRY_RUN=0
PREVIEW=1
ASSUME_YES=0
INTERACTIVE=0
ONLY_UNTAGGED=0

LOG_FILE=""
TOTAL_FILES=0
SUCCESS_FILES=0
FAILED_FILES=0
PROCESSED_FILES=0
SKIPPED_ALREADY_GEOTAGGED=0

usage() {
  cat <<'EOF'
Uso:
  ./geotag.sh "/path/foto" "/path/track1.gpx,/path/track2.gpx" [opzioni]
  ./geotag.sh --interactive

Opzioni:
  --gpx FILE                  Aggiunge un file GPX (opzione ripetibile)
  --gpx-files LISTA           Lista GPX separati da virgola
  --ext LISTA                Estensioni separate da virgola (default: ARW,DNG,HEIC,heic)
  --recursive                Cerca file in modo ricorsivo
  --geo-max-ext-secs NUM     Valore GeoMaxExtSecs (default: 3600)
  --only-untagged            Processa solo foto senza metadati GPS
  --include-already-geotagged Include anche foto già geotaggate
  --dry-run                  Mostra cosa verrebbe eseguito, senza modificare file
  --preview                  Mostra comando prima dell'esecuzione (default)
  --no-preview               Salta preview del comando
  --yes                      Non chiedere conferma prima dell'esecuzione
  --interactive              Avvia popup macOS (osascript)
  --help                     Mostra questo aiuto

Esempio:
  ./geotag.sh "/path/foto" --gpx "/path/day1.gpx" --gpx "/path/day2.gpx" --only-untagged --ext ARW,DNG,HEIC --recursive --geo-max-ext-secs 3600
EOF
}

ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  local level="$1"
  shift
  local msg="$*"
  printf '[%s] [%s] %s\n' "$(ts)" "$level" "$msg" | tee -a "$LOG_FILE"
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

validate_number() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]]
}

contains_value() {
  local seek="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$seek" ]]; then
      return 0
    fi
  done
  return 1
}

add_gpx_file() {
  local raw="$1"
  local gpx
  gpx="$(trim "$raw")"
  [[ -n "$gpx" ]] || return 0

  if ! contains_value "$gpx" "${GPX_FILES[@]-}"; then
    GPX_FILES+=("$gpx")
  fi
}

parse_gpx_input_csv() {
  local input="$1"
  local parts=()
  local part

  [[ -n "$input" ]] || return 0
  IFS=',' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    add_gpx_file "$part"
  done
}

init_log() {
  mkdir -p "$LOG_DIR" || die "Impossibile creare la directory log: $LOG_DIR"
  LOG_FILE="$LOG_DIR/geotag_$(date '+%Y%m%d_%H%M%S').log"
  : > "$LOG_FILE" || die "Impossibile scrivere il log: $LOG_FILE"
}

validate_dependencies() {
  command -v exiftool >/dev/null 2>&1 || die "exiftool non trovato. Installa con: brew install exiftool"
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    command -v osascript >/dev/null 2>&1 || die "osascript non disponibile su questo sistema"
  fi
}

validate_paths() {
  local gpx

  [[ -n "$PHOTO_DIR" ]] || die "Cartella foto non specificata"
  [[ -d "$PHOTO_DIR" ]] || die "Cartella foto non valida: $PHOTO_DIR"
  [[ -r "$PHOTO_DIR" ]] || die "Cartella foto non leggibile: $PHOTO_DIR"

  ((${#GPX_FILES[@]} > 0)) || die "Nessun file GPX specificato"

  for gpx in "${GPX_FILES[@]}"; do
    [[ -f "$gpx" ]] || die "File GPX non trovato: $gpx"
    [[ -r "$gpx" ]] || die "File GPX non leggibile: $gpx"

    if command -v xmllint >/dev/null 2>&1; then
      xmllint --noout "$gpx" >/dev/null 2>&1 || die "File GPX non valido (XML malformato): $gpx"
    elif ! grep -qi '<gpx' "$gpx"; then
      die "Impossibile validare GPX con xmllint e tag <gpx> non trovato: $gpx"
    fi
  done
}

collect_files() {
  local find_cmd=(find "$PHOTO_DIR")
  local parts=()
  local raw_ext
  local ext

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

  [[ "$added" -eq 1 ]] || die "Nessuna estensione valida trovata in --ext"

  FILES=()
  local file
  while IFS= read -r -d '' file; do
    FILES+=("$file")
  done < <("${find_cmd[@]}")

  TOTAL_FILES="${#FILES[@]}"
  (( TOTAL_FILES > 0 )) || die "Nessun file trovato con estensioni: $EXTENSIONS"
}

ask_confirmation_cli() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0

  if [[ ! -t 0 ]]; then
    die "Terminale non interattivo: usa --yes oppure --dry-run"
  fi

  printf "Procedere con l'esecuzione? [y/N]: "
  local answer
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

ask_confirmation_popup() {
  local result
  result="$({
    osascript <<'OSA'
button returned of (display dialog "Confermi l'esecuzione del geotagging?" buttons {"Annulla","Esegui"} default button "Esegui")
OSA
  } 2>/dev/null || true)"
  [[ "$result" == "Esegui" ]]
}

render_preview() {
  local gpx
  local dollar_sign
  local gps_filter_expr
  dollar_sign="$(printf '\044')"
  gps_filter_expr="not ${dollar_sign}GPS:all"
  local base_cmd=(
    exiftool
    -overwrite_original
    -api "GeoMaxExtSecs=${GEO_MAX_EXT_SECS}"
  )

  if [[ "$ONLY_UNTAGGED" -eq 1 ]]; then
    base_cmd+=( -if "$gps_filter_expr" )
  fi

  for gpx in "${GPX_FILES[@]}"; do
    base_cmd+=( -geotag "$gpx" )
  done
  base_cmd+=( "<FILE>" )

  log "INFO" "Comando base geotag: $(command_to_string "${base_cmd[@]}")"
  log "INFO" "Modalità ricorsiva: $([[ "$RECURSIVE" -eq 1 ]] && printf 'sì' || printf 'no')"
  log "INFO" "Estensioni: $EXTENSIONS"
  log "INFO" "GPX selezionati: ${#GPX_FILES[@]}"
  for gpx in "${GPX_FILES[@]}"; do
    log "INFO" "  - $gpx"
  done
  log "INFO" "Solo non geotaggate: $([[ "$ONLY_UNTAGGED" -eq 1 ]] && printf 'sì' || printf 'no')"
  log "INFO" "File trovati: $TOTAL_FILES"
}

is_already_geotagged() {
  local file="$1"
  local dollar_sign
  local gps_presence_expr
  dollar_sign="$(printf '\044')"
  gps_presence_expr="${dollar_sign}GPS:all"
  local match
  match="$(exiftool -q -q -s3 -if "$gps_presence_expr" -filename "$file" 2>/dev/null || true)"
  [[ -n "$match" ]]
}

run_geotagging() {
  local file
  local gpx
  local output
  local status
  local cmd

  for file in "${FILES[@]}"; do
    if [[ "$ONLY_UNTAGGED" -eq 1 ]] && is_already_geotagged "$file"; then
      SKIPPED_ALREADY_GEOTAGGED=$((SKIPPED_ALREADY_GEOTAGGED + 1))
      log "SKIP" "File già geotaggato, salto: $file"
      continue
    fi

    cmd=(
      exiftool
      -overwrite_original
      -api "GeoMaxExtSecs=${GEO_MAX_EXT_SECS}"
    )

    for gpx in "${GPX_FILES[@]}"; do
      cmd+=( -geotag "$gpx" )
    done
    cmd+=( "$file" )

    PROCESSED_FILES=$((PROCESSED_FILES + 1))

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
  log "INFO" "Da processare (dopo filtri): $PROCESSED_FILES"
  log "INFO" "Saltati (già geotaggati): $SKIPPED_ALREADY_GEOTAGGED"
  log "INFO" "Successo: $SUCCESS_FILES"
  log "INFO" "Falliti: $FAILED_FILES"
  log "INFO" "Log salvato in: $LOG_FILE"
}

collect_interactive_inputs() {
  local selected_gpx_raw

  PHOTO_DIR="$(osascript -e 'POSIX path of (choose folder with prompt "Seleziona cartella foto")' 2>/dev/null || true)"
  [[ -n "$PHOTO_DIR" ]] || die "Operazione annullata: cartella foto non selezionata"

  selected_gpx_raw="$({
    osascript <<'OSA'
set selectedFiles to choose file with prompt "Seleziona uno o più file GPX" with multiple selections allowed
set out to ""
repeat with f in selectedFiles
  set out to out & POSIX path of f & linefeed
end repeat
return out
OSA
  } 2>/dev/null || true)"
  [[ -n "$selected_gpx_raw" ]] || die "Operazione annullata: nessun file GPX selezionato"

  local gpx_line
  while IFS= read -r gpx_line; do
    add_gpx_file "$gpx_line"
  done <<< "$selected_gpx_raw"

  EXTENSIONS="$(osascript -e 'text returned of (display dialog "Estensioni da processare (CSV)" default answer "ARW,DNG,HEIC,heic")' 2>/dev/null || true)"
  [[ -n "$EXTENSIONS" ]] || EXTENSIONS="$DEFAULT_EXTENSIONS"

  local recursive_choice
  recursive_choice="$(osascript -e 'choose from list {"Sì","No"} with prompt "Ricorsivo?" default items {"Sì"}' 2>/dev/null || true)"
  if [[ "$recursive_choice" == *"Sì"* ]]; then
    RECURSIVE=1
  fi

  GEO_MAX_EXT_SECS="$(osascript -e 'text returned of (display dialog "GeoMaxExtSecs" default answer "3600")' 2>/dev/null || true)"
  [[ -n "$GEO_MAX_EXT_SECS" ]] || GEO_MAX_EXT_SECS="$DEFAULT_GEO_MAX_EXT_SECS"

  local dry_choice
  dry_choice="$(osascript -e 'choose from list {"No","Sì"} with prompt "Dry-run (solo preview)?" default items {"No"}' 2>/dev/null || true)"
  if [[ "$dry_choice" == *"Sì"* ]]; then
    DRY_RUN=1
  fi

  local only_untagged_choice
  only_untagged_choice="$(osascript -e 'choose from list {"Sì","No"} with prompt "Geotaggare solo foto non geotaggate?" default items {"Sì"}' 2>/dev/null || true)"
  if [[ "$only_untagged_choice" == *"Sì"* ]]; then
    ONLY_UNTAGGED=1
  fi
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --gpx)
        [[ "$#" -ge 2 ]] || die "Valore mancante per --gpx"
        add_gpx_file "$2"
        shift 2
        ;;
      --gpx-files)
        [[ "$#" -ge 2 ]] || die "Valore mancante per --gpx-files"
        parse_gpx_input_csv "$2"
        shift 2
        ;;
      --ext)
        [[ "$#" -ge 2 ]] || die "Valore mancante per --ext"
        EXTENSIONS="$2"
        shift 2
        ;;
      --recursive)
        RECURSIVE=1
        shift
        ;;
      --geo-max-ext-secs)
        [[ "$#" -ge 2 ]] || die "Valore mancante per --geo-max-ext-secs"
        GEO_MAX_EXT_SECS="$2"
        shift 2
        ;;
      --only-untagged)
        ONLY_UNTAGGED=1
        shift
        ;;
      --include-already-geotagged)
        ONLY_UNTAGGED=0
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        PREVIEW=1
        shift
        ;;
      --preview)
        PREVIEW=1
        shift
        ;;
      --no-preview)
        PREVIEW=0
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --interactive)
        INTERACTIVE=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        if [[ "${1#-}" != "$1" ]]; then
          die "Argomento non riconosciuto: $1"
        fi

        if [[ -z "$PHOTO_DIR" ]]; then
          PHOTO_DIR="$1"
        elif [[ -z "$GPX_INPUT" ]]; then
          GPX_INPUT="$1"
        else
          die "Argomento posizionale inatteso: $1"
        fi
        shift
        ;;
    esac
  done

  parse_gpx_input_csv "$GPX_INPUT"

  if [[ -z "$PHOTO_DIR" || ${#GPX_FILES[@]} -eq 0 ]]; then
    INTERACTIVE=1
  fi
}

main() {
  parse_args "$@"

  init_log
  validate_dependencies

  if [[ "$INTERACTIVE" -eq 1 ]]; then
    collect_interactive_inputs
  fi

  validate_number "$GEO_MAX_EXT_SECS" || die "geoMaxExtSecs deve essere un intero >= 0"

  validate_paths
  collect_files

  if [[ "$PREVIEW" -eq 1 ]]; then
    render_preview

    if [[ "$DRY_RUN" -eq 0 ]]; then
      if [[ "$INTERACTIVE" -eq 1 ]]; then
        ask_confirmation_popup || die "Esecuzione annullata dall'utente"
      else
        ask_confirmation_cli || die "Esecuzione annullata dall'utente"
      fi
    fi
  fi

  run_geotagging
  show_summary

  if [[ "$FAILED_FILES" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
