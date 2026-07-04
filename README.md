# photo-geotag-macos

Tool Bash per macOS per geotaggare foto con GPX usando ExifTool, con due modalità:

- **Interattiva (popup)** via `osascript`
- **CLI non interattiva** per automazione/script

Include anche uno script opzionale per allineare `FileCreateDate` e `FileModifyDate` a `DateTimeOriginal`.

## Prerequisiti

- macOS recente
- Bash
- [ExifTool](https://exiftool.org/)

Installazione ExifTool (Homebrew):

```bash
brew install exiftool
```

Verifica:

```bash
exiftool -ver
```

## File principali

- `geotag.sh` → geotagging GPX (popup + CLI)
- `align_fs_dates.sh` → allineamento date filesystem da EXIF (opzionale)

## Uso rapido

Rendi eseguibili gli script:

```bash
chmod +x geotag.sh align_fs_dates.sh
```

### Modalità popup (interattiva)

```bash
./geotag.sh --interactive
```

Ti guiderà con popup per:

1. selezione cartella foto
2. selezione file GPX
3. estensioni (default `ARW,DNG,HEIC,heic`)
4. ricorsivo sì/no
5. `geoMaxExtSecs` (default `3600`)
6. dry-run sì/no
7. conferma prima di eseguire

### Modalità CLI non interattiva

```bash
./geotag.sh "/path/foto" "/path/track.gpx" --ext ARW,DNG,HEIC --recursive --geo-max-ext-secs 3600
```

Opzioni utili:

- `--dry-run` → stampa comandi senza modificare file
- `--preview` / `--no-preview` → mostra/nasconde comando base prima del run
- `--yes` → salta conferma interattiva

## Esempi reali

Geotag ricorsivo con preview + conferma:

```bash
./geotag.sh "/Volumes/Foto/Trip-2026" "/Volumes/Tracks/2026-06-10.gpx" --ext ARW,DNG,HEIC,heic --recursive --geo-max-ext-secs 3600
```

Solo anteprima (nessuna modifica):

```bash
./geotag.sh "/Volumes/Foto/Trip-2026" "/Volumes/Tracks/2026-06-10.gpx" --dry-run --recursive
```

## Script opzionale: allineamento date filesystem

Allinea:

- `FileCreateDate <- DateTimeOriginal`
- `FileModifyDate <- DateTimeOriginal`

Dry-run:

```bash
./align_fs_dates.sh "/Volumes/Foto/Trip-2026" --ext ARW,DNG,HEIC,heic --recursive --dry-run
```

Esecuzione reale (con conferma):

```bash
./align_fs_dates.sh "/Volumes/Foto/Trip-2026" --recursive
```

## Logging e riepilogo

Entrambi gli script scrivono log timestampato in:

- `./logs/geotag_YYYYMMDD_HHMMSS.log`
- `./logs/align_fs_dates_YYYYMMDD_HHMMSS.log`

Riepilogo finale include:

- numero file trovati
- successo
- falliti
- percorso log

## Troubleshooting

### `exiftool non trovato`

Installa con:

```bash
brew install exiftool
```

### `File GPX non valido`

- verifica che il file esista
- controlla che sia XML GPX valido
- se possibile, prova ad aprirlo in un editor e verifica presenza del tag `<gpx>`

### Nessun file trovato

- controlla `--ext`
- verifica `--recursive` se i file sono in sottocartelle
- i match estensione sono **case-insensitive** (`.HEIC` e `.heic` sono entrambi supportati)

### Terminale non interattivo + conferma

In CI/script non interattivo usa:

```bash
--yes
```

oppure:

```bash
--dry-run
```

## Test manuale minimo consigliato

1. Crea una cartella test con 2-3 foto (`.HEIC` e `.heic` incluse) e un file GPX valido.
2. Esegui dry-run:

   ```bash
   ./geotag.sh "/path/test-foto" "/path/test-track.gpx" --ext HEIC,heic --dry-run --recursive
   ```

3. Verifica nel log il comando generato e i file target.
4. Esegui run reale con preview e conferma.
5. Verifica un file a campione:

   ```bash
   exiftool -gps:all "/path/test-foto/file.heic"
   ```

## Note di sicurezza

- Usa sempre prima `--dry-run` su nuovi set foto.
- Il tool mostra il comando base prima dell'esecuzione (preview) per ridurre rischi operativi.

## Licenza

MIT
