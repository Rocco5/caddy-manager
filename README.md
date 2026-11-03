# caddy-manager

Interaktives Bash-Skript zum Verwalten von [Caddy](https://caddyserver.com): Domains, Reverse-Proxys,
Weiterleitungen, statische Seiten und mehr – mit Pfeiltasten-Menü.

## Installation (Debian/Ubuntu, als root)

```bash
apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/Rocco5/caddy-manager/main/caddy-manager.sh -o /usr/local/bin/caddy-manager
chmod +x /usr/local/bin/caddy-manager
caddy-manager
```

Aktualisieren: dieselben `curl`/`chmod`-Befehle erneut ausführen. Caddy selbst installiert das Menü bei Bedarf
(„Caddy-Dienst“ → „Caddy installieren“). Das Skript läuft nur, solange das Menü offen ist; Caddy läuft als
eigener Dienst weiter.

### Server absichern: fail2ban (empfohlen)

Ein öffentlich erreichbarer Server wird ständig per SSH angegriffen. fail2ban sperrt IPs nach mehreren
Fehlversuchen automatisch.

```bash
apt-get install -y fail2ban
```

Konfiguration in `/etc/fail2ban/jail.local` (`ignoreip` an dein eigenes Netz anpassen, sonst sperrst du dich aus):

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 192.168.0.0/16
bantime  = 1h
findtime = 10m
maxretry = 4
backend  = systemd

# Wiederholungstäter länger sperren
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 4w

[sshd]
enabled = true
port    = ssh
```

Aktivieren und prüfen:

```bash
systemctl enable --now fail2ban
fail2ban-client status sshd
```

Eine fälschlich gesperrte IP entsperren: `fail2ban-client set sshd unbanip 1.2.3.4`.
Besser noch: SSH nur mit Schlüsseln erlauben (`PasswordAuthentication no` in `/etc/ssh/sshd_config`,
vorher den Schlüssel-Login testen).

## Start

```bash
sudo ./caddy-manager.sh          # Menü
sudo ./caddy-manager.sh help     # Kommandozeilen-Modus
```

## Funktionen

- Reverse-Proxy, Domain-Weiterleitung (301/302/307/308), www ↔ ohne www, statische Seite/SPA, Wartungsseite
- Regeln zu bestehenden Seiten: Pfad-Redirect, Pfad sperren, IP-Filter, Rewrite
- Seiten bearbeiten, ein-/ausschalten, umbenennen, löschen
- Bestehende Site-Blöcke der Caddyfile in die Verwaltung übernehmen (`import`)
- Diagnose (validate, fmt, DNS, HTTP-Test, Zertifikate), Dienststeuerung, Caddy-Installation (Debian/Ubuntu)
- Backups vor jeder Änderung, automatischer Rollback bei ungültiger Konfiguration

## Arbeitsweise

Jede Domain bekommt eine Datei in `/etc/caddy/conf.d/<domain>.caddy`; die Haupt-Caddyfile enthält nur
`import /etc/caddy/conf.d/*.caddy`. Deaktivierte Seiten heißen `*.caddy.disabled`.

Umgebungsvariablen: `CADDY_DIR`, `CADDYFILE`, `SITES_DIR`, `BACKUP_DIR`, `CM_NO_SUDO=1`.

## Kommandozeile

```bash
sudo ./caddy-manager.sh proxy app.example.de 127.0.0.1:8000
sudo ./caddy-manager.sh redirect alt.example.de https://neu.example.de 301
sudo ./caddy-manager.sh static docs.example.de /var/www/docs
sudo ./caddy-manager.sh list | import | validate | reload | backup
```

Hinweis: Bisher nur mit einem Caddy-Platzhalter getestet, nicht mit einem echten Caddy.
