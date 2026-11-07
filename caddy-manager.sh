#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
#  caddy-manager – interaktive Verwaltung von Caddy (Domains, Proxys, Weiterleitungen …)
#
#  Aufruf:
#     sudo ./caddy-manager.sh                 # Menü
#     sudo ./caddy-manager.sh help            # Kommandozeilen-Modus anzeigen
#
#  Arbeitsweise:
#     • Jede Domain bekommt eine eigene Datei in  /etc/caddy/conf.d/<domain>.caddy
#     • Die Haupt-Caddyfile enthält nur noch  `import /etc/caddy/conf.d/*.caddy`
#     • Vor jeder Änderung wird ein Backup angelegt, danach `caddy validate`
#       ausgeführt. Ist die Konfiguration ungültig, wird automatisch zurückgerollt.
#     • Deaktivierte Seiten heißen  *.caddy.disabled  und werden nicht geladen.
#
#  Umgebungsvariablen (optional):
#     CADDY_DIR   (Standard /etc/caddy)      CADDYFILE  (Standard $CADDY_DIR/Caddyfile)
#     SITES_DIR   (Standard $CADDY_DIR/conf.d)  BACKUP_DIR (Standard $CADDY_DIR/backups)
#     CM_NO_SUDO=1  nicht automatisch per sudo neu starten
# ──────────────────────────────────────────────────────────────────────────────
set -o pipefail

VERSION="1.1.0"
CADDY_DIR="${CADDY_DIR:-/etc/caddy}"
CADDYFILE="${CADDYFILE:-$CADDY_DIR/Caddyfile}"
SITES_DIR="${SITES_DIR:-$CADDY_DIR/conf.d}"
BACKUP_DIR="${BACKUP_DIR:-$CADDY_DIR/backups}"
LOG_DIR="${LOG_DIR:-/var/log/caddy}"
CERT_DIR="${CERT_DIR:-/var/lib/caddy/.local/share/caddy/certificates}"
SERVICE="${SERVICE:-caddy}"
MARKER="# --- Regeln ---"
GLOBAL_BEGIN="# BEGIN caddy-manager global"
GLOBAL_END="# END caddy-manager global"
MAX_BACKUPS=30

# ── Farben ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'; C_REV=$'\e[7m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_REV=""
fi

# ── Kleine Helfer ─────────────────────────────────────────────────────────────
ok()   { printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '  %s✘%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
info() { printf '  %s•%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
hr()   { printf '%s  ──────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"; }
have() { command -v "$1" >/dev/null 2>&1; }
clear_screen() { [[ -t 1 ]] && printf '\e[H\e[2J' || true; }

pause() {
  [[ -t 0 ]] || return 0
  printf '\n  %sWeiter mit beliebiger Taste …%s' "$C_DIM" "$C_RESET"
  read -rsn1 _
  echo
}

confirm() { # confirm "Frage" [j|n]  → 0 = ja
  local q=$1 def=${2:-n} hint ans
  [[ $def == j ]] && hint="J/n" || hint="j/N"
  read -r -p "  ${q} [${hint}] " ans || return 1
  ans=${ans:-$def}
  [[ $ans =~ ^[jJyY] ]]
}

ask() { # ask VARNAME "Frage" [Vorgabe]
  local __var=$1 q=$2 def=${3:-} ans
  if [[ -t 0 ]]; then
    read -r -e -i "$def" -p "  ${q}: " ans || return 1
  else
    read -r -p "  ${q}: " ans || return 1
    ans=${ans:-$def}
  fi
  printf -v "$__var" '%s' "$ans"
}

ask_secret() { # ask_secret VARNAME "Frage"
  local __var=$1 q=$2 ans
  read -r -s -p "  ${q}: " ans || return 1
  echo
  printf -v "$__var" '%s' "$ans"
}

esc() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }

banner() {
  clear_screen
  printf '\n%s  ╭─ %s🌐 Caddy-Manager%s %sv%s%s\n' "$C_CYAN$C_BOLD" "" "$C_RESET" "$C_DIM" "$VERSION" "$C_RESET"
  printf '%s  │%s  %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "${1:-}" "$C_RESET"
  printf '%s  ╰──────────────────────────────────────────────────────────%s\n' "$C_CYAN" "$C_RESET"
}

# ── Menü (Pfeiltasten, Zahlen, j/k, Enter, q) ────────────────────────────────
# Aufruf: menu "Titel" "Punkt 1" "Punkt 2" …   → Ergebnis in MENU_IDX (0-basiert, -1 = abgebrochen)
MENU_IDX=-1
menu() {
  local title=$1; shift
  local items=("$@") n=$# sel=0 key i
  MENU_IDX=-1
  if [[ ! -t 0 ]]; then            # Fallback ohne Terminal (z. B. Tests): Nummer einlesen
    for ((i = 0; i < n; i++)); do printf '  %2d) %s\n' $((i + 1)) "${items[i]}"; done
    read -r -p "  Auswahl: " key || return 1
    [[ $key =~ ^[0-9]+$ ]] && ((key >= 1 && key <= n)) && MENU_IDX=$((key - 1))
    return 0
  fi
  have tput && tput civis 2>/dev/null
  trap 'have tput && tput cnorm 2>/dev/null' RETURN
  while true; do
    banner "$title"
    status_line
    echo
    for ((i = 0; i < n; i++)); do
      if ((i == sel)); then
        printf '   %s▶ %-2s %s %s\n' "$C_REV$C_BOLD" "$((i + 1))" "${items[i]}" "$C_RESET"
      else
        printf '     %s%-2s%s %s\n' "$C_DIM" "$((i + 1))" "$C_RESET" "${items[i]}"
      fi
    done
    printf '\n  %s↑/↓ wählen · Enter bestätigen · Zahl direkt · q zurück%s\n' "$C_DIM" "$C_RESET"
    IFS= read -rsn1 key || return 1
    case $key in
      $'\e') read -rsn2 -t 0.05 key
             case $key in '[A') ((sel = (sel + n - 1) % n)) ;; '[B') ((sel = (sel + 1) % n)) ;; esac ;;
      k) ((sel = (sel + n - 1) % n)) ;;
      j) ((sel = (sel + 1) % n)) ;;
      q|Q) MENU_IDX=-1; return 0 ;;
      '') MENU_IDX=$sel; return 0 ;;
      [1-9]) if ((key <= n)); then MENU_IDX=$((key - 1)); return 0; fi ;;
    esac
  done
}

status_line() {
  local state="unbekannt" color=$C_YELLOW count
  if ! have caddy; then
    state="Caddy nicht installiert"; color=$C_RED
  elif have systemctl && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    state="läuft"; color=$C_GREEN
  elif have systemctl; then
    state="gestoppt"; color=$C_RED
  fi
  count=$(site_files | wc -l)
  printf '  Dienst: %s%s%s  ·  Seiten: %s%s%s  ·  %s%s%s\n' \
    "$color" "$state" "$C_RESET" "$C_BOLD" "$count" "$C_RESET" "$C_DIM" "$SITES_DIR" "$C_RESET"
}

# ── Rechte / Voraussetzungen ──────────────────────────────────────────────────
ensure_root() {
  [[ -n ${CM_NO_SUDO:-} ]] && return 0
  if [[ $EUID -ne 0 ]]; then
    if have sudo; then
      info "Root-Rechte nötig – starte neu mit sudo …"
      exec sudo -E CM_NO_SUDO=1 bash "$0" "$@"
    fi
    err "Bitte als root ausführen."; exit 1
  fi
}

ensure_dirs() { mkdir -p "$SITES_DIR" "$BACKUP_DIR"; }

# ── Dateien & Seiten ──────────────────────────────────────────────────────────
site_files() { # gibt alle verwalteten Dateien aus (aktiv + deaktiviert)
  local f
  shopt -s nullglob
  for f in "$SITES_DIR"/*.caddy "$SITES_DIR"/*.caddy.disabled; do printf '%s\n' "$f"; done
  shopt -u nullglob
}

site_name()   { local b; b=$(basename "$1"); b=${b%.disabled}; printf '%s' "${b%.caddy}"; }
site_active() { [[ $1 == *.disabled ]] && return 1 || return 0; }
site_type()   { sed -n 's/^# type: *//p' "$1" | head -1; }
site_addr()   { grep -m1 -E '\{[[:space:]]*$' "$1" | sed 's/[[:space:]]*{[[:space:]]*$//'; }
site_target() {
  local f=$1 t
  case $(site_type "$f") in
    proxy)       t=$(grep -m1 -E '^\s*reverse_proxy' "$f" | sed -E 's/^\s*reverse_proxy\s+//; s/\s*\{$//') ;;
    redirect)    t=$(grep -m1 -E '^\s*redir ' "$f" | sed -E 's/^\s*redir\s+//') ;;
    static)      t=$(grep -m1 -E '^\s*root ' "$f" | sed -E 's/^\s*root\s+\*\s+//') ;;
    maintenance) t="Wartungsseite (503)" ;;
    *)           t="(extern/benutzerdefiniert)" ;;
  esac
  printf '%s' "$t"
}

type_label() {
  case $1 in
    proxy) echo "Proxy" ;; redirect) echo "Weiterleitung" ;; static) echo "Statisch" ;;
    maintenance) echo "Wartung" ;; *) echo "Eigene" ;;
  esac
}

print_sites() {
  local f any=0
  printf '  %s%-3s %-30s %-14s %-9s %s%s\n' "$C_BOLD" "Nr" "Adresse" "Typ" "Status" "Ziel" "$C_RESET"
  hr
  local i=0
  while IFS= read -r f; do
    any=1; ((i++))
    local st
    site_active "$f" && st="${C_GREEN}aktiv${C_RESET}   " || st="${C_RED}aus${C_RESET}     "
    local lock=""
    [[ -n $(site_auth_user "$f") ]] && lock=" 🔒"
    printf '  %-3s %-30s %-14s %s %s%s\n' "$i" "$(site_addr "$f" | cut -c1-30)" \
      "$(type_label "$(site_type "$f")")" "$st" "$(site_target "$f")" "$lock"
  done < <(site_files)
  ((any)) || info "Noch keine Seiten angelegt."
}

# Seite auswählen → SITE_FILE
SITE_FILE=""
pick_site() {
  local files=() labels=() f
  while IFS= read -r f; do
    files+=("$f")
    local mark="●"; site_active "$f" || mark="○"
    labels+=("$mark $(printf '%-28s' "$(site_addr "$f")") ${C_DIM}$(site_target "$f")${C_RESET}")
  done < <(site_files)
  if ((${#files[@]} == 0)); then warn "Keine Seiten vorhanden."; pause; return 1; fi
  menu "${1:-Seite auswählen}" "${labels[@]}" "↩  Zurück"
  ((MENU_IDX < 0 || MENU_IDX >= ${#files[@]})) && return 1
  SITE_FILE=${files[MENU_IDX]}
}

# ── Eingabe-Prüfungen ────────────────────────────────────────────────────────
RE_HOST='^(\*\.)?([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}(:[0-9]{1,5})?$|^localhost(:[0-9]{1,5})?$|^:[0-9]{1,5}$'
RE_UPSTREAM='^[][A-Za-z0-9_.:/-]+$'

# Domains einlesen (Leerzeichen/Komma getrennt) → DOMAINS (Array), DOMAIN_LINE ("a, b")
DOMAINS=(); DOMAIN_LINE=""
ask_domains() { # ask_domains "Frage"
  local raw d
  while true; do
    ask raw "${1:-Domain(s), mehrere durch Leerzeichen}" "" || return 1
    raw=${raw//,/ }
    DOMAINS=()
    local bad=0
    for d in $raw; do
      d=${d,,}; d=${d#http://}; d=${d#https://}; d=${d%/}
      if [[ $d =~ $RE_HOST ]]; then DOMAINS+=("$d"); else err "Ungültige Domain: $d"; bad=1; fi
    done
    ((bad == 0 && ${#DOMAINS[@]} > 0)) && break
    confirm "Abbrechen?" n && return 1
  done
  DOMAIN_LINE=$(IFS=,; printf '%s' "${DOMAINS[*]}" | sed 's/,/, /g')
}

file_for_domain() { # sicherer Dateiname aus erster Domain
  local n=${1//[^a-zA-Z0-9._-]/_}
  n=${n//\*/wildcard}
  printf '%s/%s.caddy' "$SITES_DIR" "$n"
}

# ── Backup / Rollback ────────────────────────────────────────────────────────
snapshot() { # → Pfad auf stdout
  ensure_dirs
  local d="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)" n=0
  while [[ -e $d ]]; do d="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)-$((++n))"; done
  mkdir -p "$d/conf.d"
  [[ -f $CADDYFILE ]] && cp -a "$CADDYFILE" "$d/Caddyfile"
  cp -a "$SITES_DIR"/. "$d/conf.d/" 2>/dev/null
  # Alte Backups aufräumen
  local old
  old=$(ls -1d "$BACKUP_DIR"/*/ 2>/dev/null | sort | head -n -"$MAX_BACKUPS")
  [[ -n $old ]] && rm -rf $old
  printf '%s' "$d"
}

restore_snapshot() {
  local d=$1
  [[ -d $d ]] || { err "Backup nicht gefunden: $d"; return 1; }
  [[ -f $d/Caddyfile ]] && cp -a "$d/Caddyfile" "$CADDYFILE"
  rm -rf "$SITES_DIR"; mkdir -p "$SITES_DIR"
  cp -a "$d/conf.d/." "$SITES_DIR/" 2>/dev/null
  return 0
}

# ── Caddy: validieren / neu laden ────────────────────────────────────────────
validate_config() {
  have caddy || { echo "Caddy nicht installiert – Prüfung übersprungen"; return 0; }
  caddy validate --config "$CADDYFILE" --adapter caddyfile 2>&1
}

reload_caddy() {
  have caddy || { warn "Caddy nicht installiert – kein Reload."; return 0; }
  if have systemctl && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    systemctl reload "$SERVICE" && ok "Caddy neu geladen (systemd)" || { err "Reload fehlgeschlagen"; return 1; }
  else
    caddy reload --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 \
      && ok "Caddy neu geladen" || warn "Caddy läuft nicht – Konfiguration gespeichert, Dienst mit „systemctl start $SERVICE“ starten."
  fi
}

# Nach einer Änderung: prüfen, bei Fehler zurückrollen, sonst neu laden.  commit_change SNAPSHOT
commit_change() {
  local snap=$1 out
  if out=$(validate_config); then
    ok "Konfiguration ist gültig"
    reload_caddy
    return 0
  fi
  err "Caddy lehnt die Konfiguration ab:"
  printf '%s\n' "$out" | sed 's/^/      /' >&2
  restore_snapshot "$snap" && warn "Änderung zurückgerollt (Backup: $snap)"
  return 1
}

# ── Einrichtung der Haupt-Caddyfile ──────────────────────────────────────────
IMPORT_LINE() { printf 'import %s/*.caddy' "$SITES_DIR"; }

main_is_setup() { [[ -f $CADDYFILE ]] && grep -qF "$(IMPORT_LINE)" "$CADDYFILE"; }

write_global_block() { # write_global_block EMAIL STAGING(0/1)
  local email=$1 staging=$2 tmp
  tmp=$(mktemp)
  {
    echo "$GLOBAL_BEGIN"
    echo "{"
    [[ -n $email ]] && printf '\temail %s\n' "$email"
    ((staging)) && printf '\tacme_ca https://acme-staging-v02.api.letsencrypt.org/directory\n'
    echo "}"
    echo "$GLOBAL_END"
    echo
    # Rest der alten Datei ohne alten Global-Block
    [[ -f $CADDYFILE ]] && awk -v b="$GLOBAL_BEGIN" -v e="$GLOBAL_END" '
      $0==b {skip=1; next} $0==e {skip=0; next} !skip {print}' "$CADDYFILE"
  } >"$tmp"
  cat "$tmp" >"$CADDYFILE"; rm -f "$tmp"
}

setup_main() {
  banner "Ersteinrichtung"
  ensure_dirs
  local snap; snap=$(snapshot)
  if [[ -f $CADDYFILE ]] && grep -qE '^[^#[:space:]]' "$CADDYFILE" && ! main_is_setup; then
    warn "Es gibt bereits eine Caddyfile mit Inhalt: $CADDYFILE"
    menu "Bestehende Caddyfile" \
      "➕ Behalten und nur den Import ergänzen (empfohlen)" \
      "♻  Durch frische, leere Caddyfile ersetzen (Backup bleibt)" \
      "↩  Abbrechen"
    case $MENU_IDX in
      0) ;;
      1) : >"$CADDYFILE" ;;
      *) return 1 ;;
    esac
  fi
  [[ -f $CADDYFILE ]] || : >"$CADDYFILE"
  if ! main_is_setup; then
    {
      echo
      echo "# Von caddy-manager verwaltete Seiten:"
      IMPORT_LINE; echo
    } >>"$CADDYFILE"
    ok "Import-Zeile ergänzt"
  else
    ok "Import-Zeile ist bereits vorhanden"
  fi
  local email=""
  ask email "E-Mail für Let's-Encrypt-Benachrichtigungen (leer = keine)" "" || true
  if [[ -n $email && ! $email =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    warn "E-Mail sieht ungültig aus – wird ignoriert."; email=""
  fi
  write_global_block "$email" 0
  ok "Globale Einstellungen geschrieben"
  commit_change "$snap"
  pause
}

# ── Seite schreiben ──────────────────────────────────────────────────────────
OUT=""
L() { OUT+="$1"$'\n'; }

site_header() { # site_header TYP
  L "# managed-by: caddy-manager"
  L "# type: $1"
  L "# created: $(date '+%Y-%m-%d %H:%M')"
}

save_site() { # save_site DATEI  (Inhalt in $OUT)
  local file=$1 snap
  if [[ -e $file || -e $file.disabled ]]; then
    warn "Für diese Domain existiert schon eine Datei: $(basename "$file")"
    confirm "Überschreiben?" n || { info "Abgebrochen."; return 1; }
    rm -f "$file.disabled"
  fi
  main_is_setup || { warn "Haupt-Caddyfile ist noch nicht eingerichtet – hole das nach."; setup_main; }
  snap=$(snapshot)
  printf '%s' "$OUT" >"$file"
  chmod 644 "$file"
  echo
  hr
  sed 's/^/    /' "$file"
  hr
  commit_change "$snap" && ok "Gespeichert: $file"
}

ensure_log_dir() {
  [[ -d $LOG_DIR ]] && return 0
  mkdir -p "$LOG_DIR" 2>/dev/null || return 1
  id caddy >/dev/null 2>&1 && chown caddy:caddy "$LOG_DIR" 2>/dev/null
  return 0
}

emit_common_options() { # fragt Komprimierung, Security-Header, Logging, Basic-Auth ab → schreibt via L
  if confirm "Komprimierung (gzip/zstd) aktivieren?" j; then L $'\tencode zstd gzip'; fi
  if confirm "Sicherheits-Header (HSTS, nosniff, Frame-Schutz) setzen?" j; then
    L $'\theader {'
    L $'\t\tStrict-Transport-Security "max-age=31536000; includeSubDomains"'
    L $'\t\tX-Content-Type-Options nosniff'
    L $'\t\tX-Frame-Options SAMEORIGIN'
    L $'\t\tReferrer-Policy strict-origin-when-cross-origin'
    L $'\t\t-Server'
    L $'\t}'
  fi
  if confirm "Zugriffsschutz per Passwort (Basic-Auth)?" n; then
    local u p hash
    ask u "Benutzername" "admin"
    if [[ ! $u =~ ^[A-Za-z0-9._-]+$ ]]; then err "Ungültiger Benutzername – Basic-Auth übersprungen."
    elif ! have caddy; then err "Caddy fehlt (für den Passwort-Hash nötig) – übersprungen."
    else
      ask_secret p "Passwort"
      if [[ -z $p ]]; then err "Leeres Passwort – übersprungen."
      else
        hash=$(caddy hash-password --plaintext "$p" 2>/dev/null)
        L $'\tbasic_auth {'
        L $'\t\t'"$u $hash"
        L $'\t}'
        ok "Basic-Auth für „$u“ eingerichtet"
      fi
    fi
  fi
}

emit_logging() { # emit_logging DOMAIN
  if confirm "Eigene Zugriffs-Logdatei ($LOG_DIR)?" n; then
    ensure_log_dir || { warn "Konnte $LOG_DIR nicht anlegen – Logging übersprungen."; return; }
    L $'\tlog {'
    L $'\t\toutput file '"$LOG_DIR/${1//[^a-zA-Z0-9._-]/_}.log"' {'
    L $'\t\t\troll_size 10mb'
    L $'\t\t\troll_keep 5'
    L $'\t\t}'
    L $'\t}'
  fi
}

emit_www_redirect() { # Falls erste Domain keine www-Variante hat: www → Hauptdomain
  local main=${DOMAINS[0]}
  [[ $main == www.* || $main == \** || $main == :* || $main == localhost* ]] && return
  if confirm "www.$main zusätzlich auf $main weiterleiten?" j; then
    L ""
    L "www.$main {"
    L $'\tredir https://'"$main"$'{uri} permanent'
    L "}"
  fi
}

dns_check() { # dns_check DOMAIN
  local d=$1 ips mine
  d=${d#\*.}; d=${d%%:*}
  ips=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if have curl; then mine=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null); fi
  if [[ -z $ips ]]; then err "$d: keine DNS-Auflösung (A-Record fehlt?)"; return 1; fi
  info "$d → ${ips}"
  if [[ -n ${mine:-} ]]; then
    if [[ " $ips " == *" $mine "* ]]; then ok "Zeigt auf diesen Server ($mine)"
    else warn "Zeigt NICHT auf diesen Server (öffentliche IP hier: $mine) – Zertifikat kann scheitern."; fi
  fi
}

maybe_dns_check() {
  confirm "DNS jetzt prüfen (zeigt die Domain auf diesen Server)?" n || return 0
  local d; for d in "${DOMAINS[@]}"; do dns_check "$d"; done
}

# ── Seite anlegen: Reverse-Proxy ─────────────────────────────────────────────
add_proxy() {
  banner "Neue Domain → Reverse-Proxy"
  ask_domains || return
  local up tok ok_up=1 insecure=0 up_list=""
  while true; do
    ask up "Backend (Host:Port, mehrere für Lastverteilung durch Leerzeichen)" "127.0.0.1:8000" || return
    ok_up=1
    for tok in $up; do [[ $tok =~ $RE_UPSTREAM ]] || { err "Ungültiges Backend: $tok"; ok_up=0; }; done
    [[ -n $up && $ok_up -eq 1 ]] && break
  done
  if [[ $up == *https://* ]] && confirm "Selbstsigniertes Zertifikat des Backends akzeptieren?" n; then insecure=1; fi

  OUT=""; site_header proxy
  L "$DOMAIN_LINE {"
  emit_common_options
  emit_logging "${DOMAINS[0]}"
  L $'\t'"$MARKER"
  if ((insecure)); then
    L $'\treverse_proxy '"$up"$' {'
    L $'\t\ttransport http {'
    L $'\t\t\ttls_insecure_skip_verify'
    L $'\t\t}'
    L $'\t}'
  else
    L $'\treverse_proxy '"$up"
  fi
  L "}"
  emit_www_redirect
  maybe_dns_check
  save_site "$(file_for_domain "${DOMAINS[0]}")"
  pause
}

# ── Weiterleitung Domain → URL ───────────────────────────────────────────────
add_redirect() {
  banner "Neue Weiterleitung (Domain → Ziel-URL)"
  ask_domains "Quell-Domain(s), die weitergeleitet werden" || return
  local target code keep
  while true; do
    ask target "Ziel (z. B. https://neu.example.de)" "https://" || return
    [[ $target =~ ^https?://[^[:space:]\{\}\"]+$ ]] && break
    err "Bitte eine vollständige URL mit http:// oder https:// angeben."
  done
  target=${target%/}
  menu "Art der Weiterleitung" \
    "301 – dauerhaft (Browser/Suchmaschinen merken sich das)" \
    "302 – vorübergehend" \
    "307 – vorübergehend, Methode bleibt erhalten" \
    "308 – dauerhaft, Methode bleibt erhalten"
  case $MENU_IDX in 0) code=301 ;; 1) code=302 ;; 2) code=307 ;; 3) code=308 ;; *) return ;; esac
  confirm "Pfad und Parameter übernehmen (alt.de/seite?a=1 → neu.de/seite?a=1)?" j && keep='{uri}' || keep='/'

  OUT=""; site_header redirect
  L "$DOMAIN_LINE {"
  L $'\tredir '"$target$keep $code"
  L "}"
  maybe_dns_check
  save_site "$(file_for_domain "${DOMAINS[0]}")"
  pause
}

# ── www ↔ non-www ────────────────────────────────────────────────────────────
add_www_redirect() {
  banner "www ↔ ohne www"
  local d
  while true; do
    ask d "Domain (ohne www, z. B. example.de)" "" || return
    d=${d,,}; d=${d#www.}
    [[ $d =~ $RE_HOST ]] && break
    err "Ungültige Domain."
  done
  menu "Richtung" "www.$d  →  $d" "$d  →  www.$d"
  OUT=""; site_header redirect
  case $MENU_IDX in
    0) L "www.$d {"; L $'\tredir https://'"$d"$'{uri} permanent'; L "}" ;;
    1) L "$d {"; L $'\tredir https://www.'"$d"$'{uri} permanent'; L "}" ;;
    *) return ;;
  esac
  save_site "$(file_for_domain "$([[ $MENU_IDX -eq 0 ]] && echo "www.$d" || echo "$d")")"
  info "Hinweis: Die Ziel-Domain braucht eine eigene Seite (z. B. Reverse-Proxy)."
  pause
}

# ── Statische Website ────────────────────────────────────────────────────────
add_static() {
  banner "Neue statische Website / SPA"
  ask_domains || return
  local root spa=0 browse=0
  while true; do
    ask root "Verzeichnis mit den Dateien" "/var/www/${DOMAINS[0]}" || return
    [[ $root == /* && $root =~ ^[A-Za-z0-9_./-]+$ ]] && break
    err "Bitte einen absoluten Pfad ohne Sonderzeichen angeben."
  done
  if [[ ! -d $root ]]; then
    confirm "Verzeichnis $root existiert nicht – jetzt anlegen?" j && mkdir -p "$root" && ok "Angelegt"
  fi
  confirm "Single-Page-App (unbekannte Pfade → /index.html)?" n && spa=1
  ((spa)) || { confirm "Verzeichnisinhalt anzeigen (Datei-Browser)?" n && browse=1; }

  OUT=""; site_header static
  L "$DOMAIN_LINE {"
  L $'\troot * '"$root"
  emit_common_options
  emit_logging "${DOMAINS[0]}"
  L $'\t'"$MARKER"
  ((spa)) && L $'\ttry_files {path} {path}/ /index.html'
  if ((browse)); then L $'\tfile_server browse'; else L $'\tfile_server'; fi
  L "}"
  emit_www_redirect
  maybe_dns_check
  save_site "$(file_for_domain "${DOMAINS[0]}")"
  pause
}

# ── Wartungsseite ────────────────────────────────────────────────────────────
add_maintenance() {
  banner "Wartungsseite (HTTP 503)"
  ask_domains || return
  local msg
  ask msg "Text der Wartungsseite" "Wir sind gleich wieder da – Wartungsarbeiten." || return
  OUT=""; site_header maintenance
  L "$DOMAIN_LINE {"
  L $'\theader Retry-After "3600"'
  L $'\trespond "'"$(esc "$msg")"$'" 503'
  L "}"
  save_site "$(file_for_domain "${DOMAINS[0]}")"
  pause
}

# ── Regeln zu bestehender Seite ──────────────────────────────────────────────
insert_rule() { # insert_rule DATEI REGELTEXT
  local file=$1 tmp
  grep -qF "$MARKER" "$file" || { err "In dieser Datei fehlt die Zeile „$MARKER“ – bitte manuell bearbeiten."; return 1; }
  tmp=$(mktemp)
  RULE=$2 awk -v m="$MARKER" 'BEGIN{d=0} {print} !d && index($0,m) {print ENVIRON["RULE"]; d=1}' "$file" >"$tmp" \
    && cat "$tmp" >"$file"
  rm -f "$tmp"
}

# ── Passwortschutz (Basic-Auth) einer bestehenden Seite ─────────────────────
# Benutzername des Passwortschutzes einer Seite (leer = ungeschützt)
site_auth_user() {
  awk '
    blk { print $1; exit }
    /^[ \t]*(basic_auth|basicauth)[ \t]*\{[ \t]*$/ { blk = 1 }' "$1"
}

# Entfernt vorhandene basic_auth-Blöcke aus DATEI
remove_auth_block() {
  local file=$1 tmp
  tmp=$(mktemp)
  awk '
    skip { if ($0 ~ /^[ \t]*\}[ \t]*$/) skip = 0; next }
    /^[ \t]*(basic_auth|basicauth)[ \t]*\{[ \t]*$/ { skip = 1; next }
    { print }' "$file" >"$tmp" && cat "$tmp" >"$file"
  rm -f "$tmp"
}

# Fügt eine Anweisung für die ganze Seite ein: hinter dem Platzhalter, sonst hinter der ersten „{“-Zeile
insert_site_level() { # insert_site_level DATEI TEXT
  local file=$1 tmp
  if grep -qF "$MARKER" "$file"; then insert_rule "$file" "$2"; return; fi
  tmp=$(mktemp)
  RULE=$2 awk 'BEGIN{d=0} {print} !d && /\{[ \t]*$/ {print ENVIRON["RULE"]; d=1}' "$file" >"$tmp" \
    && cat "$tmp" >"$file"
  rm -f "$tmp"
}

# Setzt Benutzer und Passwort (ersetzt einen vorhandenen Schutz). Der Aufrufer sichert vorher und prüft danach.
# Das Passwort wird nie gespeichert, nur der Hash; die Datei ist danach nur für root und Caddy lesbar.
set_site_auth() { # set_site_auth DATEI BENUTZER PASSWORT
  local file=$1 user=$2 pass=$3 hash
  [[ $user =~ ^[A-Za-z0-9._-]+$ ]] || { err "Ungültiger Benutzername (erlaubt: Buchstaben, Ziffern, . _ -)."; return 1; }
  [[ -n $pass ]] || { err "Leeres Passwort."; return 1; }
  have caddy || { err "Caddy fehlt (für den Passwort-Hash nötig)."; return 1; }
  hash=$(caddy hash-password --plaintext "$pass" 2>/dev/null)
  [[ -n $hash ]] || { err "Passwort-Hash konnte nicht erzeugt werden."; return 1; }
  remove_auth_block "$file"
  insert_site_level "$file" $'\tbasic_auth {\n\t\t'"$user $hash"$'\n\t}' || return 1
  if id caddy >/dev/null 2>&1; then chgrp caddy "$file" 2>/dev/null && chmod 640 "$file"; fi
  return 0
}

site_auth_menu() { # site_auth_menu DATEI
  local file=$1 cur user pass pass2 snap
  cur=$(site_auth_user "$file")
  menu "Passwortschutz für $(site_addr "$file") ($([[ -n $cur ]] && echo "geschützt, Benutzer: $cur" || echo "ungeschützt"))" \
    "🔑 Benutzer und Passwort setzen / ersetzen" \
    "🔓 Passwortschutz entfernen" \
    "↩  Zurück"
  case $MENU_IDX in
    0)
      ask user "Benutzername" "${cur:-vorschau}" || return
      ask_secret pass "Passwort" || return
      ask_secret pass2 "Passwort wiederholen" || return
      [[ $pass == "$pass2" ]] || { err "Die Passwörter sind nicht gleich."; pause; return; }
      snap=$(snapshot)
      if set_site_auth "$file" "$user" "$pass"; then commit_change "$snap" && ok "Passwortschutz gesetzt (Benutzer: $user)"
      else restore_snapshot "$snap"; fi
      pause ;;
    1)
      [[ -n $cur ]] || { info "Diese Seite hat keinen Passwortschutz."; pause; return; }
      confirm "Passwortschutz von $(site_addr "$file") wirklich entfernen? Die Seite ist danach offen." n || return
      snap=$(snapshot)
      remove_auth_block "$file"
      commit_change "$snap" && ok "Passwortschutz entfernt"
      pause ;;
  esac
}

add_rule() {
  pick_site "Zu welcher Seite soll eine Regel hinzukommen?" || return
  local file=$SITE_FILE
  menu "Regel für $(site_addr "$file")" \
    "↪  Pfad weiterleiten      (/alt → /neu oder andere URL)" \
    "🚫 Pfad sperren           (liefert 403)" \
    "🔒 Pfad nur für bestimmte IPs freigeben" \
    "✏  Pfad intern umschreiben (rewrite)" \
    "🔑 Passwortschutz (Basic-Auth) für die ganze Seite" \
    "↩  Zurück"
  if ((MENU_IDX == 4)); then site_auth_menu "$file"; return; fi
  if ((MENU_IDX >= 0 && MENU_IDX <= 3)) && ! grep -qF "$MARKER" "$file"; then
    err "Diese Seite unterstützt keine automatischen Regeln (kein Platzhalter)."; pause; return
  fi
  local rule="" from to code ips id
  case $MENU_IDX in
    0)
      ask from "Alter Pfad (z. B. /alt oder /blog/*)" "/" || return
      ask to "Ziel (Pfad oder volle URL)" "/" || return
      ask code "Statuscode (301 dauerhaft / 302 vorübergehend)" "301" || return
      [[ $from == /* && $from =~ ^[^[:space:]\{\}\"]+$ && $to =~ ^[^[:space:]\"]+$ && $code =~ ^30[1278]$ ]] \
        || { err "Eingabe ungültig."; pause; return; }
      rule=$'\t'"redir $from $to $code" ;;
    1)
      ask from "Zu sperrender Pfad (z. B. /admin/*)" "/admin/*" || return
      [[ $from == /* && $from =~ ^[^[:space:]\{\}\"]+$ ]] || { err "Pfad ungültig."; pause; return; }
      rule=$'\t'"respond $from \"Zugriff verweigert\" 403" ;;
    2)
      ask from "Pfad (z. B. /admin/*)" "/admin/*" || return
      ask ips "Erlaubte IPs/Netze (Leerzeichen getrennt, z. B. 203.0.113.5 10.0.0.0/8)" "" || return
      [[ $from == /* && $from =~ ^[^[:space:]\{\}\"]+$ && $ips =~ ^[0-9a-fA-F:./\ ]+$ ]] \
        || { err "Eingabe ungültig."; pause; return; }
      id="ip$RANDOM"
      rule=$'\t'"@$id {"$'\n'$'\t\t'"path $from"$'\n'$'\t\t'"not remote_ip $ips"$'\n'$'\t'"}"$'\n'$'\t'"respond @$id \"Zugriff verweigert\" 403" ;;
    3)
      ask from "Aufgerufener Pfad" "/alt" || return
      ask to "Wird intern umgeschrieben auf" "/neu" || return
      [[ $from == /* && $to == /* && $from =~ ^[^[:space:]\{\}\"]+$ && $to =~ ^[^[:space:]\"]+$ ]] \
        || { err "Eingabe ungültig."; pause; return; }
      rule=$'\t'"rewrite $from $to" ;;
    *) return ;;
  esac
  local snap; snap=$(snapshot)
  insert_rule "$file" "$rule" && { ok "Regel eingefügt"; commit_change "$snap"; }
  pause
}

# ── Seiten verwalten ─────────────────────────────────────────────────────────
manage_sites() {
  while true; do
    pick_site "Seiten verwalten" || return
    local file=$SITE_FILE act
    while true; do
      local state="aktiv"; site_active "$file" || state="deaktiviert"
      menu "$(site_addr "$file")  [$state]" \
        "👁  Anzeigen" \
        "✏  Bearbeiten (Editor)" \
        "⏯  Aktivieren / Deaktivieren" \
        "🔁 Domain(s) umbenennen" \
        "🗑  Löschen" \
        "↩  Zurück"
      act=$MENU_IDX
      case $act in
        0) banner "$(basename "$file")"; echo; sed 's/^/    /' "$file"; pause ;;
        1) edit_site "$file" ;;
        2) toggle_site "$file" && { [[ $file == *.disabled ]] && file=${file%.disabled} || file="$file.disabled"; } ;;
        3) rename_site "$file"; break ;;
        4) delete_site "$file" && break ;;
        *) break ;;
      esac
      [[ -e $file ]] || break
    done
  done
}

edit_site() {
  local file=$1 snap ed=${EDITOR:-}
  [[ -z $ed ]] && for ed in nano vim vi; do have "$ed" && break; done
  have "$ed" || { err "Kein Editor gefunden (EDITOR setzen)."; pause; return; }
  snap=$(snapshot)
  "$ed" "$file"
  if commit_change "$snap"; then :; else warn "Datei wurde zurückgesetzt."; fi
  pause
}

toggle_site() { # → 0 bei Erfolg
  local file=$1 snap new
  snap=$(snapshot)
  if site_active "$file"; then new="$file.disabled"; else new=${file%.disabled}; fi
  mv "$file" "$new"
  if commit_change "$snap"; then ok "Jetzt: $(site_active "$new" && echo aktiv || echo deaktiviert)"; pause; return 0; fi
  pause; return 1
}

rename_site() {
  local file=$1 old new_line
  old=$(site_addr "$file")
  ask_domains "Neue Domain(s) (bisher: $old)" || return
  local snap; snap=$(snapshot)
  # Nur die erste Block-Zeile (Adresszeile) ersetzen
  local tmp; tmp=$(mktemp)
  NEWADDR="$DOMAIN_LINE" awk 'BEGIN{d=0} !d && /\{[[:space:]]*$/ && !/^[[:space:]]/ {print ENVIRON["NEWADDR"] " {"; d=1; next} {print}' "$file" >"$tmp" \
    && cat "$tmp" >"$file"
  rm -f "$tmp"
  local dest; dest=$(file_for_domain "${DOMAINS[0]}"); [[ $file == *.disabled ]] && dest="$dest.disabled"
  [[ $dest != "$file" ]] && mv "$file" "$dest"
  commit_change "$snap" && ok "Umbenannt: $old → $DOMAIN_LINE"
  pause
}

delete_site() { # → 0 wenn gelöscht
  local file=$1 snap
  confirm "„$(site_addr "$file")“ wirklich löschen? (Backup wird angelegt)" n || return 1
  snap=$(snapshot)
  rm -f "$file"
  commit_change "$snap" && ok "Gelöscht. Wiederherstellen: Menü → Backups ($snap)"
  pause
  return 0
}

list_sites_screen() {
  banner "Alle Seiten"
  echo
  print_sites
  pause
}

# ── Diagnose ─────────────────────────────────────────────────────────────────
http_check() {
  local d
  ask d "Domain prüfen (z. B. example.de)" "" || return
  have curl || { err "curl fehlt."; return; }
  echo
  info "HTTP → HTTPS:"
  curl -sS -o /dev/null -I --max-time 10 -w '    Status %{http_code}  Weiterleitung: %{redirect_url}\n' "http://$d" 2>&1 | sed 's/^curl: /    /'
  info "HTTPS:"
  curl -sS -o /dev/null -I --max-time 10 -w '    Status %{http_code}  Zeit %{time_total}s  TLS-Verify: %{ssl_verify_result} (0 = ok)\n' "https://$d" 2>&1 | sed 's/^curl: /    /'
}

show_certs() {
  [[ -d $CERT_DIR ]] || { warn "Keine Zertifikate gefunden ($CERT_DIR)."; return; }
  have openssl || { err "openssl fehlt."; return; }
  printf '  %s%-38s %s%s\n' "$C_BOLD" "Domain" "Läuft ab" "$C_RESET"; hr
  local crt exp
  while IFS= read -r crt; do
    exp=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
    printf '  %-38s %s\n' "$(basename "$(dirname "$crt")")" "$exp"
  done < <(find "$CERT_DIR" -name '*.crt' 2>/dev/null | sort)
}

diagnose_menu() {
  while true; do
    menu "Prüfen & Diagnose" \
      "✅ Konfiguration prüfen (caddy validate)" \
      "🎨 Konfiguration formatieren (caddy fmt)" \
      "🌍 DNS prüfen (zeigt Domain auf diesen Server?)" \
      "🔗 Erreichbarkeit testen (HTTP/HTTPS)" \
      "🔐 Zertifikate anzeigen" \
      "↩  Zurück"
    case $MENU_IDX in
      0) banner "Konfiguration prüfen"; echo; out=$(validate_config) && ok "Gültig" || { err "Fehler:"; echo "$out" | sed 's/^/      /'; }; pause ;;
      1) banner "Formatieren"; echo
         if have caddy; then
           local snap; snap=$(snapshot)
           caddy fmt --overwrite "$CADDYFILE" 2>&1 | sed 's/^/    /'
           local f; while IFS= read -r f; do [[ $f == *.caddy ]] && caddy fmt --overwrite "$f" >/dev/null 2>&1; done < <(site_files)
           commit_change "$snap"
         else err "Caddy nicht installiert."; fi; pause ;;
      2) banner "DNS-Prüfung"; echo; local d; ask d "Domain" "" && dns_check "$d"; pause ;;
      3) banner "Erreichbarkeit"; echo; http_check; pause ;;
      4) banner "Zertifikate"; echo; show_certs; pause ;;
      *) return ;;
    esac
  done
}

# ── Dienst ───────────────────────────────────────────────────────────────────
install_caddy() {
  banner "Caddy installieren"
  have caddy && { ok "Caddy ist bereits installiert: $(caddy version 2>/dev/null | head -1)"; pause; return; }
  have apt-get || { err "Automatische Installation nur für Debian/Ubuntu. Siehe https://caddyserver.com/docs/install"; pause; return; }
  info "Es wird das offizielle Caddy-Paket-Repository (cloudsmith) eingerichtet."
  confirm "Fortfahren?" j || return
  apt-get update -y && apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update -y && apt-get install -y caddy \
    && ok "Caddy installiert" || err "Installation fehlgeschlagen."
  pause
}

service_menu() {
  while true; do
    menu "Caddy-Dienst" \
      "📊 Status anzeigen" \
      "🔄 Konfiguration neu laden (ohne Unterbrechung)" \
      "♻  Dienst neu starten" \
      "▶  Starten" \
      "⏹  Stoppen" \
      "🔌 Beim Systemstart aktivieren" \
      "📜 Log anzeigen (letzte 60 Zeilen)" \
      "📡 Log live verfolgen (Strg+C beendet)" \
      "⬇  Caddy installieren" \
      "↩  Zurück"
    case $MENU_IDX in
      0) banner "Status"; echo
         have caddy && info "$(caddy version 2>/dev/null | head -1)"
         have systemctl && systemctl status "$SERVICE" --no-pager -n 5 2>&1 | sed 's/^/    /'
         have ss && { echo; info "Lauschende Ports:"; ss -tlnp 2>/dev/null | grep -i caddy | sed 's/^/    /'; }
         pause ;;
      1) banner "Neu laden"; echo; reload_caddy; pause ;;
      2) banner "Neustart"; echo; systemctl restart "$SERVICE" && ok "Neu gestartet" || err "Fehlgeschlagen"; pause ;;
      3) banner "Starten"; echo; systemctl start "$SERVICE" && ok "Gestartet" || err "Fehlgeschlagen"; pause ;;
      4) banner "Stoppen"; echo; confirm "Caddy wirklich stoppen? (alle Seiten offline)" n && systemctl stop "$SERVICE" && ok "Gestoppt"; pause ;;
      5) banner "Autostart"; echo; systemctl enable "$SERVICE" 2>&1 | sed 's/^/    /'; pause ;;
      6) banner "Log"; echo; journalctl -u "$SERVICE" -n 60 --no-pager 2>&1 | sed 's/^/  /'; pause ;;
      7) banner "Live-Log"; echo; trap ':' INT; journalctl -u "$SERVICE" -f -n 20 2>&1; trap - INT; pause ;;
      8) install_caddy ;;
      *) return ;;
    esac
  done
}

# ── Backups ──────────────────────────────────────────────────────────────────
backup_menu() {
  while true; do
    menu "Backups & Wiederherstellung" \
      "💾 Jetzt Backup anlegen" \
      "⏪ Backup wiederherstellen" \
      "📂 Backups auflisten" \
      "↩  Zurück"
    case $MENU_IDX in
      0) banner "Backup"; echo; ok "Angelegt: $(snapshot)"; pause ;;
      1) restore_menu ;;
      2) banner "Backups"; echo; ls -1 "$BACKUP_DIR" 2>/dev/null | sort -r | sed 's/^/    /'; pause ;;
      *) return ;;
    esac
  done
}

restore_menu() {
  local dirs=() d
  while IFS= read -r d; do dirs+=("$d"); done < <(ls -1 "$BACKUP_DIR" 2>/dev/null | sort -r)
  ((${#dirs[@]})) || { warn "Keine Backups vorhanden."; pause; return; }
  local labels=() x
  for x in "${dirs[@]}"; do
    labels+=("$x  ${C_DIM}($(ls -1 "$BACKUP_DIR/$x/conf.d" 2>/dev/null | wc -l) Dateien)${C_RESET}")
  done
  menu "Welches Backup wiederherstellen?" "${labels[@]}" "↩  Zurück"
  ((MENU_IDX < 0 || MENU_IDX >= ${#dirs[@]})) && return
  local pick=${dirs[MENU_IDX]}
  confirm "Aktuellen Stand durch Backup $pick ersetzen?" n || return
  local safety; safety=$(snapshot)
  restore_snapshot "$BACKUP_DIR/$pick"
  info "Vorheriger Stand gesichert unter: $safety"
  commit_change "$safety" && ok "Wiederhergestellt: $pick"
  pause
}

# ── Globale Einstellungen ────────────────────────────────────────────────────
global_menu() {
  while true; do
    menu "Globale Einstellungen" \
      "✉  ACME-E-Mail setzen" \
      "🧪 Let's-Encrypt-Staging an/aus (zum Testen, ohne Rate-Limits)" \
      "🛠  Ersteinrichtung / Import-Zeile prüfen" \
      "↩  Zurück"
    case $MENU_IDX in
      0) banner "ACME-E-Mail"; echo
         local cur e staging=0
         cur=$(awk -v b="$GLOBAL_BEGIN" -v e="$GLOBAL_END" '$0==b{s=1} s&&/email/{print $2} $0==e{s=0}' "$CADDYFILE" 2>/dev/null)
         grep -q 'acme-staging' "$CADDYFILE" 2>/dev/null && staging=1
         ask e "E-Mail-Adresse" "$cur" || continue
         [[ -z $e || $e =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { err "Ungültige E-Mail."; pause; continue; }
         local snap; snap=$(snapshot); write_global_block "$e" "$staging"; commit_change "$snap"; pause ;;
      1) banner "Staging"; echo
         local cur_s=0 email
         grep -q 'acme-staging' "$CADDYFILE" 2>/dev/null && cur_s=1
         email=$(awk -v b="$GLOBAL_BEGIN" -v e="$GLOBAL_END" '$0==b{s=1} s&&/email/{print $2} $0==e{s=0}' "$CADDYFILE" 2>/dev/null)
         if ((cur_s)); then info "Staging ist AN (Browser zeigen Zertifikatswarnungen)."; confirm "Ausschalten?" j && cur_s=0
         else info "Staging ist AUS."; confirm "Einschalten?" n && cur_s=1; fi
         local snap2; snap2=$(snapshot); write_global_block "$email" "$cur_s"; commit_change "$snap2"; pause ;;
      2) setup_main ;;
      *) return ;;
    esac
  done
}

# ── Bestehende Caddyfile-Blöcke übernehmen ───────────────────────────────────
# Zerlegt die Haupt-Caddyfile: Site-Blöcke (Adresse { … }) landen in DIR/block_N.txt,
# alles andere (globale Optionen, Snippets, import-Zeilen, Kommentare) in DIR/rest.txt.
IMPORT_COUNT=0
split_caddyfile() { # split_caddyfile DIR
  local dir=$1
  : >"$dir/rest.txt"
  awk -v dir="$dir" -v gb="$GLOBAL_BEGIN" -v ge="$GLOBAL_END" '
    function strip(s) { gsub(/"[^"]*"/, "", s); sub(/#.*/, "", s); return s }
    function net(s,   o, c) { s = strip(s); o = gsub(/\{/, "{", s); c = gsub(/\}/, "}", s); return o - c }
    BEGIN { mode = 0; depth = 0; n = 0; pend = ""; glob = 0; rest = dir "/rest.txt" }
    {
      line = $0
      if (mode == 1) {                       # innerhalb eines Site-Blocks
        print line >> f; depth += net(line)
        if (depth <= 0) { mode = 0; depth = 0; close(f) }
        next
      }
      if (mode == 2) {                       # innerhalb eines zu behaltenden Blocks
        print line >> rest; depth += net(line)
        if (depth <= 0) { mode = 0; depth = 0 }
        next
      }
      if (glob) { print line >> rest; if (line == ge) glob = 0; next }
      if (line == gb) { printf "%s", pend >> rest; pend = ""; print line >> rest; glob = 1; next }
      if (line ~ /^[[:space:]]*#/) { pend = pend line "\n"; next }
      if (line ~ /^[[:space:]]*$/) { printf "%s", pend >> rest; pend = ""; print line >> rest; next }
      s = strip(line)
      if (s ~ /\{[[:space:]]*$/ && line !~ /^\{/ && line !~ /^\(/ && line !~ /^[[:space:]]/ && line !~ /^import[[:space:]]/) {
        n++; f = dir "/block_" n ".txt"
        printf "%s", pend >> f; pend = ""
        print line >> f; depth = net(line)
        if (depth <= 0) { depth = 0; close(f) } else mode = 1
        next
      }
      printf "%s", pend >> rest; pend = ""
      print line >> rest
      depth = net(line)
      if (depth > 0) mode = 2; else depth = 0
    }
    END { printf "%s", pend >> rest }
  ' "$CADDYFILE"
  IMPORT_COUNT=$(find "$dir" -name 'block_*.txt' | wc -l)
}

block_addr() { # erste nicht-Kommentar-Zeile eines Blocks ohne „{“
  grep -m1 -vE '^[[:space:]]*#' "$1" | sed 's/[[:space:]]*{[[:space:]]*$//'
}

block_type() {
  if grep -qE '^[[:space:]]*reverse_proxy' "$1"; then echo proxy
  elif grep -qE '^[[:space:]]*file_server' "$1"; then echo static
  elif grep -qE '^[[:space:]]*redir ' "$1"; then echo redirect
  else echo custom; fi
}

# Baut aus einem Block eine verwaltete Seite (Header + ggf. Regel-Platzhalter) → stdout
render_imported_block() { # render_imported_block BLOCKFILE
  local b=$1 t
  t=$(block_type "$b")
  printf '# managed-by: caddy-manager\n# type: %s\n# imported: %s\n' "$t" "$(date '+%Y-%m-%d %H:%M')"
  if [[ $t == proxy || $t == static ]]; then
    # Platzhalter für Regeln vor die erste Haupt-Direktive setzen (nur Einrückung 1. Ebene)
    awk -v m="$MARKER" -v pat='^(\t| {2}| {4})(reverse_proxy|file_server)([ \t{]|$)' '
      !d && $0 ~ pat { match($0, /^[ \t]+/); print substr($0, 1, RLENGTH) m; d = 1 } { print }' "$b"
  else
    cat "$b"
  fi
}

import_blocks() { # import_blocks [auto]   (auto = alles ohne Rückfrage)
  local auto=${1:-} tmp i=0 b snap name dest k chosen=() cnt=0
  [[ -f $CADDYFILE ]] || { warn "Keine Caddyfile gefunden: $CADDYFILE"; return 1; }
  tmp=$(mktemp -d)
  split_caddyfile "$tmp"
  if ((IMPORT_COUNT == 0)); then
    info "Keine übernehmbaren Site-Blöcke in der Caddyfile gefunden."
    rm -rf "$tmp"; return 0
  fi
  local files=()
  while IFS= read -r b; do files+=("$b"); done < <(find "$tmp" -name 'block_*.txt' | sort -V)

  echo
  printf '  %s%d Block/Blöcke in %s gefunden:%s\n' "$C_BOLD" "${#files[@]}" "$CADDYFILE" "$C_RESET"
  hr
  for b in "${files[@]}"; do
    ((i++)); printf '  %-3s %-34s %s\n' "$i" "$(block_addr "$b" | cut -c1-34)" "$(type_label "$(block_type "$b")")"
  done
  hr
  local mode=0
  if [[ -z $auto ]]; then
    menu "Was übernehmen?" "📥 Alle Blöcke übernehmen" "☑  Einzeln auswählen" "↩  Abbrechen"
    mode=$MENU_IDX
    [[ $mode -lt 0 || $mode -gt 1 ]] && { rm -rf "$tmp"; return 0; }
  fi
  for b in "${files[@]}"; do
    if ((mode == 1)); then
      if confirm "„$(block_addr "$b")“ übernehmen?" j; then chosen+=("$b"); fi
    else
      chosen+=("$b")
    fi
  done
  # nicht gewählte Blöcke bleiben in der Caddyfile
  for b in "${files[@]}"; do
    [[ " ${chosen[*]} " == *" $b "* ]] || { cat "$b" >>"$tmp/rest.txt"; printf '\n' >>"$tmp/rest.txt"; }
  done
  if ((${#chosen[@]} == 0)); then info "Nichts übernommen."; rm -rf "$tmp"; return 0; fi

  snap=$(snapshot)
  ensure_dirs
  for b in "${chosen[@]}"; do
    name=$(block_addr "$b" | tr ',' ' ' | awk '{print $1}')
    name=${name#http://}; name=${name#https://}
    dest=$(file_for_domain "$name"); k=1
    local base=${dest%.caddy}
    while [[ -e $dest || -e $dest.disabled ]]; do dest="$base-$((++k)).caddy"; done
    render_imported_block "$b" >"$dest"; chmod 644 "$dest"
    ok "Übernommen: $(basename "$dest")"; ((cnt++))
  done
  cat "$tmp/rest.txt" >"$CADDYFILE"
  grep -qF "$(IMPORT_LINE)" "$CADDYFILE" || printf '\n# Von caddy-manager verwaltete Seiten:\n%s\n' "$(IMPORT_LINE)" >>"$CADDYFILE"
  rm -rf "$tmp"
  commit_change "$snap" && ok "$cnt Block/Blöcke in die Verwaltung übernommen. Backup: $snap"
}

import_menu() {
  banner "Bestehende Caddyfile-Blöcke übernehmen"
  info "Verschiebt Site-Blöcke aus $CADDYFILE in eigene Dateien unter $SITES_DIR."
  info "Globale Optionen, Snippets und import-Zeilen bleiben stehen. Es wird vorher ein Backup angelegt."
  import_blocks
  pause
}

# ── Kommandozeilen-Modus ─────────────────────────────────────────────────────
usage() {
  cat <<EOF
caddy-manager $VERSION

  ohne Argument                     interaktives Menü
  list                              alle Seiten anzeigen
  import                            alle Site-Blöcke der Caddyfile in die Verwaltung übernehmen
  proxy DOMAIN BACKEND              Reverse-Proxy anlegen   (z. B. proxy app.example.de 127.0.0.1:8000)
  redirect VON ZIEL [CODE]          Weiterleitung anlegen    (CODE: 301 Standard, 302, 307, 308)
  static DOMAIN VERZEICHNIS         statische Seite anlegen
  auth DOMAIN BENUTZER              Passwortschutz (Basic-Auth) setzen oder ersetzen. Das Passwort steht nie
                                    als Argument: Umgebungsvariable CM_AUTH_PASSWORD oder Abfrage im Terminal
  auth-off DOMAIN                   Passwortschutz entfernen
  remove DOMAIN                     Seite löschen (mit Backup)
  enable DOMAIN | disable DOMAIN    Seite ein-/ausschalten
  validate                          Konfiguration prüfen
  reload                            Caddy neu laden
  backup                            Backup anlegen
  setup                             Haupt-Caddyfile einrichten (Import-Zeile)
  help                              diese Hilfe
EOF
}

cli_find() { # DOMAIN → Datei (aktiv oder deaktiviert)
  local f=$(file_for_domain "$1")
  [[ -e $f ]] && { echo "$f"; return 0; }
  [[ -e $f.disabled ]] && { echo "$f.disabled"; return 0; }
  return 1
}

cli_write() { # cli_write DOMAIN  (Inhalt in OUT)
  local f snap
  f=$(file_for_domain "$1")
  ensure_dirs
  main_is_setup || { [[ -f $CADDYFILE ]] || : >"$CADDYFILE"; printf '\n%s\n' "$(IMPORT_LINE)" >>"$CADDYFILE"; }
  snap=$(snapshot)
  printf '%s' "$OUT" >"$f"
  commit_change "$snap" && ok "Angelegt: $f"
}

cli() {
  local cmd=$1; shift
  case $cmd in
    list)     ensure_dirs; print_sites ;;
    import)   ensure_dirs; import_blocks auto ;;
    proxy)
      [[ $# -ge 2 && ${1,,} =~ $RE_HOST && $2 =~ $RE_UPSTREAM ]] || { usage; exit 2; }
      DOMAINS=("${1,,}"); OUT=""; site_header proxy
      L "${1,,} {"; L $'\tencode zstd gzip'; L $'\t'"$MARKER"; L $'\treverse_proxy '"$2"; L "}"
      cli_write "${1,,}" ;;
    redirect)
      [[ $# -ge 2 && ${1,,} =~ $RE_HOST && $2 =~ ^https?://[^[:space:]\{\}\"]+$ ]] || { usage; exit 2; }
      local code=${3:-301}; [[ $code =~ ^30[1278]$ ]] || { err "Ungültiger Code"; exit 2; }
      OUT=""; site_header redirect
      L "${1,,} {"; L $'\tredir '"${2%/}"$'{uri} '"$code"; L "}"
      cli_write "${1,,}" ;;
    static)
      [[ $# -ge 2 && ${1,,} =~ $RE_HOST && $2 == /* && $2 =~ ^[A-Za-z0-9_./-]+$ ]] || { usage; exit 2; }
      OUT=""; site_header static
      L "${1,,} {"; L $'\troot * '"$2"; L $'\tencode zstd gzip'; L $'\t'"$MARKER"; L $'\tfile_server'; L "}"
      cli_write "${1,,}" ;;
    auth)
      [[ $# -ge 2 && ${1,,} =~ $RE_HOST ]] || { usage; exit 2; }
      local f snap pass=${CM_AUTH_PASSWORD:-}
      f=$(cli_find "$1") || { err "Nicht gefunden: $1"; exit 1; }
      if [[ -z $pass ]]; then
        [[ -t 0 ]] || { err "Passwort fehlt: CM_AUTH_PASSWORD setzen oder im Terminal ausführen."; exit 2; }
        ask_secret pass "Passwort" || exit 1
      fi
      snap=$(snapshot)
      set_site_auth "$f" "$2" "$pass" || exit 1
      commit_change "$snap" && ok "Passwortschutz gesetzt (Benutzer: $2)" ;;
    auth-off)
      local f snap; f=$(cli_find "${1:-}") || { err "Nicht gefunden: ${1:-}"; exit 1; }
      [[ -n $(site_auth_user "$f") ]] || { info "Kein Passwortschutz vorhanden"; exit 0; }
      snap=$(snapshot); remove_auth_block "$f"
      commit_change "$snap" && ok "Passwortschutz entfernt" ;;
    remove)
      local f snap; f=$(cli_find "${1:-}") || { err "Nicht gefunden: ${1:-}"; exit 1; }
      snap=$(snapshot); rm -f "$f"; commit_change "$snap" ;;
    enable)
      local f snap; f=$(cli_find "${1:-}") || { err "Nicht gefunden"; exit 1; }
      [[ $f == *.disabled ]] || { info "Bereits aktiv"; exit 0; }
      snap=$(snapshot); mv "$f" "${f%.disabled}"; commit_change "$snap" ;;
    disable)
      local f snap; f=$(cli_find "${1:-}") || { err "Nicht gefunden"; exit 1; }
      [[ $f == *.disabled ]] && { info "Bereits deaktiviert"; exit 0; }
      snap=$(snapshot); mv "$f" "$f.disabled"; commit_change "$snap" ;;
    validate) out=$(validate_config) && ok "Gültig" || { err "Fehler"; echo "$out"; exit 1; } ;;
    reload)   reload_caddy ;;
    backup)   ensure_dirs; ok "Backup: $(snapshot)" ;;
    setup)    ensure_dirs; main_is_setup || { printf '\n%s\n' "$(IMPORT_LINE)" >>"$CADDYFILE"; }; ok "Eingerichtet" ;;
    help|-h|--help) usage ;;
    *) usage; exit 2 ;;
  esac
}

# ── Hauptmenü ────────────────────────────────────────────────────────────────
main_menu() {
  have caddy || warn "Caddy ist nicht installiert – Menüpunkt „Caddy-Dienst → Installieren“ nutzen."
  main_is_setup || { [[ -t 0 ]] && { warn "Haupt-Caddyfile noch nicht eingerichtet."; confirm "Jetzt einrichten?" j && setup_main; }; }
  if [[ -f $CADDYFILE ]]; then
    local scan; scan=$(mktemp -d); split_caddyfile "$scan"; rm -rf "$scan"
    ((IMPORT_COUNT > 0)) && warn "$IMPORT_COUNT bestehende(r) Block/Blöcke in der Caddyfile – Menüpunkt 13 übernimmt sie in die Verwaltung."
  fi
  while true; do
    menu "Hauptmenü" \
      "🔀 Neue Domain → Reverse-Proxy (App/Backend)" \
      "↪  Neue Weiterleitung (Domain → andere URL)" \
      "🔁 www ↔ ohne www weiterleiten" \
      "📁 Neue statische Website / SPA" \
      "🚧 Wartungsseite einrichten" \
      "➕ Regel zu bestehender Seite (Pfad-Redirect, Sperre, IP-Filter, Passwortschutz)" \
      "📋 Alle Seiten anzeigen" \
      "🗂  Seiten verwalten (bearbeiten, ein/aus, löschen)" \
      "🔍 Prüfen & Diagnose" \
      "⚙  Caddy-Dienst" \
      "💾 Backups & Wiederherstellung" \
      "🛠  Globale Einstellungen" \
      "📥 Bestehende Caddyfile-Blöcke übernehmen" \
      "🚪 Beenden"
    case $MENU_IDX in
      0) add_proxy ;;
      1) add_redirect ;;
      2) add_www_redirect ;;
      3) add_static ;;
      4) add_maintenance ;;
      5) add_rule ;;
      6) list_sites_screen ;;
      7) manage_sites ;;
      8) diagnose_menu ;;
      9) service_menu ;;
      10) backup_menu ;;
      11) global_menu ;;
      12) import_menu ;;
      13|-1) clear_screen; echo "  Tschüss!"; return 0 ;;
    esac
  done
}

# ── Start ────────────────────────────────────────────────────────────────────
ensure_root "$@"
ensure_dirs 2>/dev/null || { err "Kann $CADDY_DIR nicht beschreiben."; exit 1; }
if (($# > 0)); then cli "$@"; else main_menu; fi
