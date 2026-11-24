# Local installation certificates

The bundled TLS certificates identify only the built-in local install server (`app.localhost.qaq.wiki`). That hostname is a functional DNS identity of the install server, not app branding — it must stay as-is for the local installer to work.
The local HTTPS installer needs the leaf certificate and its private key.
The CA private key is not included in the repository or release packages.

Version 4.2.2 replaces the old CA certificate, whose subject contained a local
username and hostname. To use OTA installation after upgrading, install and
trust the new certificate from Settings again.

Release builds explicitly clear `DEVELOPMENT_TEAM`, disable developer signing,
and check the IPA and macOS archive for personal build paths, provisioning
profiles, developer signing identities, and personal certificate subjects
before publishing them.

NVD CA (1.2, Nov 2026): the bundled CA was regenerated as
"O = NVD, CN = NVD Local Installation CA" (SHA256 fingerprint
37:BD:D2:D8:03:2E:84:F0:15:A6:0D:F3:51:D6:86:81:A4:AA:2A:8D:9B:00:BB:63:69:99:3C:05:0F:C3:65:A0,
valid 24 Nov 2026 - 21 Nov 2036) and the leaf was re-issued for
`localhost.qaq.wiki` (SAN DNS:localhost.qaq.wiki, DNS:*.localhost.qaq.wiki,
valid 1 year). The hostname stays `app.localhost.qaq.wiki` — only the
certificate display name (CN) changed, so the local installer still
resolves. The CA private key is not in the repository (same as upstream).
After upgrading from a build with the old Asspp CA, install and trust the
new certificate from Settings again. The default install path (NVD manifest
worker) does not use this certificate at all.
