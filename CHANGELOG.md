# Changelog

## [1.1.0] — 2026-05-22

- **Subscriptions** — add a profile from a subscription URL (Add from URL...). Supported protocols: VLESS (including XTLS Reality), VMess, Shadowsocks, Trojan, Hysteria2. Response formats: base64, plain text, ready-made sing-box JSON
- **Subscription update** — Update button in profile settings re-downloads the config from the stored URL
- **HWID** — subscription requests include `x-hwid`, `x-device-os`, `x-ver-os`, `x-device-model` headers for device identification in the management panel (compatible with Remnawave)
- **Generated config format** — matches the modern sing-box API: `address` instead of `inet4_address`, `stack: mixed`, sniff, `hijack-dns`, `ip_is_private`, `domain_resolver`

## [1.0.1] — 2026-04-25

- **SOCKS5 DNS fix** — resolved DNS resolution failures where fakeip server references remained in rules after removal, causing A/AAAA resolution to break for sites like Yandex, Gmail, and Google Meet in SOCKS5 mode
- **TUN+SOCKS5 QUIC fix** — added UDP port 443 blocking rules for selected processes, forcing browsers to fall back to TCP through the proxy instead of attempting QUIC over UDP

## [1.0.0] — 2026-04-25

Initial release.

- TUN mode — full-system VPN via virtual network interface (L3 capture, no per-app configuration needed)
- SOCKS5 mode — sets macOS system proxy; hybrid TUN+SOCKS5 sub-mode routes selected apps through VPN while everything else goes direct
- App routing — per-process traffic routing with automatic helper process detection for Electron apps (Claude, VS Code, ChatGPT)
- Multi-profile support with live reload via FSEvents
- Passwordless sudo integration (one-time setup via `/etc/sudoers.d/yurec`)
- External process detection — adopts a running sing-box instance started outside the app
- Launch at login and auto-connect on launch
- Built-in log viewer with configurable size limit
