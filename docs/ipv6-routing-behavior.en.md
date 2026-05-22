# IPv6 and Happy Eyeballs Across VPN Modes

## Background

Browsers implement the **Happy Eyeballs** algorithm (RFC 8305): when a domain resolves to both IPv4 and IPv6 addresses, the browser races both connection attempts simultaneously and uses whichever succeeds first. Understanding this is essential, because it is exactly this behaviour that creates a failure in hybrid TUN+SOCKS5 mode.

---

## Mode 1: No VPN

```
Browser
  │
  ├─ DNS query for example.com
  │     ISP DNS responds:
  │     A:    203.0.113.10      (IPv4)
  │     AAAA: 2001:db8::1      (IPv6)
  │
  ├─── Happy Eyeballs IPv6 ──→ OS network stack
  │                                  │
  │                           no global IPv6 address on any interface
  │                           OS → ICMP "no route to host" (instant, before handshake)
  │                                  ✗ failure BEFORE the connection is established
  │
  └─── Happy Eyeballs IPv4 ──→ OS network stack → 203.0.113.10
                                                   local ISP IP ✅

Result: works. IPv6 fails instantly at the OS level;
        the browser transparently falls back to IPv4.
```

**Why this matters:** the OS returns `EHOSTUNREACH` or `ENETUNREACH` **before** the TCP handshake. The browser treats this as "address unreachable" and correctly switches to IPv4.

---

## Mode 2: TUN mode (`route.final = "proxy"`)

All traffic is routed through the VPN server.

```
Browser
  │
  ├─ DNS query for example.com
  │     172.19.0.1 (TUN) → sing-box DNS → 1.1.1.1 via VPN tunnel
  │     A:    203.0.113.10
  │     AAAA: 2001:db8::1
  │
  ├─── Happy Eyeballs IPv6 ──→ TUN interface → sing-box
  │                                                │
  │                                         route: proxy
  │                                                │
  │                               [sniff] extracts SNI from TLS ClientHello
  │                               target: "example.com" (domain, not IP)
  │                                                │
  │                                    VLESS tunnel (TCP over IPv4)
  │                                    ──→ vpn-server.example.com:443
  │                                                │
  │                                    Server receives request:
  │                                    "connect to example.com:443"
  │                                                │
  │                                    Server resolves example.com
  │                                                │
  │                                  ┌─────────────┴─────────────┐
  │                             has IPv6                    no IPv6
  │                                  │                           │
  │                            → 2001:db8::1 ✅          → 203.0.113.10 ✅
  │                              (server has IPv6            (falls back to IPv4,
  │                               connectivity)               server decides)
  │
  └─── Happy Eyeballs IPv4 ──→ (same path through VPN)

Result: works. But the external IP = VPN server IP (foreign).
        Geo-restricted services may block access.
```

**Key point:** sing-box sends the VPN server a **domain name** (extracted via sniff/SNI), not the IPv6 address. The server resolves the domain itself and picks an IP according to its own configuration. If the server has no IPv6, it will use IPv4 without any error.

**Exception:** if sniff fails (plain HTTP, non-standard TLS, QUIC), sing-box forwards the raw IPv6 address to the server. If the VPN server has no IPv6, the connection will fail.

---

## Mode 3: SOCKS5 hybrid (`route.final = "direct"`)

The browser goes directly to the internet; selected apps are routed through the VPN.

```
Browser
  │
  ├─ DNS query for example.com
  │     172.19.0.1 (TUN) → sing-box DNS → 1.1.1.1 via VPN tunnel
  │     A:    203.0.113.10
  │     AAAA: 2001:db8::1
  │
  ├─── Happy Eyeballs IPv6 ──→ TUN interface → sing-box
  │                                                │
  │                                         route: direct
  │                                                │
  │                            ┌── sing-box completes TCP handshake LOCALLY
  │                            │   SYN → SYN-ACK → ACK  (< 1 ms)
  │                            │   Browser thinks: "connection established!"
  │                            │   IPv6 wins the Happy Eyeballs race
  │                            │
  │                            └── sing-box attempts outbound connection:
  │                                direct → 2001:db8::1:443
  │                                      │
  │                                no global IPv6 on the machine
  │                                      │
  │                                sing-box → TCP RST → browser
  │
  │         Browser receives RST on an "established" connection
  │         → ERR_CONNECTION_RESET 🚫
  │         → Happy Eyeballs does NOT fall back to IPv4
  │           (RST is interpreted as a server-side reset, not an unreachable address)
  │
  └─── Happy Eyeballs IPv4 ──→ TUN → sing-box → direct → 203.0.113.10
                                                           local ISP IP — but this
                                                           attempt is already cancelled,
                                                           IPv6 "won" the race

Result: ERR_CONNECTION_RESET. The browser does not fall back to IPv4.
```

### Why IPv4 does not save the day

The difference between two kinds of failure:

| Situation | Error | Browser behaviour |
|---|---|---|
| No IPv6, no VPN | `EHOSTUNREACH` before handshake | Falls back to IPv4 |
| TUN + direct, no IPv6 | TCP RST after handshake | **Does not fall back**, shows error |

The TUN creates a trap: it accepts the handshake locally (so IPv6 wins the race), but then cannot forward the connection outbound. By that point the browser has already cancelled its IPv4 attempt.

---

## Mode 3 with fix: SOCKS5 + `strategy: ipv4_only`

```
Browser
  │
  ├─ DNS query for example.com (AAAA)
  │     sing-box DNS (strategy: ipv4_only)
  │     → AAAA query is suppressed / not forwarded
  │     → only A: 203.0.113.10 is returned
  │
  └─── IPv4 only ──→ TUN → sing-box → direct → 203.0.113.10
                                                local ISP IP ✅

Result: works. The browser never learns about the IPv6 address.
```

---

## Automatic strategy selection in the client

Rather than always disabling IPv6, the client checks for a global IPv6 address on physical interfaces at VPN start time:

```
DNSHelper.hasGlobalIPv6()
  │
  ├── iterates all network interfaces (getifaddrs)
  ├── excludes: utun*, lo* (loopback and TUN interfaces)
  ├── excludes: link-local addresses (fe80::/10)
  │
  ├── found a global IPv6 → strategy unchanged (IPv6 works fine)
  └── not found           → strategy = "ipv4_only"
```

This ensures correct behaviour on both networks without IPv6 (most residential ISPs) and fully dual-stack networks (offices, data centres, cloud environments).

---

## Mode comparison

| Mode | Browser IP | IPv6 connection | Issue |
|---|---|---|---|
| No VPN | local ISP | OS rejects instantly → IPv4 fallback | none |
| TUN | VPN server IP | Tunnelled through VPN server, server decides | geo-blocks on local services |
| SOCKS5 hybrid (no fix) | local ISP | TUN accepts handshake → RST | ERR_CONNECTION_RESET |
| SOCKS5 hybrid (with fix) | local ISP | AAAA suppressed, IPv4 only | none |

---

## Affected domains

The issue appears on dual-stack sites that have AAAA records but where IPv6 connectivity from the client machine is missing:

- Yandex and all its services (streaming, mail, maps, music, etc.)
- Google services (Gmail, Maps, Docs, etc.)
- Other major CDNs with dual-stack support

Sites with A records only (many regional e-commerce platforms, for example) are unaffected — the browser never attempts an IPv6 connection.
