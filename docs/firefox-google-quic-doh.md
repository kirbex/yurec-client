# Why Google (and only Google) breaks in Firefox under TUN/SOCKS5 hybrid routing

## Symptom

With Firefox included in App Routing (per-app TUN+SOCKS5 hybrid mode), Google properties
(search, and other AAAA-publishing Google domains) stop loading after some browsing time.
Not a hang — the page simply fails to load, even via a direct URL (not just via a search
redirect). Restarting Firefox fixes it temporarily; it breaks again after a while.

Distinguishing characteristics that ruled out several other explanations during
investigation:

- Other proxied apps (Telegram, Claude, ChatGPT, ...) are unaffected — only Firefox.
- Within Firefox, only Google properties are affected — other sites, including ones
  proxied through the same VPN tunnel, load fine.
- Other search engines work fine.
- Reproduces on different ISPs / different VPN providers — ruling out ISP-level
  throttling or a problem with one specific VPN server.
- Chrome/Edge on the same machine showed no symptoms — but only because they were not
  in the App Routing list at the time, so their traffic bypassed TUN capture entirely.
  This is not evidence that Chromium browsers are immune to either mechanism below.

Two independent, stackable root causes were found. Both stem from the same underlying
fact: **Google is one of the very few large sites that aggressively adopts both QUIC/HTTP3
and full IPv4+IPv6 dual-stack everywhere**, and both of those protocol choices interact
badly with TUN-based traffic capture. Almost no other major site exercises either edge
case as consistently as Google does — which is why the symptom is so narrowly scoped to
Google regardless of network, VPN provider, or ISP.

---

## Cause 1 — QUIC/HTTP3 blackhole (mitigated, not Google-exclusive)

`ConfigTransformer.swift` blocks UDP/443 for routed processes (`ConfigTransformer.swift:106-117`)
because the VLESS tunnel used by this app cannot relay QUIC/UDP reliably. The comment in
the code documents this was tuned against Chrome/Yandex's behavior, which falls back to
TCP/TLS quickly when UDP/443 is silently dropped.

Firefox does not fall back as gracefully in all cases. This turns out to be a known,
unconfirmed upstream bug:

- [Mozilla Bug 1882018](https://bugzilla.mozilla.org/show_bug.cgi?id=1882018) — "QUIC
  (HTTP/3) connection does not work when using SOCKS5 proxy" (filed Feb 2024, still
  unconfirmed as of this writing).
- Firefox has a fast-fallback safety net,
  `network.dns.httpssvc.http3_fast_fallback_timeout` (default 50ms,
  [Bug 1701829](https://bugzilla.mozilla.org/show_bug.cgi?id=1701829)) — but it only
  applies when HTTP/3 support is discovered via DNS HTTPS resource records (HTTPSSVC/SVCB).
  When Firefox instead learns about HTTP/3 from an `Alt-Svc` response header (which is how
  Google advertises it), the 50ms race does not apply. Once Firefox caches the Alt-Svc
  mapping for a domain, subsequent navigations attempt QUIC directly and sit on QUIC's own
  much longer internal connection timeout before falling back — which produces exactly the
  "works right after restart, breaks after some browsing" pattern, since a fresh Firefox
  process has no cached Alt-Svc state yet.

**Fix:** `about:config` → `network.http.http3.enable` → `false`. Confirmed empirically:
zero `blocked packet connection` log entries for Firefox since this was applied, versus a
continuous stream of blocked QUIC attempts to Google IP ranges before.

This is a real, contributing mechanism, but disabling HTTP/3 alone did **not** fully
resolve the live case investigated here — see Cause 2.

---

## Cause 2 — DNS-over-HTTPS bypassing the sing-box IPv6 mitigation (the actual root cause)

This app already mitigates a known IPv6 Happy-Eyeballs trap (documented in
[`ipv6-routing-behavior.md`](ipv6-routing-behavior.md)): in TUN mode, sing-box accepts a
TCP handshake locally and instantly, so a browser's IPv6 attempt "wins" the Happy Eyeballs
race even when the IPv6 destination is unreachable end-to-end. The browser then sees a
`RST` after the handshake instead of an immediate "host unreachable," and — unlike a
pre-handshake failure — does **not** fall back to the already-lost IPv4 attempt.

The mitigation: `DNSHelper.hasGlobalIPv6()` detects whether the host has real, global
IPv6 connectivity, and if not, forces `dns.strategy = "ipv4_only"` on the sing-box config
(`ConfigTransformer.swift:151-156`), so AAAA records never reach the browser in the first
place. This works correctly for every app that resolves DNS through the system resolver
(which sing-box hijacks via the `tun-in` inbound's DNS interception).

**Firefox does not use the system resolver.** Its profile (`prefs.js`) showed:

```
user_pref("doh-rollout.mode", 2);
user_pref("doh-rollout.self-enabled", true);
user_pref("doh-rollout.uri", "https://mozilla.cloudflare-dns.com/dns-query");
user_pref("doh-rollout.home-region", "RU");
```

Mozilla auto-enables DNS-over-HTTPS (TRR mode 2: prefer DoH, fall back to native DNS only
on TRR failure) by default for users in regions with known DNS interference — Russia among
them. This is normally a privacy/anti-censorship feature, but it means Firefox resolves
domains by querying Cloudflare directly over HTTPS, **completely bypassing** the system
DNS at `172.19.0.1` and, with it, the `ipv4_only` mitigation entirely.

This was confirmed live: `lsof` on the running Firefox process showed established TCP
sockets over IPv6 through the TUN interface's own IPv6 prefix
(`[fdfe:dcba:9876::1]:* -> [...]:443`) at the exact moment Google was failing to load,
despite `ipv4_only` being active in the sing-box config. Firefox got a real AAAA record
straight from Cloudflare, re-opening the exact Happy-Eyeballs trap the `ipv4_only` fix
exists to close — just via a path that bypasses it entirely.

**Fix:** Firefox → Settings → Privacy & Security → DNS over HTTPS → **Off**
(`network.trr.mode` → `5`). This returns Firefox to system DNS resolution, where the
existing `ipv4_only` mitigation applies normally.

**Confirmed working.** After applying `network.trr.mode = 5`, Google loads reliably with
no further breakage. As a side effect, every other site in Firefox started loading
noticeably faster too — DoH was adding an extra HTTPS round-trip to Cloudflare for every
DNS lookup, on top of (and instead of) the local hijacked resolver; removing it sped up
DNS resolution for all sites, not just Google.

---

## Why this is Firefox/Google-specific, independent of network or VPN provider

| Factor | Why it singles out Google | Why it's provider-independent |
|---|---|---|
| QUIC/HTTP3 + Alt-Svc | Google is the most aggressive HTTP/3 + Alt-Svc adopter on the web | The fallback bug is inside Firefox's own networking stack |
| DNS-over-HTTPS bypass | Google is one of the few sites with full, consistent dual-stack AAAA everywhere | DoH is a Firefox client-side setting; reproduces on any TUN/SOCKS5 proxy on any network |

Other proxied apps (Telegram, Electron-based apps) are unaffected because they resolve DNS
through the system resolver, which is correctly hijacked and forced to IPv4-only.
Chrome/Edge appeared unaffected in this investigation only because they were not part of
the App Routing list at the time — not because either mechanism above doesn't apply to
Chromium-based browsers.

## Status

Both fixes are Firefox-side `about:config`/Settings changes, not code changes in
YurecClient:

1. `network.http.http3.enable = false` — applied.
2. `network.trr.mode = 5` (DNS over HTTPS → Off) — applied and confirmed working: Google
   loads reliably, and general browsing latency in Firefox improved as well (one less
   DNS round-trip per lookup).

No code changes are required in this repository for this specific case — both fixes are
Firefox-side settings.
