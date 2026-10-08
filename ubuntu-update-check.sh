#!/usr/bin/env bash

# Ubuntu Server Update Audit
# Entwickler: Bernd Geier
# Copyright (c) 2026 Bernd Geier
# Lizenz: MIT License
# SPDX-License-Identifier: MIT
#

SCRIPT_NAME="Ubuntu Server Update Audit"
SCRIPT_VERSION="1.7.3"
SCRIPT_DATE="2026-10-08"
SCRIPT_TARGETS="Ubuntu Server 22.04 / 24.04 / 26.04 LTS"
# ubuntu-update-check.sh
# Read-only audit for Ubuntu Server 22.04 LTS / 24.04 LTS / 26.04 LTS.
# Does NOT install updates and does NOT change APT configuration.
set -u

AUDIT_ERRORS=0
AUDIT_WARNINGS=0
AUDIT_INACTIVE=0
AUDIT_REBOOT=0
AUDIT_TIMER_ERRORS=0
export LC_ALL=C

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'
  C=$'\033[36m'; W=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; C=""; W=""; D=""; N=""
fi

ok()   { printf "%s[AKTIV]%s  %s\n" "$G" "$N" "$*"; }
bad() {
    AUDIT_INACTIVE=$((AUDIT_INACTIVE + 1))
    AUDIT_WARNINGS=$((AUDIT_WARNINGS + 1))
    printf "%s[INAKTIV]%s %s\n" "$R" "$N" "$*"
}
warn() {
    AUDIT_WARNINGS=$((AUDIT_WARNINGS + 1))
    printf "%s[WARNUNG]%s %s\n" "$Y" "$N" "$*"
}
upd()  { printf "%s[UPDATE]%s  %s\n" "$Y" "$N" "$*"; }
reb()  { printf "%s[REBOOT]%s  %s\n" "$Y" "$N" "$*"; }
info() { printf "%s[INFO]%s   %s\n" "$C" "$N" "$*"; }
head1(){ printf "\n%s%s=== %s ===%s\n" "$W" "$B" "$*" "$N"; }
kv()   { printf "  %-27s %s\n" "$1:" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }

APT_DUMP=""
if have apt-config; then APT_DUMP="$(apt-config dump 2>/dev/null || true)"; fi
aptval() {
  local key="$1"
  awk -v k="$key" '$1==k {gsub(/[";]/,"",$2); print $2; exit}' <<<"$APT_DUMP"
}

if [[ ! -r /etc/os-release ]]; then
  printf "%s[FEHLER]%s /etc/os-release nicht lesbar.\n" "$R" "$N"
  exit 2
fi
. /etc/os-release


# Prüft systemd-Calendar-Timer auf einen plausiblen nächsten Lauf und auf
# Abweichungen zwischen OnCalendar-Konfiguration und tatsächlichem Zustand.

error() {
    AUDIT_ERRORS=$((AUDIT_ERRORS + 1))
    if [[ "${NO_COLOR:-0}" == "1" ]]; then
        printf '[FEHLER] %s\n' "$*"
    else
        printf '%b[FEHLER]%b %s\n' '\033[1;31m' '\033[0m' "$*"
    fi
}

audit_calendar_timer() {
    local unit="$1"
    local active sub result last next_rt next_mono calendars cal_expr expected enabled
    local last_epoch now_epoch age_days max_age_days

    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    active="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)"
    sub="$(systemctl show "$unit" -p SubState --value 2>/dev/null || true)"
    result="$(systemctl show "$unit" -p Result --value 2>/dev/null || true)"
    last="$(systemctl show "$unit" -p LastTriggerUSec --value 2>/dev/null || true)"
    next_rt="$(systemctl show "$unit" -p NextElapseUSecRealtime --value 2>/dev/null || true)"
    next_mono="$(systemctl show "$unit" -p NextElapseUSecMonotonic --value 2>/dev/null || true)"
    calendars="$(systemctl show "$unit" -p TimersCalendar --value 2>/dev/null || true)"

    echo "  $unit"
    kv "  Enabled" "${enabled:-unbekannt}"
    kv "  Zustand" "${active:-unbekannt}/${sub:-unbekannt}"
    [[ -n "$last" ]] && kv "  Letzter Lauf" "$last"
    if [[ -n "$next_rt" ]]; then
        kv "  Nächster Lauf" "$next_rt"
    else
        kv "  Nächster Lauf" "FEHLT"
    fi

    # APT-Calendar-Timer sollten nach dem Aktivieren auf den nächsten Termin warten.
    if [[ "$active" == "active" && "$sub" != "waiting" ]]; then
        AUDIT_TIMER_ERRORS=$((AUDIT_TIMER_ERRORS + 1))
        error "$unit ist aktiv, aber SubState=${sub:-unbekannt} statt waiting"
    fi

    # Ein aktiver Calendar-Timer mit leerem NEXT bzw. infinity ist fehlerhaft,
    # sofern seine OnCalendar-Regel grundsätzlich einen Termin ergibt.
    if [[ "$active" == "active" && ( -z "$next_rt" || "$next_mono" == "infinity" ) ]]; then
        cal_expr="$(systemctl cat "$unit" 2>/dev/null | sed -n 's/^[[:space:]]*OnCalendar=//p' | tail -1)"
        if [[ -n "$cal_expr" ]] && command -v systemd-analyze >/dev/null 2>&1; then
            expected="$(systemd-analyze calendar "$cal_expr" 2>/dev/null | sed -n 's/^[[:space:]]*Next elapse:[[:space:]]*//p' | head -1)"
            if [[ -n "$expected" ]]; then
                AUDIT_TIMER_ERRORS=$((AUDIT_TIMER_ERRORS + 1))
                error "$unit hat keinen nächsten Trigger, obwohl OnCalendar einen Termin ergibt"
                kv "  OnCalendar" "$cal_expr"
                kv "  Rechnerisch nächster Termin" "$expected"
            else
                AUDIT_TIMER_ERRORS=$((AUDIT_TIMER_ERRORS + 1))
                error "$unit hat keinen nächsten Trigger"
            fi
        else
            AUDIT_TIMER_ERRORS=$((AUDIT_TIMER_ERRORS + 1))
            error "$unit hat keinen nächsten Trigger"
        fi
    fi

    # Für die Ubuntu-APT-Timer ist ein letzter Lauf, der mehrere Tage zurückliegt,
    # nicht mit der täglichen Konfiguration vereinbar. Großzügige Schwelle wegen
    # RandomizedDelaySec und möglichen kurzen Ausfallzeiten.
    max_age_days=3
    if [[ -n "$last" && "$last" != "n/a" ]]; then
        last_epoch="$(date -d "$last" +%s 2>/dev/null || true)"
        now_epoch="$(date +%s)"
        if [[ "$last_epoch" =~ ^[0-9]+$ ]]; then
            age_days=$(( (now_epoch - last_epoch) / 86400 ))
            if (( age_days > max_age_days )); then
                AUDIT_TIMER_ERRORS=$((AUDIT_TIMER_ERRORS + 1))
                error "$unit letzter Lauf liegt ${age_days} Tage zurück; das passt nicht zu einem täglichen APT-Timer"
            fi
        fi
    else
        warn "$unit hat keinen aufgezeichneten letzten Lauf"
    fi

    if [[ -n "$result" && "$result" != "success" ]]; then
        AUDIT_TIMER_ERRORS=$((AUDIT_TIMER_ERRORS + 1))
        error "$unit meldet Result=$result"
    fi
}

head1 "$SCRIPT_NAME"
kv "Script Version" "$SCRIPT_VERSION"
kv "Script Stand" "$SCRIPT_DATE"
kv "Zielsysteme" "$SCRIPT_TARGETS"
kv "Zeit" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
kv "Hostname" "$(hostname -f 2>/dev/null || hostname)"
kv "OS" "${PRETTY_NAME:-unbekannt}"
kv "Codename" "${VERSION_CODENAME:-unbekannt}"
kv "Architektur" "$(dpkg --print-architecture 2>/dev/null || uname -m)"
kv "Kernel laufend" "$(uname -r)"
kv "Uptime" "$(uptime -p 2>/dev/null || true)"

case "${VERSION_ID:-}" in
  22.04|24.04|26.04) ok "Unterstützte Script-Zielversion: Ubuntu ${VERSION_ID} LTS (${VERSION_CODENAME:-unbekannt})" ;;
  *) warn "Nicht offiziell unterstützte Script-Zielversion erkannt: Ubuntu ${VERSION_ID:-unbekannt}" ;;
esac

head1 "Unattended Upgrades"
UU_INSTALLED=0
if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
  UU_INSTALLED=1
  ok "Paket unattended-upgrades ist installiert ($(dpkg-query -W -f='${Version}' unattended-upgrades 2>/dev/null))"
else
  bad "Paket unattended-upgrades ist nicht installiert"
fi

periodic="$(aptval 'APT::Periodic::Unattended-Upgrade')"
lists="$(aptval 'APT::Periodic::Update-Package-Lists')"
[[ "$periodic" == "1" ]] && ok "Automatische Upgrades: täglich (APT::Periodic::Unattended-Upgrade=1)" \
  || bad "Automatische Upgrades nicht täglich aktiviert (Wert: ${periodic:-nicht gesetzt})"
[[ "$lists" == "1" ]] && ok "Paketlisten: täglich aktualisieren" \
  || warn "Paketlisten-Intervall: ${lists:-nicht gesetzt}"

reboot="$(aptval 'Unattended-Upgrade::Automatic-Reboot')"
reboot_users="$(aptval 'Unattended-Upgrade::Automatic-Reboot-WithUsers')"
reboot_time="$(aptval 'Unattended-Upgrade::Automatic-Reboot-Time')"
[[ "$reboot" == "true" ]] && ok "Automatischer Reboot bei Bedarf: JA, Zeit ${reboot_time:-nicht gesetzt}" \
  || info "Automatischer Reboot bei Bedarf: ${reboot:-nicht gesetzt}"
kv "Reboot mit Usern" "${reboot_users:-nicht gesetzt}"

if [[ -f /var/run/reboot-required ]]; then
    AUDIT_REBOOT=1
  reb "System verlangt aktuell einen Neustart (Uptime: $(uptime -p 2>/dev/null || echo unbekannt))"
  [[ -r /var/run/reboot-required.pkgs ]] && sed 's/^/           - /' /var/run/reboot-required.pkgs
else
  ok "Aktuell kein /var/run/reboot-required"
fi

head1 "Systemzeit / NTP"
if command -v timedatectl >/dev/null 2>&1; then
    clock_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    ntp_service="$(timedatectl show -p NTP --value 2>/dev/null || true)"
    timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    kv "Zeitzone" "${timezone:-unbekannt}"
    if [[ "$clock_sync" == "yes" ]]; then
        ok "Systemuhr ist per NTP synchronisiert"
    else
        warn "Systemuhr ist nicht als NTP-synchronisiert gemeldet"
    fi
    [[ -n "$ntp_service" ]] && kv "NTP aktiviert" "$ntp_service"
fi
if command -v systemctl >/dev/null 2>&1; then
    systemd_ver="$(systemctl --version 2>/dev/null | head -1)"
    kv "systemd" "${systemd_ver:-unbekannt}"
fi
echo

head1 "APT systemd Timer"
audit_calendar_timer "apt-daily.timer"
audit_calendar_timer "apt-daily-upgrade.timer"

head1 "Erlaubte unattended-upgrades Quellen"
if have unattended-upgrade; then
# Snapshot des unattended-upgrades-Logs VOR dem aktuellen Audit-Dry-Run.
UU_LOG_SNAPSHOT=""
UU_LOG_MTIME_SNAPSHOT=""
if [[ -r /var/log/unattended-upgrades/unattended-upgrades.log ]]; then
    UU_LOG_SNAPSHOT="$(tail -n 500 /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null || true)"
    UU_LOG_MTIME_SNAPSHOT="$(stat -c '%y' /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null | cut -d. -f1 || true)"
fi

  dry="$(timeout 90 unattended-upgrade --dry-run --debug 2>&1 || true)"
  allowed="$(grep -m1 '^Allowed origins are:' <<<"$dry" || true)"
  if [[ -n "$allowed" ]]; then
    ok "${allowed#Allowed origins are: }"
  else
    warn "Allowed Origins konnten im Dry-Run nicht ermittelt werden"
  fi
  if grep -q 'InstCount=0' <<<"$dry"; then
    info "Dry-Run: derzeit keine von unattended-upgrades ausgewählten Installationen"
  elif grep -qE 'InstCount=[1-9]' <<<"$dry"; then
    warn "Dry-Run würde Updates installieren"
    grep -E 'InstCount=' <<<"$dry" | tail -1 | sed 's/^/           /'
  fi
else
  warn "unattended-upgrade Befehl fehlt"
fi

head1 "APT Repositories"
if have apt-get; then
  apt-get indextargets --format '$(SITE) | $(RELEASE) | $(COMPONENT) | $(ARCHITECTURE)' 2>/dev/null |
    grep -v '\$(ARCHITECTURE)' | awk 'NF && !seen[$0]++' | sort | sed 's/^/  /'
else
  warn "apt-get fehlt"
fi

head1 "APT Proxy"
proxy_http="$(aptval 'Acquire::http::Proxy')"
proxy_https="$(aptval 'Acquire::https::Proxy')"
proxy_ftp="$(aptval 'Acquire::ftp::Proxy')"
if [[ -n "$proxy_http$proxy_https$proxy_ftp" ]]; then
  warn "APT-Proxy konfiguriert"
  [[ -n "$proxy_http" ]]  && kv "HTTP Proxy" "$proxy_http"
  [[ -n "$proxy_https" ]] && kv "HTTPS Proxy" "$proxy_https"
  [[ -n "$proxy_ftp" ]]   && kv "FTP Proxy" "$proxy_ftp"
else
  ok "Kein globaler APT Acquire-Proxy konfiguriert"
fi
for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
  [[ -n "${!v:-}" ]] && kv "Environment $v" "${!v}"
done

head1 "Ubuntu Pro / ESM / Livepatch"
ESM_APPS=0
ESM_INFRA=0
LIVEPATCH=0
if have pro; then
  pro_status="$(pro status 2>/dev/null || true)"
  if grep -qi 'esm-apps.*enabled' <<<"$pro_status"; then ESM_APPS=1; ok "ESM Apps aktiviert"; else info "ESM Apps nicht aktiviert/erkannt (kein ESM-Apps-Schutz)"; fi
  if grep -qi 'esm-infra.*enabled' <<<"$pro_status"; then ESM_INFRA=1; ok "ESM Infra aktiviert"; else info "ESM Infra nicht aktiviert/erkannt"; fi
  if grep -qi 'livepatch.*enabled' <<<"$pro_status"; then LIVEPATCH=1; ok "Livepatch aktiviert"; else info "Livepatch nicht aktiviert/erkannt"; fi
else
  info "'pro' CLI nicht vorhanden; ESM/Livepatch nicht als aktiv nachweisbar"
fi

head1 "Effektive Update-Policy"
if [[ "$UU_INSTALLED" != "1" ]]; then
  printf "%s[INAKTIV]%s unattended-upgrades nicht verfügbar: Paket ist nicht installiert\n" "$R" "$N"
  if [[ "$periodic" == "1" ]]; then
    info "APT::Periodic::Unattended-Upgrade=1 ist konfiguriert, kann aber ohne unattended-upgrades nicht ausgeführt werden"
  else
    info "APT::Periodic::Unattended-Upgrade=${periodic:-nicht gesetzt}"
  fi
  warn "Ubuntu Security Updates: automatische Installation nicht prüfbar"
  info "Normale Ubuntu Updates (*-updates): automatische Installation nicht prüfbar"
  info "Ubuntu Kernel-Updates: automatische unattended-upgrades-Policy nicht prüfbar"
else
  if [[ "$periodic" == "1" ]]; then
    ok "unattended-upgrades wird täglich ausgeführt"
  else
    printf "%s[INAKTIV]%s unattended-upgrades ist nicht täglich aktiviert\n" "$R" "$N"
  fi

  if [[ -n "${allowed:-}" ]] && grep -q "a=${VERSION_CODENAME:-}-security" <<<"$allowed"; then
    ok "Ubuntu Security Updates: automatisch erlaubt"
  else
    warn "Ubuntu Security Updates: nicht eindeutig automatisch erlaubt"
  fi
  if [[ -n "${allowed:-}" ]] && grep -q "a=${VERSION_CODENAME:-}-updates" <<<"$allowed"; then
    ok "Normale Ubuntu Updates (*-updates): automatisch erlaubt"
    ok "Reguläre Ubuntu Kernel-Updates aus *-updates: automatisch erlaubt (sofern nicht per Paket-Blacklist ausgeschlossen)"
  else
    info "Normale Ubuntu Updates (*-updates): nicht automatisch erlaubt"
    info "Reguläre Kernel-Updates aus *-updates: nicht automatisch erlaubt; Security-Kernelupdates können weiterhin über *-security erlaubt sein"
  fi
fi

if [[ "$ESM_APPS" == "1" || "$ESM_INFRA" == "1" ]]; then
  ok "Ubuntu Pro / ESM: mindestens ein ESM-Dienst aktiv"
else
  info "Ubuntu Pro / ESM: nicht aktiv; ESM-exklusive Updates werden nicht installiert"
fi

if [[ "$reboot" == "true" ]]; then
  ok "Automatischer Reboot bei Bedarf: aktiv (${reboot_time:-Zeit nicht gesetzt})"
  [[ "$reboot_users" == "false" ]] && info "Automatischer Reboot wird bei angemeldeten Benutzern nicht erzwungen"
elif [[ "$reboot" == "false" ]]; then
  info "Automatischer Reboot bei Bedarf: deaktiviert"
else
  info "Automatischer Reboot bei Bedarf: nicht konfiguriert"
fi

repo_sites="$(apt-get indextargets --format '$(SITE)' 2>/dev/null | sort -u || true)"
if grep -qi 'download.docker.com' <<<"$repo_sites"; then
  if [[ -n "${allowed:-}" ]] && grep -qiE 'o=(Docker|docker)' <<<"$allowed"; then
    ok "Docker Repository: für unattended-upgrades freigegeben (Origin Docker)"
  else
    info "Docker Repository: vorhanden, aber nicht automatisch freigegeben"
  fi
fi
if grep -qi 'repo.fortimonitor.com' <<<"$repo_sites"; then
  if [[ -n "${allowed:-}" ]] && grep -qiE 'o=.*(FortiMonitor|Panopta)' <<<"$allowed"; then
    ok "FortiMonitor Repository: für unattended-upgrades freigegeben"
  else
    info "FortiMonitor Repository: Drittanbieterquelle, nicht automatisch freigegeben"
  fi
fi

head1 "Verfügbare Updates"
# apt-get -s dist-upgrade is read-only and gives a robust total set without parsing apt's unstable UI.
sim="$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null || true)"
mapfile -t up_pkgs < <(awk '/^Inst / {print $2}' <<<"$sim" | sort -u)
total=${#up_pkgs[@]}
if (( total == 0 )); then
  ok "Keine normalen APT-Upgrades laut Simulation"
else
  upd "$total Paket(e) grundsätzlich aktualisierbar"
fi

# Classify each simulated upgrade using apt-cache policy.
# A candidate can exist in multiple Ubuntu pockets simultaneously. We inspect
# all source lines belonging to the exact Candidate version.
security=()
kernel=()
thirdparty=()
for p in "${up_pkgs[@]}"; do
  pol="$(apt-cache policy "$p" 2>/dev/null || true)"
  cand="$(awk '/Candidate:/ {print $2; exit}' <<<"$pol")"

  [[ "$p" =~ ^linux-(image|headers|modules|generic|virtual|tools|signed)|^linux-generic|^linux-virtual ]] && kernel+=("$p")

  [[ -z "$cand" || "$cand" == "(none)" ]] && continue

  # Extract repository lines for the exact candidate version. A version block
  # ends when apt-cache policy starts the next version entry.
  src_lines="$(awk -v c="$cand" '
    BEGIN { inver=0 }
    {
      line=$0
      t=$0
      sub(/^[[:space:]]+/,"",t)
      if (t ~ /^\*\*\*[[:space:]]+/) sub(/^\*\*\*[[:space:]]+/,"",t)
      split(t,a,/[[:space:]]+/)
      if (a[1] == c) { inver=1; next }
      if (inver && t ~ /^[^[:space:]]+[[:space:]]+[0-9]+$/) exit
      if (inver) print line
    }' <<<"$pol")"

  # Ubuntu security pocket for the candidate.
  if grep -Eq 'https?://[^ ]*(security\.ubuntu\.com|([a-z]{2}\.)?archive\.ubuntu\.com|ports\.ubuntu\.com|old-releases\.ubuntu\.com)/ubuntu[^ ]*[[:space:]]+[^ ]*-security/' <<<"$src_lines"; then
    security+=("$p")
  fi

  # Third party only if at least one candidate source URL exists and none of
  # those candidate URLs belongs to an official Ubuntu archive.
  urls="$(grep -Eo 'https?://[^ ]+' <<<"$src_lines" || true)"
  if [[ -n "$urls" ]] && ! grep -Eq 'https?://[^ ]*(security\.ubuntu\.com|([a-z]{2}\.)?archive\.ubuntu\.com|ports\.ubuntu\.com|esm\.ubuntu\.com|old-releases\.ubuntu\.com)/' <<<"$urls"; then
    thirdparty+=("$p")
  fi
done

if (( ${#security[@]} )); then
  upd "${#security[@]} Security-Update(s) anhand Candidate/Origin erkannt:"
  printf '           - %s\n' "${security[@]}"
else
  ok "Keine aus *-security angebotenen Candidate-Updates erkannt"
fi

if (( ${#kernel[@]} )); then
  upd "${#kernel[@]} Kernel-/Kernel-Metapaket-Update(s) in der APT-Simulation:"
  printf '           - %s\n' "${kernel[@]}"
else
  ok "Keine Kernel-Pakete in der aktuellen Upgrade-Simulation"
fi

if (( ${#thirdparty[@]} )); then
  upd "${#thirdparty[@]} Update(s) aus Drittanbieter-Repositories erkannt:"
  printf '           - %s\n' "${thirdparty[@]}"
fi

if (( total > 0 )); then
  info "Alle Upgrade-Pakete:"
  printf '           - %s\n' "${up_pkgs[@]}"
fi

head1 "Kernel"
running="$(uname -r)"
kv "Laufender Kernel" "$running"
if have dpkg-query; then
  newest="$(dpkg-query -W -f='${Package} ${Version}\n' 'linux-image-*' 2>/dev/null |
    awk '$1 !~ /unsigned/ {print $2" "$1}' | sort -V | tail -1)"
  [[ -n "$newest" ]] && kv "Höchstes installiertes Image" "$newest"
fi
apt-cache policy linux-generic linux-image-generic linux-virtual linux-image-virtual 2>/dev/null |
  awk '/^[a-z].*:$/ || /Installed:|Candidate:/ {print "  "$0}'

head1 "unattended-upgrades Log"
if [[ -n "${UU_LOG_SNAPSHOT:-}" ]]; then
    [[ -n "${UU_LOG_MTIME_SNAPSHOT:-}" ]] && kv "Log geändert (vor aktuellem Audit)" "$UU_LOG_MTIME_SNAPSHOT"
    last_start="$(printf '%s\n' "$UU_LOG_SNAPSHOT" | grep 'Starting unattended upgrades script' | tail -1 || true)"
    last_result="$(printf '%s\n' "$UU_LOG_SNAPSHOT" | grep -E 'No packages found|Packages that will be upgraded|All upgrades installed|ERROR|WARNING' | tail -1 || true)"
    [[ -n "$last_start" ]] && printf '  Letzter protokollierter Start: %s\n' "$last_start"
    [[ -n "$last_result" ]] && printf '  Letztes protokolliertes Ergebnis: %s\n' "$last_result"
    info "Hinweis: Ein protokollierter Lauf kann auch von einem manuellen oder Audit-Dry-Run stammen."
else
    info "Kein lesbares unattended-upgrades-Log vor dem Audit gefunden."
fi

head1 "Zusammenfassung"

if (( AUDIT_TIMER_ERRORS > 0 )); then
    if [[ "${NO_COLOR:-0}" == "1" ]]; then
        printf '[FEHLER] APT-Timer funktionieren nicht ordnungsgemäß (%d Timer-Probleme erkannt).\n' "$AUDIT_TIMER_ERRORS"
    else
        printf '%b[FEHLER]%b APT-Timer funktionieren nicht ordnungsgemäß (%d Timer-Probleme erkannt).\n' '\033[1;31m' '\033[0m' "$AUDIT_TIMER_ERRORS"
    fi
fi

if (( AUDIT_REBOOT > 0 )); then
    if [[ "${NO_COLOR:-0}" == "1" ]]; then
        printf '[REBOOT] Neustart des Systems erforderlich.\n'
    else
        printf '%b[REBOOT]%b Neustart des Systems erforderlich.\n' '\033[1;35m' '\033[0m'
    fi
fi

if (( AUDIT_ERRORS == 0 && AUDIT_WARNINGS == 0 && AUDIT_REBOOT == 0 )); then
    ok "Keine Audit-Fehler, Warnungen oder ausstehenden Neustarts erkannt."
elif (( AUDIT_ERRORS == 0 )); then
    warn_count="$AUDIT_WARNINGS"
    printf '[INFO]   Audit-Warnungen: %s\n' "$warn_count"
fi

printf '\n'
kv "Fehler" "$AUDIT_ERRORS"
kv "Warnungen" "$AUDIT_WARNINGS"
kv "Inaktive Funktionen" "$AUDIT_INACTIVE"
kv "Reboot erforderlich" "$([[ "$AUDIT_REBOOT" -gt 0 ]] && echo ja || echo nein)"
if [[ "$reboot" == "true" ]]; then
  auto_reboot_summary="aktiv"
elif [[ "$reboot" == "false" ]]; then
  auto_reboot_summary="inaktiv"
else
  auto_reboot_summary="nicht konfiguriert"
fi
kv "Auto-Reboot Policy" "$auto_reboot_summary"

if [[ "$UU_INSTALLED" != "1" ]]; then
  updates_summary="nicht prüfbar"
elif [[ -n "${allowed:-}" ]] && grep -q "a=${VERSION_CODENAME:-}-updates" <<<"$allowed"; then
  updates_summary="automatisch"
else
  updates_summary="nicht automatisch"
fi
kv "Ubuntu *-updates" "$updates_summary"
kv "Ubuntu Pro / ESM" "$([[ "$ESM_APPS" == "1" || "$ESM_INFRA" == "1" ]] && echo aktiv || echo nicht aktiv)"

if (( AUDIT_ERRORS > 0 )); then
    if [[ "${NO_COLOR:-0}" == "1" ]]; then
        printf '[FEHLER] Gesamtstatus: FEHLER\n'
    else
        printf '%b[FEHLER]%b Gesamtstatus: FEHLER\n' '\033[1;31m' '\033[0m'
    fi
    exit 2
elif (( AUDIT_WARNINGS > 0 || AUDIT_REBOOT > 0 )); then
    if [[ "${NO_COLOR:-0}" == "1" ]]; then
        printf '[WARNUNG] Gesamtstatus: WARNUNG\n'
    else
        printf '%b[WARNUNG]%b Gesamtstatus: WARNUNG\n' '\033[1;33m' '\033[0m'
    fi
    exit 1
else
    ok "Gesamtstatus: OK"
    exit 0
fi
