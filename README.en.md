# YurecClient

A macOS menu bar application — a graphical front-end for [sing-box](https://sing-box.sagernet.org/). Lets you start sing-box in two modes (TUN and SOCKS5) with a single click from the status bar, manage configuration profiles, and configure per-process traffic routing.

---

## Table of Contents

- [Requirements](#requirements)
- [Architecture](#architecture)
- [TUN Mode](#tun-mode)
- [SOCKS5 Mode](#socks5-mode)
- [Profiles](#profiles)
- [App Routing](#app-routing)
- [Sudoers and Permissions](#sudoers-and-permissions)
- [Launch at Login and Auto-connect](#launch-at-login-and-auto-connect)
- [External Process Detection](#external-process-detection)
- [Logs](#logs)
- [Project Structure](#project-structure)

---

## Requirements

- macOS 13 Ventura or later
- [sing-box](https://sing-box.sagernet.org/) installed on the system:
  - `/usr/local/bin/sing-box` (auto-detected)
  - `/opt/homebrew/bin/sing-box` (auto-detected)
  - or any custom path set in Settings
- Xcode 15+ to build

---

## Architecture

```
YurecClient
├── AppDelegate                  — entry point, NSStatusItem initialisation
├── Managers/
│   ├── ProxyManager             — start/stop sing-box, process lifecycle management
│   ├── ProfileManager           — storage and observation of JSON configs
│   ├── ConfigTransformer        — config transformation for SOCKS5 mode
│   ├── AppRoutingStore          — storage of per-app routing lists
│   ├── AppRoutingEntry          — model for a single app in the routing list
│   ├── ConnectionMode           — enum: .tun / .socks5(port:)
│   ├── SudoersManager           — manages the /etc/sudoers.d/yurec rule
│   └── LaunchAtLoginManager     — launch-at-login via ServiceManagement
├── Helpers/
│   ├── DNSHelper                — set/reset DNS via networksetup
│   └── SystemProxyHelper        — set/reset macOS system SOCKS5 proxy
└── UI/
    ├── StatusMenuController     — status bar menu, icon, animations
    └── Settings/
        ├── GeneralTabView       — general settings, global App Routing list
        └── ProfilesTabView      — profile management, per-profile settings
```

The central singleton is `ProxyManager`. All other components either call it directly or subscribe to its `@Published` properties (`isRunning`, `currentMode`) via Combine.

---

## TUN Mode

### What happens

TUN mode creates a virtual network interface at the kernel level. All outgoing system traffic is intercepted by sing-box at the L3 layer (IP packets), regardless of whether an application knows about a proxy or not. This is a true full-VPN mode.

### Start sequence

```
StatusMenuController.connectTun()
  └── beginConnect(to: .tun, profile:)
        └── ProxyManager.start(profilePath:, mode: .tun)
              1. killOrphanedSingBox()          — kill any orphaned sing-box processes
              2. configPath = profilePath       — TUN uses the profile directly, no transformation
              3. SudoersManager.isInstalled()   — check whether the sudoers rule exists
                  └── if not → SudoersManager.install() → password dialog (once ever)
              4. open/create log file           — ~/Library/Logs/YurecClient/sing-box.log
              5. Process() with sudo -n         — sudo -n /path/to/sing-box run -c config.json
              6. isRunning = true               — synchronously, before registering terminationHandler
              7. task.terminationHandler        — dispatched async on main queue → handleProcessTermination()
              8. DNSHelper.setDNS("172.19.0.1") — redirect DNS on all network interfaces
                                                  to sing-box's fake-ip stack
```

### DNS in TUN mode

After sing-box starts, `DNSHelper.setDNS("172.19.0.1")` runs for every enabled network service:

```sh
sudo -n /usr/sbin/networksetup -setdnsservers "Wi-Fi" 172.19.0.1
```

`172.19.0.1` is the fake-ip DNS server address inside sing-box's TUN interface. All DNS queries from applications are routed to sing-box, which returns synthetic IPs in the `198.18.x.x` range and maps them to real domains for subsequent routing decisions.

### Stopping TUN

```
ProxyManager.stop()
  1. SIGKILL all sing-box child processes (pgrepSingBox + forceKillPIDs)
  2. killProcess() — terminate() + SIGTERM by PID
  3. DNSHelper.resetDNS() — reset DNS back to "empty" (DHCP)
  4. cleanupMode() — delete tempConfigURL (if any), clear state
  5. isRunning = false
  6. startLaunchDetectionLoop() — begin watching for sing-box to appear externally
```

---

## SOCKS5 Mode

### What happens

In SOCKS5 mode, sing-box starts without a TUN interface. Instead of intercepting at the L3 layer, it opens a SOCKS5 proxy server on `127.0.0.1:<port>` (default 2080). Applications must explicitly use this proxy.

To automatically route all traffic through SOCKS5 without manually configuring each application, YurecClient sets the **macOS system proxy** via `networksetup`. This causes browsers, Electron apps, and any application that respects the system proxy settings to automatically connect through sing-box.

### Start sequence

```
StatusMenuController.connectSocks5()
  └── beginConnect(to: .socks5(port:), profile:)
        └── ProxyManager.start(profilePath:, mode: .socks5(port:))
              1. killOrphanedSingBox()
              2. ensurePortFreeForSocks5(port)     — verify the port is available
                   └── hasListenerOnPort()          — connect() to 127.0.0.1:port
                       if held by sing-box → SIGKILL
                       if held by a foreign process → log + abort
              3. AppRoutingStore.effectiveProcessNames(for: profile)
                                                   — get process_name list for injection
              4. ConfigTransformer.makeSocks5Config(from:, port:, routedProcessNames:)
                                                   — transform config (see below)
              5. SudoersManager.isInstalled()       — check sudoers for sing-box + networksetup
              6. Process() with sudo -n             — both modes run as root via sudo
              7. isRunning = true
              8. SystemProxyHelper.enableSOCKS5(port:)
                                                   — set the macOS system SOCKS5 proxy
```

### Config transformation (ConfigTransformer)

The original sing-box profile is designed for TUN mode — it may contain a `tun` inbound and `fakeip` DNS. Neither is needed in SOCKS5 mode and both interfere. `ConfigTransformer.makeSocks5Config()` produces a temporary JSON file:

1. **Removes `tun` inbounds** — the TUN interface is not needed
2. **Removes existing `socks` inbounds** — replaces them with a single clean one
3. **Adds a SOCKS5 inbound**:
   ```json
   { "type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": 2080 }
   ```
4. **Removes `fakeip` DNS servers** — fake-ip only works with TUN
5. **Injects a `process_name` rule** (when the app list is non-empty):
   ```json
   {
     "route": {
       "find_process": true,
       "rules": [
         { "process_name": ["Telegram", "Discord"], "outbound": "proxy" },
         ...remaining profile rules...
       ]
     }
   }
   ```
   `route.final` is intentionally **left unchanged** — apps not in the list follow the profile's default routing.

The temporary file is written to `/tmp/yurec-socks5-<UUID>.json` and deleted on stop.

### macOS system proxy

`SystemProxyHelper.enableSOCKS5(port:)` runs for each active network service:

```sh
sudo -n /usr/sbin/networksetup -setsocksfirewallproxy "Wi-Fi" 127.0.0.1 2080
sudo -n /usr/sbin/networksetup -setsocksfirewallproxystate "Wi-Fi" on
```

When SOCKS5 stops (`stop()`, `handleProcessTermination()`, `forceCleanup()`), `SystemProxyHelper.disableSOCKS5()` is called:

```sh
sudo -n /usr/sbin/networksetup -setsocksfirewallproxystate "Wi-Fi" off
```

### Stopping SOCKS5

```
ProxyManager.stop()
  1. SIGKILL all sing-box child processes
  2. killProcess()
  3. SystemProxyHelper.disableSOCKS5()  — remove the system proxy
  4. cleanupMode()                       — delete the temp config from /tmp
  5. isRunning = false
  6. startLaunchDetectionLoop()
```

---

## Profiles

Profiles are sing-box JSON configuration files stored in `~/.singbox/profiles/`. The app watches this directory via **FSEvents** and automatically refreshes the profile list when files are added or removed.

### Profile contents

A standard sing-box JSON with:
- `inbounds` — incoming transports (TUN, SOCKS5, etc.)
- `outbounds` — egress destinations (proxy, direct, block)
- `route.rules` — traffic routing rules
- `route.final` — default outbound (typically `"proxy"`)
- `dns` — DNS servers, including fake-ip for TUN

### Per-profile settings

Each profile independently stores:
- **SOCKS5 Port** — port for SOCKS5 mode (default 2080), saved in `UserDefaults`
- **App Routing override** — flag and a profile-specific app list that replaces the global one

---

## App Routing

Allows you to explicitly specify which applications should be routed through the proxy in SOCKS5 mode, using sing-box's `process_name` routing mechanism.

### Two-tier system

```
GlobalEntries (UserDefaults: appRouting.global.v1)
     │
     └── applied to every profile where overridesGlobal = false
              │
         ProfileEntries (UserDefaults: appRouting.profile.entries.<path>)
              │
              └── applied to the specific profile when overridesGlobal = true
```

**Resolution** (`AppRoutingStore.effectiveEntries(for:)`):
- `profile == nil` → global list
- `profile.overridesGlobal == true` → profile-specific list
- otherwise → global list

### AppRoutingEntry

When an app is added via NSOpenPanel, `AppRoutingEntry(appURL:)` reads from the bundle:
- `displayName` — from `CFBundleDisplayName` / `CFBundleName` / filename
- `processName` — executable basename (what sing-box actually matches in `process_name` rules)
- `bundleIdentifier` — `CFBundleIdentifier`
- `appPath` — path to the `.app` bundle for the icon

### How to add an application

In Settings (General or Profiles tab), click `+` → an `NSOpenPanel` opens pointing to `/Applications`, configured to select `.app` bundles as files (`treatsFilePackagesAsDirectories = false`).

---

## Sudoers and Permissions

Both TUN and SOCKS5 are launched via `sudo -n` (passwordless). The rule is installed **once** — on first connect, the standard macOS `administrator privileges` dialog appears.

### The rule (`/etc/sudoers.d/yurec`)

```
# Managed by YurecClient — do not edit
%admin ALL=(root) NOPASSWD: /usr/local/bin/sing-box, /opt/homebrew/bin/sing-box, /bin/kill, /usr/sbin/networksetup
```

Covers:
- sing-box paths (standard locations + custom path if set)
- `/bin/kill` — for SIGKILL of orphaned processes
- `/usr/sbin/networksetup` — for DNS management and the system proxy

The rule is validated via `sudo -n -l <path>` before every start. If the binary path has changed (e.g. after a Homebrew update), the rule is reinstalled automatically.

---

## Launch at Login and Auto-connect

| Setting | Mechanism | Storage |
|---|---|---|
| **Launch at Login** | `SMAppService.mainApp` (ServiceManagement.framework) | system launchd registry |
| **Auto-connect on Launch** | checked in `AppDelegate.applicationDidFinishLaunching` | `UserDefaults: autoConnectOnLaunch` |

Auto-connect uses the active profile and TUN mode.

---

## External Process Detection

If sing-box was started outside YurecClient (manually in Terminal, by another app), the client will still adopt it.

### Mechanism

On launch and after every stop, `ProxyManager` starts `startLaunchDetectionLoop()` — a background thread that scans for a `sing-box` process every 2 seconds using `sysctl(KERN_PROC_ALL)`. When found:

1. Reads the process arguments via `sysctl(KERN_PROCARGS2)` — looks for the `run` flag and the config path (`-c <path>`)
2. Identifies the active profile from the config path
3. Calls `adoptProcess(pid:profilePath:)` — sets `isRunning = true` and begins watching

### Watching an adopted process

For processes without a `terminationHandler` (no `Process` object), **kqueue** is used (`EVFILT_PROC / NOTE_EXIT`). This allows efficient waiting for process exit without constant polling. If kqueue is unavailable, it falls back to polling every 2 seconds.

---

## Logs

Log file: `~/Library/Logs/YurecClient/sing-box.log`

sing-box stdout and stderr are both redirected to this file. Each session start appends a separator:

```
--- YurecClient: starting TUN (Full VPN) @ 2025-01-15 12:00:00 +0000 ---
```

The log can be opened from the menu: **Open Logs** — opens Finder with the file selected.

### Log size management

In Settings (General → Logs):

- **Current size** — current file size in B / KB / MB
- **Clear Now** — clears the file immediately: truncates it to zero and resets the write position to the beginning; works even while sing-box is running
- **Limit log file size** — enables automatic size enforcement
- **Max size** — threshold in megabytes (default 10 MB). Enforced both at session start and in real time during a running session

### LogForwarder

sing-box output is not redirected directly to a file. Instead, stdout/stderr are connected to `Pipe`s, and `LogForwarder` reads from both pipes via `readabilityHandler` on a background GCD queue and writes to the log file itself.

This gives full control over every write:
- When accumulated bytes exceed the limit → `fileHandle.truncateFile(atOffset: 0)` + `seek(toFileOffset: 0)` → the file is zeroed and writing continues from the beginning
- **Clear Now** calls the same `rotate()` through the forwarder — no file deletion needed, sing-box keeps running without interruption
- The file **never exceeds** the configured limit regardless of how long the session runs

---

## Project Structure

```
YurecClient/
├── AppDelegate.swift
├── Managers/
│   ├── ConnectionMode.swift         — enum .tun / .socks5(port:), requiresRoot
│   ├── ProxyManager.swift           — core: start, stop, process lifecycle
│   ├── ProfileManager.swift         — profile CRUD, FSEvents, active profile
│   ├── ConfigTransformer.swift      — config transformation for SOCKS5
│   ├── AppRoutingEntry.swift        — app model for the routing list
│   ├── AppRoutingStore.swift        — two-tier global/per-profile storage
│   ├── SudoersManager.swift         — install /etc/sudoers.d/yurec
│   └── LaunchAtLoginManager.swift   — SMAppService wrapper
├── Helpers/
│   ├── DNSHelper.swift              — networksetup DNS for TUN
│   └── SystemProxyHelper.swift      — networksetup SOCKS5 proxy
└── UI/
    ├── StatusMenuController.swift   — NSStatusItem, menu, icon animations
    ├── StatusBarIconState.swift     — icon state model
    ├── StatusBarIconProvider.swift  — icon rendering from state
    └── Settings/
        ├── SettingsView.swift           — tab container
        ├── SettingsWindowController.swift
        ├── GeneralTabView.swift         — Launch at Login, binary path, App Routing (global)
        ├── ProfilesTabView.swift        — profile list, SOCKS5 port, App Routing (per-profile)
        └── AppRoutingListView.swift     — reusable list with +/- toolbar
```
