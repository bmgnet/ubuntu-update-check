# Ubuntu Server Update Audit

**Script-Version:** 1.7.2
**Stand:** 2026-10-02

**Dokumentationsstand:** v1.7.2

Read-only Prüfscript für Ubuntu Server **22.04 LTS**, **24.04 LTS** und
**26.04 LTS**. Es kontrolliert automatische Sicherheitsupdates,
APT/systemd-Timer, Updatequellen, Kernelstatus und ausstehende
Neustarts.

## Entwicklung und Lizenz

- **Entwickler:** Bernd Geier
- **Copyright:** © 2026 Bernd Geier
- **Lizenz:** MIT License
- **SPDX-License-Identifier:** `MIT`
- **Open Source:** Ja

Das Projekt wird unter der MIT-Lizenz veröffentlicht. Nutzung, Kopieren, Ändern und Weiterverbreiten sind unter den Bedingungen der MIT-Lizenz gestattet. Der Copyright- und Lizenzhinweis muss bei Kopien bzw. wesentlichen Teilen der Software erhalten bleiben.

Die vollständigen Lizenzbedingungen befinden sich in der Datei `LICENSE`.

## Installation

``` bash
sudo install -m 0755 ubuntu-update-check.sh /usr/local/sbin/ubuntu-update-check
sudo ubuntu-update-check
echo "Exit-Code: $?"
```

Ohne Farben:

``` bash
sudo NO_COLOR=1 ubuntu-update-check
```

Das Script führt kein `apt update`, keine Paketinstallation und keine
automatische Reparatur durch. Die Prüfung basiert daher auf den aktuell
lokal vorhandenen APT-Paketlisten.

Für einen aktuellen Paketstand kann vorher bewusst ausgeführt werden:

``` bash
sudo apt update
sudo ubuntu-update-check
```

## Geprüfte Bereiche

-   Ubuntu-Version, Codename, Architektur, Kernel und Uptime
-   Installation und effektive Konfiguration von `unattended-upgrades`
-   verständliche effektive Update-Policy: Security, normale Ubuntu-Updates, ESM, Drittanbieter und Auto-Reboot
-   `APT::Periodic::*` und automatische Reboot-Einstellungen
-   `/var/run/reboot-required`, betroffene Pakete und aktuelle Uptime direkt in der Reboot-Meldung
-   Systemzeit, Zeitzone und NTP-Synchronisierung
-   `apt-daily.timer` und `apt-daily-upgrade.timer`
-   Timer-Zustand `active/waiting`, letzter und nächster Trigger
-   Plausibilitätsprüfung von `OnCalendar` mit
    `systemd-analyze calendar`
-   Erkennung von `active/running` ohne nächsten Trigger
-   Allowed Origins über einen `unattended-upgrade --dry-run --debug`
-   konfigurierte/eingelesene APT-Repositories
-   APT-Proxy und Proxy-Umgebungsvariablen
-   Ubuntu Pro, ESM und Livepatch
-   normale verfügbare Updates
-   Security-Candidates aus `*-security`
-   Kernel- und Kernel-Metapaket-Updates
-   Hinweise auf Updates aus Drittanbieter-Repositories
-   laufender, installierter und angebotener Kernel
-   letzter protokollierter unattended-upgrades-Betrieb
-   zusammengefasster Auditstatus und maschinenlesbarer Exit-Code


## Effektive Update-Policy (ab v1.7.0)

Der Report unterscheidet nun ausdrücklich zwischen einem laufenden `unattended-upgrades`-Timer und den Quellen, aus denen tatsächlich automatisch installiert werden darf. Dadurch ist beispielsweise sichtbar, ob `noble-security` und `noble-updates` automatisch erlaubt sind, ob Ubuntu Pro/ESM tatsächlich aktiviert ist und ob ein automatischer Reboot konfiguriert wurde.

Ein typisches gewünschtes Serverprofil kann damit so erscheinen:

``` text
=== Effektive Update-Policy ===
[AKTIV]  unattended-upgrades wird täglich ausgeführt
[AKTIV]  Ubuntu Security Updates: automatisch erlaubt
[AKTIV]  Normale Ubuntu Updates (*-updates): automatisch erlaubt
[INFO]   Ubuntu Pro / ESM: nicht aktiv; ESM-exklusive Updates werden nicht installiert
[AKTIV]  Automatischer Reboot bei Bedarf: aktiv (03:30)
[INFO]   Docker Repository: vorhanden, aber nicht in den ermittelten Allowed Origins freigegeben
```

Wenn `/var/run/reboot-required` vorhanden ist, enthält die Reboot-Meldung zusätzlich die aktuelle Uptime. Das hilft einzuschätzen, wie lange ein bereits notwendiger Neustart möglicherweise aussteht.

### Docker automatisch mit unattended-upgrades aktualisieren

Docker CE ist ein Drittanbieter-Repository. Ein vorhandenes `download.docker.com`-Repository bedeutet **nicht**, dass Docker-Pakete automatisch durch `unattended-upgrades` installiert werden.

Die Anleitung ist generisch für Ubuntu 22.04, 24.04 und 26.04: Repository-Metadaten werden auf dem jeweiligen Host ermittelt; ein Ubuntu-Codename wird nicht fest verdrahtet.

#### 1. Repository-Metadaten ermitteln

```bash
sudo apt update

grep -hE '^(Origin|Label|Suite|Codename):' \
  /var/lib/apt/lists/*download.docker.com*InRelease \
  /var/lib/apt/lists/*download.docker.com*Release 2>/dev/null
```

Beim offiziellen Docker-CE-Repository sind beispielsweise Werte wie `Origin: Docker`, `Label: Docker CE` und `Suite: noble` möglich. Maßgeblich sind immer die tatsächlich ausgegebenen Werte.

#### 2. Docker als zusätzliche Allowed Origin konfigurieren

Die bestehende Ubuntu-Liste soll nicht durch einen zweiten vollständigen `Allowed-Origins`-Block ersetzt werden. Eine spätere lokale APT-Datei kann einen Listeneintrag ergänzen:

```bash
sudo tee /etc/apt/apt.conf.d/53unattended-upgrades-docker >/dev/null <<'EOF'
Unattended-Upgrade::Allowed-Origins:: "Docker:${distro_codename}";
EOF
```

`${distro_codename}` wird vom APT-Kontext des jeweiligen Ubuntu-Systems aufgelöst. Falls die ermittelten Docker-Metadaten abweichen, diese Beispielregel nicht blind übernehmen.

#### 3. Effektive Konfiguration und Auswahl prüfen

```bash
apt-config dump | grep -A30 '^Unattended-Upgrade::Allowed-Origins'
sudo unattended-upgrade --dry-run --debug
apt-cache policy docker-ce
```

Docker muss im Dry-Run unter den erlaubten Origins erscheinen. Ist ein Update verfügbar, sollten die betreffenden Docker-Pakete zur Installation ausgewählt werden.

#### 4. Betriebsrisiko

Ein automatisches Upgrade von Docker-Komponenten kann Dienste neu starten und laufende Container beeinflussen. Auf produktiven Systemen sollte Docker nur automatisch freigegeben werden, wenn dies zum Wartungskonzept passt.

Das Audit verändert diese Einstellung niemals selbst. Es erkennt Repository und effektive unattended-upgrades-Policy.

### FortiMonitor

FortiMonitor ist **kein Bestandteil einer normalen Ubuntu-Installation**. Es ist ein Monitoring-Produkt von Fortinet. Der Linux-Agent (`fm-agent`) kann Server, VMs, Dienste und Anwendungen überwachen und verwendet bei einer APT-basierten Installation ein eigenes Repository unter `repo.fortimonitor.com`.

Wenn dieses Repository auf einem Server vorhanden ist, wurde FortiMonitor separat installiert oder durch Provisionierung/Hosting/Administration hinzugefügt. Das Audit behandelt es deshalb als Drittanbieterquelle. Auch FortiMonitor wird nicht automatisch von unattended-upgrades aktualisiert, solange seine tatsächliche Repository-Origin nicht ausdrücklich freigegeben wurde.

## Generische Policy-Erkennung

Das Script ist nicht auf einen bestimmten Server oder Ubuntu-Codename zugeschnitten. Es wertet die effektive Konfiguration des geprüften Systems aus:

```text
Security erlaubt, *-updates nicht erlaubt
→ Security-Policy; normale Ubuntu- und reguläre Kernel-Updates werden nicht allgemein automatisch installiert.

Security + *-updates erlaubt
→ Security- und normale Ubuntu-Updates einschließlich regulärer Kernel-Updates dürfen automatisch installiert werden.

Drittanbieter-Repository vorhanden, Origin nicht erlaubt
→ Pakete können mit APT aktualisierbar sein, werden aber nicht automatisch von unattended-upgrades installiert.
```

ESM-Einträge in `Allowed-Origins` werden getrennt vom tatsächlichen Ubuntu-Pro/ESM-Status bewertet.

## APT/systemd-Timer

Für beide Ubuntu-APT-Timer wird nicht nur geprüft, ob sie `enabled` und
`active` sind. Ein gesunder kalenderbasierter Timer sollte normalerweise
auf seinen nächsten Lauf warten:

``` text
ActiveState=active
SubState=waiting
NextElapseUSecRealtime=<zukünftiger Termin>
```

Ein Zustand wie

``` text
ActiveState=active
SubState=running
NextElapseUSecRealtime=
NextElapseUSecMonotonic=infinity
```

wird als Fehler erkannt, wenn `OnCalendar` gleichzeitig einen gültigen
nächsten Termin ergibt.

Auf einem betroffenen Ubuntu-24.04-System konnte dieser inkonsistente
systemd-Laufzeitzustand durch folgende administrative Schritte behoben
werden:

``` bash
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl restart apt-daily.timer apt-daily-upgrade.timer
```

Diese Befehle werden vom Audit **nicht automatisch ausgeführt**. Das
Script bleibt read-only.

## Dry-Run und unattended-upgrades-Log

Zur Ermittlung der tatsächlich für `unattended-upgrades` zulässigen Pakete
verwendet das Audit `unattended-upgrade --dry-run --debug`.

Dieser Dry-Run kann Einträge im regulären `unattended-upgrades`-Log erzeugen.
Das Audit kann deshalb bei einem vorhandenen Logeintrag nicht zuverlässig
unterscheiden, ob er von einem echten automatischen Lauf, einem manuellen
Dry-Run oder dem Audit selbst stammt. Die Logausgabe wird entsprechend nur
als Information dargestellt und nicht als alleiniger Beweis für einen
tatsächlich installierenden automatischen Lauf verwendet.


## Manuelles APT und automatische Updates

`apt update`, `apt upgrade` und `unattended-upgrades` haben unterschiedliche Aufgaben:

| Befehl/Funktion | Bedeutung |
|---|---|
| `sudo apt update` | Aktualisiert nur die lokalen Paketlisten. Es werden keine Pakete installiert. |
| `sudo apt upgrade` | Installiert verfügbare Upgrades aus den aktivierten APT-Repositories, soweit APT sie im normalen Upgrade durchführen kann. Dazu können auch Docker, Brave oder andere Drittanbieterpakete gehören. |
| `unattended-upgrades` | Installiert automatisch nur Pakete aus den dafür erlaubten Origins/Patterns und unter Beachtung seiner weiteren Regeln. |

Ein Drittanbieter-Repository kann daher bei `apt upgrade` berücksichtigt werden, obwohl es **nicht** automatisch durch `unattended-upgrades` aktualisiert wird.

Beispiel: Ist das offizielle Docker-Repository aktiv und zeigt

```bash
apt-cache policy docker-ce
```

eine neuere Candidate-Version, wird Docker grundsätzlich von einem manuellen `apt upgrade` berücksichtigt. Für eine automatische Installation durch `unattended-upgrades` muss die Docker-Origin zusätzlich erlaubt sein.

Dasselbe Prinzip gilt für andere Drittanbieter-Repositories wie Brave oder Hersteller-Repositories. Das Audit zeigt deshalb allgemeine APT-Updates und die effektive unattended-upgrades-Policy getrennt an.

## Ubuntu Pro und Livepatch

Canonical Livepatch kann bestimmte kritische und hochpriorisierte Kernel-Sicherheitskorrekturen auf einen **laufenden Kernel** anwenden. Dadurch lassen sich sicherheitsbedingte Neustarts reduzieren.

Livepatch ersetzt normale Kernel-Updates und geplante Neustarts jedoch nicht vollständig. Ein neuer Kernel kann weiterhin regulär installiert werden, und Änderungen, die nicht durch Livepatch abgedeckt sind, können weiterhin einen Neustart erfordern.

### Ubuntu Pro Free

Livepatch wird über Ubuntu Pro bereitgestellt. Für berechtigte persönliche bzw. kleine Installationen bietet Canonical eine kostenlose Ubuntu-Pro-Subscription mit einer begrenzten Anzahl von Maschinen an. Vor dem Einsatz auf Produktionssystemen sollten die jeweils aktuellen Canonical-Bedingungen und das Maschinenlimit geprüft werden.

Die grundsätzliche Aktivierung erfolgt nach Bezug eines Ubuntu-Pro-Tokens:

```bash
pro status

sudo pro attach <TOKEN>
sudo pro enable livepatch

pro status
canonical-livepatch status --verbose
```

Das Audit führt diese Befehle **nicht** selbst aus und aktiviert weder Ubuntu Pro noch Livepatch.

### Sinnvolle Verwendung auf Produktionsservern

Für einen Server, der möglichst selten neu gestartet werden soll, kann eine Kombination aus folgenden Maßnahmen sinnvoll sein:

```text
unattended-upgrades        → normale/Security-Updates nach definierter Policy
Livepatch                  → unterstützte Kernel-Sicherheitsfixes ohne sofortigen Reboot
geplantes Wartungsfenster  → verbleibende Kernel-/System-Neustarts kontrolliert durchführen
```

Ein `[INFO] Livepatch nicht aktiviert/erkannt` im Audit ist daher kein Fehler. Es zeigt lediglich, dass der zusätzliche Livepatch-Dienst nicht aktiv erkannt wurde.


## Automatische Updates aktivieren und konfigurieren

Die folgenden Einstellungen sind für Ubuntu Server 22.04, 24.04 und 26.04 LTS gedacht. Verwende in `Allowed-Origins` die Variablen `${distro_id}` und `${distro_codename}` statt einen Codename wie `noble` fest einzutragen.

### 1. Grundlegende tägliche Aktivierung

Wenn das Audit meldet:

```text
[INAKTIV] Automatische Upgrades nicht täglich aktiviert (Wert: 0)
```

prüfe zuerst die effektive Konfiguration:

```bash
apt-config dump | grep -E 'APT::Periodic::(Update-Package-Lists|Unattended-Upgrade)'
```

Eine übliche tägliche Konfiguration ist:

```text
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

Sie kann beispielsweise in `/etc/apt/apt.conf.d/20auto-upgrades` hinterlegt werden:

```bash
sudoedit /etc/apt/apt.conf.d/20auto-upgrades
```

`"1"` bedeutet täglich. `"0"` deaktiviert die jeweilige periodische Aktion. Größere Ganzzahlen geben ein Intervall in Tagen an; für dieses Audit wird `Unattended-Upgrade "1"` als gewünschter täglicher Zustand bewertet.

### 2. Variante A – nur Security-Updates automatisch

Für Server, auf denen ausschließlich Security-Updates automatisch installiert werden sollen, sollte die `Allowed-Origins`-Konfiguration in `/etc/apt/apt.conf.d/50unattended-upgrades` sinngemäß enthalten:

```text
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
};
```

ESM-Einträge sind nur wirksam, wenn die entsprechenden Ubuntu-Pro-Dienste aktiviert und verfügbar sind.

Je nach gewünschter Policy kann auch die Basis-Distribution `${distro_id}:${distro_codename}` erlaubt sein. Vor Änderungen immer die bestehende Konfiguration und die vom Audit ausgegebenen effektiven Allowed Origins prüfen.

### 3. Variante B – Security + normale Updates automatisch

Wenn zusätzlich normale Updates automatisch installiert werden sollen:

```text
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}";
        "${distro_id}:${distro_codename}-security";
        "${distro_id}:${distro_codename}-updates";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
};
```

**Wichtig:** Ist `${distro_codename}-updates` bereits erlaubt und wird anschließend `APT::Periodic::Unattended-Upgrade` von `0` auf `1` gesetzt, können künftig auch normale Updates automatisch installiert werden. Deshalb zuerst die Allowed Origins prüfen und erst danach die Automatik aktivieren.

Drittanbieter-Repositories wie Docker, NodeSource oder Hersteller-Repositories werden nicht automatisch dadurch freigegeben. Sie benötigen eine explizit passende unattended-upgrades-Origin, wenn sie automatisch verarbeitet werden sollen.

### 4. Lokale unattended-upgrades-Policy und automatischer Reboot

Für lokale Einstellungen, die von der Ubuntu-Standarddatei `/etc/apt/apt.conf.d/50unattended-upgrades` getrennt bleiben sollen, empfiehlt diese Dokumentation eine eigene Datei:

```text
/etc/apt/apt.conf.d/52unattended-upgrades-local
```

Die Dateien unter `/etc/apt/apt.conf.d/` werden anhand ihres Dateinamens in Reihenfolge eingelesen. Die `52unattended-upgrades-local` wird daher nach `50unattended-upgrades` verarbeitet und eignet sich für lokale Overrides. Dadurch muss die vom Paket bereitgestellte Standarddatei nicht für jede lokale Policy direkt geändert werden.

#### Empfohlene Policy: kein automatischer Reboot

Für Server, auf denen Updates automatisch installiert, Neustarts aber bewusst manuell durchgeführt werden sollen:

```bash
sudo tee /etc/apt/apt.conf.d/52unattended-upgrades-local >/dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF
```

Ein nach Updates erforderlicher Neustart wird dadurch **nicht verhindert**. Ubuntu kann weiterhin `/var/run/reboot-required` setzen; das Audit meldet diesen Zustand als `[REBOOT]`. Der Administrator entscheidet dann über den Zeitpunkt des Neustarts.

#### Optional: automatischer Reboot

Wenn automatische Neustarts ausdrücklich gewünscht sind:

```bash
sudo tee /etc/apt/apt.conf.d/52unattended-upgrades-local >/dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
EOF
```

`Automatic-Reboot-WithUsers "false"` verhindert einen automatischen Neustart, solange Benutzer angemeldet sind. Die Uhrzeit sollte zum Wartungsfenster des Servers passen.

#### Effektive Reboot-Konfiguration prüfen

Nicht nur den Inhalt einzelner Dateien prüfen, sondern die von APT tatsächlich zusammengesetzte Konfiguration:

```bash
apt-config dump | grep -E \
'Unattended-Upgrade::Automatic-Reboot($|-WithUsers|-Time)'
```

Für die Policy **kein automatischer Reboot** wird mindestens erwartet:

```text
Unattended-Upgrade::Automatic-Reboot "false";
```

#### Komplettes Beispiel: Security + normale Ubuntu-Updates, kein Auto-Reboot

Tägliche Ausführung aktivieren:

```bash
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
```

Automatischen Reboot deaktivieren:

```bash
sudo tee /etc/apt/apt.conf.d/52unattended-upgrades-local >/dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF
```

Vor der Aktivierung muss geprüft werden, welche `Allowed-Origins` wirksam sind. Für **Security + normale Ubuntu-Updates** muss insbesondere `${distro_codename}-updates` erlaubt sein. Drittanbieter-Repositories werden dadurch nicht automatisch freigegeben.

Die wesentlichen effektiven Einstellungen anschließend gemeinsam prüfen:

```bash
apt-config dump | grep -E \
'APT::Periodic::(Update-Package-Lists|Unattended-Upgrade)|Unattended-Upgrade::Automatic-Reboot'
```

Erwartetes Grundbild:

```text
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";
```

Danach das Audit erneut ausführen:

```bash
sudo ubuntu-update-check
echo "Exit-Code: $?"
```

Ein Exit-Code `1` kann trotz korrekt aktivierter Update-Automatik weiterhin normal sein, wenn beispielsweise ein manueller Neustart erforderlich ist.

### 5. Nach einer Änderung prüfen

```bash
sudo systemctl daemon-reload
systemctl status apt-daily.timer apt-daily-upgrade.timer --no-pager
systemctl list-timers --all | grep -E 'apt-daily|NEXT'
sudo ubuntu-update-check
echo "Exit-Code: $?"
```

Ein gesunder Timer sollte `active/waiting` sein und einen zukünftigen nächsten Lauf besitzen.

### 6. Beispiel für einen Host mit `Unattended-Upgrade=0`

Vor der Aktivierung:

```bash
apt-config dump | grep -E 'APT::Periodic|Unattended-Upgrade::Allowed-Origins' -A20
```

Entscheide anschließend bewusst zwischen **Security-only** und **Security + normale Updates**. Erst danach `APT::Periodic::Unattended-Upgrade "1";` setzen und das Audit erneut ausführen.


## Statusmeldungen

-   `[AKTIV]` -- erwarteter bzw. gesunder Zustand
-   `[INFO]` -- Information ohne negative Wertung
-   `[UPDATE]` -- Update vorhanden
-   `[WARNUNG]` -- prüfenswerter Zustand
-   `[REBOOT]` -- Neustart des Systems erforderlich
-   `[FEHLER]` -- relevante Fehlkonfiguration oder Funktionsstörung

Mit `NO_COLOR=1` werden dieselben Statuskennzeichnungen ohne ANSI-Farben
ausgegeben.

## Exit-Codes

    Exit-Code Bedeutung
  ----------- -----------------------------------------------------------
          `0` Keine Audit-Fehler, Warnungen oder ausstehenden Neustarts
          `1` Warnung und/oder Neustart erforderlich
          `2` Mindestens ein Audit-Fehler erkannt

Ein erforderlicher Reboot wird separat gezählt. Deshalb kann
`Warnungen: 0` angezeigt werden und der Gesamtstatus trotzdem
`[WARNUNG]` mit Exit-Code `1` sein.

## Unterstützte Ubuntu-LTS-Versionen

  Ubuntu      Codename          Status
  ----------- ----------------- -------------
  22.04 LTS   Jammy Jellyfish   unterstützt
  24.04 LTS   Noble Numbat      unterstützt
  26.04 LTS   Resolute          unterstützt

Die Prüfungen verwenden die vom System gemeldete Version, den Codename
und die APT-Origins. Security-Pockets sind daher nicht fest auf
`noble-security` verdrahtet.

## Hinweise zur Interpretation

APT-Simulation und `unattended-upgrades` beantworten unterschiedliche
Fragen. Ein Paket kann allgemein aktualisierbar sein, aber aufgrund der
konfigurierten `Allowed-Origins` trotzdem nicht automatisch installiert
werden.

Für Security-Updates wertet das Script die lokal bekannten
Candidate-Versionen und deren APT-Origin aus. Für die maßgebliche
automatische Auswahl wird zusätzlich der
`unattended-upgrade --dry-run --debug` herangezogen.

Wenn das Audit einen erforderlichen Neustart meldet, sollte insbesondere
geprüft werden, ob der laufende Kernel älter als das höchste
installierte Kernel-Image ist.
