# caddy-manager

Interaktives Bash-Skript zum Verwalten von [Caddy](https://caddyserver.com): Domains, Reverse-Proxys,
Weiterleitungen, statische Seiten und mehr – mit Pfeiltasten-Menü.

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
