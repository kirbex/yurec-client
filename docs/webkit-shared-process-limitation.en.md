# Limitation: Apple system apps with a shared network process

## The problem

Process-name routing in sing-box works as follows: when an app opens a TCP connection, sing-box identifies the originating process name and applies the matching rule. This works perfectly for third-party apps (Telegram, Claude, VS Code, etc.) that own their own network stack.

**Apple system apps work differently.** Safari, Mail, News, App Store and several other system apps delegate all network operations to a **shared system WebKit XPC service**:

```
com.apple.WebKit.Networking
```

This process does not live inside `Safari.app` — it resides in a system framework:

```
/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/
  WebKit.framework/Versions/A/XPCServices/
    com.apple.WebKit.Networking.xpc/Contents/MacOS/
      com.apple.WebKit.Networking
```

## What happens when Safari is added to the routing list

```
User adds Safari.app
  │
  └─ allProcessNames scans Safari.app/Contents/
       finds:      "Safari"  (main process)
       misses:     com.apple.WebKit.Networking  (not inside the app bundle)

User opens a page in Safari
  │
  ├─ Safari.app/Safari           — rendering, UI
  └─ com.apple.WebKit.Networking — all TCP connections (HTTP/HTTPS)

sing-box checks who opened the connection:
  process_name = "com.apple.WebKit.Networking"
  rule for "Safari" → no match
  → route.final = direct → traffic bypasses the VPN
```

## Affected applications

All applications that use `com.apple.WebKit.Networking` for network requests:

| App | Behaviour |
|---|---|
| Safari | All web traffic via WebKit.Networking |
| Mail | Loading email content (images, web parts) |
| News | All content |
| App Store | Requests to Apple APIs |
| Other system apps | Depends on implementation |

## Why a simple fix is not straightforward

Adding `com.apple.WebKit.Networking` to the routing list is technically possible, but has a significant side effect: **all** of the apps listed above would be routed through the VPN, not just Safari. The user added Safari but also gets Mail, News, and App Store.

This is a macOS architectural constraint — one shared process for the entire system. Splitting it per-application at the process_name level is not possible.

## Apps that work correctly

For comparison — apps with their own network stack:

| App | Network process | Routing |
|---|---|---|
| Telegram | `Telegram` | ✅ Works |
| Claude | `Claude`, `Claude Helper (Renderer)`, … | ✅ Works |
| VS Code | `Code`, `Code Helper`, … | ✅ Works |
| ChatGPT | `ChatGPT`, `ChatGPT Helper (Renderer)`, … | ✅ Works |
| Chrome / Edge | `Google Chrome Helper`, `msedge`, … | ✅ Works |
| Firefox | `firefox` | ✅ Works |
| Safari | `Safari` → network via `com.apple.WebKit.Networking` | ❌ Does not work |

## Possible directions for a solution

Rough options:

1. **UI warning** — when Safari (or any other WebKit-based app) is added, show a message explaining that process-name routing will not work due to WebKit's architecture
2. **Add `com.apple.WebKit.Networking` with an explicit warning** — the user consciously accepts that Mail and News will also be routed through the VPN
3. **Automatic detection of affected apps** — during bundle scanning, check whether the app has its own network process or delegates to a shared WebKit service
