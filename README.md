# YurecClient

macOS menu bar приложение — графический фронтенд для [sing-box](https://sing-box.sagernet.org/). Позволяет запускать sing-box в двух режимах (TUN и SOCKS5) одним кликом из строки меню, управлять профилями конфигурации и настраивать маршрутизацию трафика на уровне процессов.

---

## Содержание

- [Требования](#требования)
- [Архитектура](#архитектура)
- [Режим TUN](#режим-tun)
- [Режим SOCKS5](#режим-socks5)
- [Профили](#профили)
- [Маршрутизация по приложениям (App Routing)](#маршрутизация-по-приложениям-app-routing)
- [Sudoers и права](#sudoers-и-права)
- [Автозапуск и авто-подключение](#автозапуск-и-авто-подключение)
- [Обнаружение внешних процессов](#обнаружение-внешних-процессов)
- [Логи](#логи)
- [Структура проекта](#структура-проекта)

---

## Требования

- macOS 13 Ventura или новее
- [sing-box](https://sing-box.sagernet.org/) установлен в системе:
  - `/usr/local/bin/sing-box` (автоопределение)
  - `/opt/homebrew/bin/sing-box` (автоопределение)
  - или любой произвольный путь, заданный в настройках
- Xcode 15+ для сборки

---

## Архитектура

```
YurecClient
├── AppDelegate                  — точка входа, инициализация StatusItem
├── Managers/
│   ├── ProxyManager             — запуск/остановка sing-box, управление жизненным циклом
│   ├── ProfileManager           — хранение и наблюдение за JSON-конфигами
│   ├── ConfigTransformer        — трансформация конфига под режим SOCKS5
│   ├── AppRoutingStore          — хранение списков приложений для маршрутизации
│   ├── AppRoutingEntry          — модель одного приложения в списке маршрутизации
│   ├── ConnectionMode           — enum: .tun / .socks5(port:)
│   ├── SudoersManager           — управление правилом /etc/sudoers.d/yurec
│   └── LaunchAtLoginManager     — управление автозапуском через ServiceManagement
├── Helpers/
│   ├── DNSHelper                — установка/сброс DNS через networksetup
│   └── SystemProxyHelper        — установка/сброс системного SOCKS5-прокси
└── UI/
    ├── StatusMenuController     — меню строки состояния, иконка, анимация
    └── Settings/
        ├── GeneralTabView       — общие настройки, глобальный список App Routing
        └── ProfilesTabView      — управление профилями, настройки на профиль
```

Центральный синглтон — `ProxyManager`. Все остальные компоненты либо вызывают его напрямую, либо подписываются на его `@Published` свойства (`isRunning`, `currentMode`) через Combine.

---

## Режим TUN

### Что происходит

TUN-режим создаёт виртуальный сетевой интерфейс на уровне ядра. Весь исходящий трафик системы перехватывается sing-box на уровне L3 (IP-пакеты), независимо от того, знает ли приложение о прокси или нет. Это полноценный «full VPN» режим.

### Последовательность запуска

```
StatusMenuController.connectTun()
  └── beginConnect(to: .tun, profile:)
        └── ProxyManager.start(profilePath:, mode: .tun)
              1. killOrphanedSingBox()         — убить осиротевшие процессы sing-box
              2. configPath = profilePath      — TUN использует профиль напрямую, без трансформации
              3. SudoersManager.isInstalled()  — проверить наличие sudoers-правила
                  └── если нет → SudoersManager.install() → диалог пароля (один раз за всё время)
              4. открыть/создать лог-файл      — ~/Library/Logs/YurecClient/sing-box.log
              5. Process() с sudo -n           — sudo -n /path/to/sing-box run -c config.json
              6. isRunning = true              — синхронно, до регистрации terminationHandler
              7. task.terminationHandler       — async на main queue, вызывает handleProcessTermination()
              8. DNSHelper.setDNS("172.19.0.1") — перенаправить DNS всех сетевых интерфейсов
                                                  на fake-ip стек sing-box
```

### DNS в TUN-режиме

После запуска sing-box `DNSHelper.setDNS("172.19.0.1")` выполняет для каждого включённого сетевого сервиса:

```sh
sudo -n /usr/sbin/networksetup -setdnsservers "Wi-Fi" 172.19.0.1
```

`172.19.0.1` — это адрес fake-ip DNS-сервера внутри TUN-интерфейса sing-box. Все DNS-запросы приложений уходят в sing-box, который возвращает фиктивные IP из диапазона `198.18.x.x` и отображает их на реальные домены для последующей маршрутизации.

### Остановка TUN

```
ProxyManager.stop()
  1. SIGKILL всем дочерним sing-box процессам (pgrepSingBox + forceKillPIDs)
  2. killProcess() — terminate() + SIGTERM по PID
  3. DNSHelper.resetDNS() — сбросить DNS обратно на "empty" (DHCP)
  4. cleanupMode() — удалить tempConfigURL (если есть), обнулить состояние
  5. isRunning = false
  6. startLaunchDetectionLoop() — начать следить за внешним запуском sing-box
```

---

## Режим SOCKS5

### Что происходит

В SOCKS5-режиме sing-box запускается без TUN-интерфейса. Вместо перехвата на уровне L3 открывается SOCKS5-прокси сервер на `127.0.0.1:<port>` (по умолчанию 2080). Приложения должны явно использовать этот прокси.

Чтобы автоматически направить весь трафик через SOCKS5 без ручной настройки в каждом приложении, YurecClient устанавливает **системный прокси macOS** через `networksetup`. Это заставляет браузеры, Electron-приложения и любые приложения, уважающие системные настройки прокси, автоматически подключаться через sing-box.

### Последовательность запуска

```
StatusMenuController.connectSocks5()
  └── beginConnect(to: .socks5(port:), profile:)
        └── ProxyManager.start(profilePath:, mode: .socks5(port:))
              1. killOrphanedSingBox()
              2. ensurePortFreeForSocks5(port)    — проверить, что порт свободен
                   └── hasListenerOnPort()         — connect() на 127.0.0.1:port
                       если занят sing-box → SIGKILL
                       если занят чужой процесс → лог + abort
              3. AppRoutingStore.effectiveProcessNames(for: profile)
                                                  — получить список process_name для инжекции
              4. ConfigTransformer.makeSocks5Config(from:, port:, routedProcessNames:)
                                                  — трансформировать конфиг (см. ниже)
              5. SudoersManager.isInstalled()      — проверить sudoers для sing-box + networksetup
              6. Process() с sudo -n               — оба режима запускаются через sudo
              7. isRunning = true
              8. SystemProxyHelper.enableSOCKS5(port:)
                                                  — выставить системный SOCKS5-прокси
```

### Трансформация конфига (ConfigTransformer)

Оригинальный профиль sing-box рассчитан на TUN-режим — он может содержать `tun`-inbound и `fakeip` DNS. Для SOCKS5 всё это не нужно и мешает. `ConfigTransformer.makeSocks5Config()` создаёт временный JSON-файл:

1. **Убирает `tun`-inbound** — TUN-интерфейс не нужен
2. **Убирает существующие `socks`-inbound** — заменяет одним чистым
3. **Добавляет SOCKS5-inbound**:
   ```json
   { "type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": 2080 }
   ```
4. **Убирает `fakeip` DNS-серверы** — fake-ip работает только с TUN
5. **Инжектирует `process_name` правило** (если список приложений непустой):
   ```json
   {
     "route": {
       "find_process": true,
       "rules": [
         { "process_name": ["Telegram", "Discord"], "outbound": "proxy" },
         ...остальные правила профиля...
       ]
     }
   }
   ```
   `route.final` намеренно **не меняется** — приложения, не попавшие в список, следуют дефолтной маршрутизации профиля.

Временный файл сохраняется в `/tmp/yurec-socks5-<UUID>.json` и удаляется при остановке.

### Системный прокси macOS

`SystemProxyHelper.enableSOCKS5(port:)` вызывает для каждого активного сетевого сервиса:

```sh
sudo -n /usr/sbin/networksetup -setsocksfirewallproxy "Wi-Fi" 127.0.0.1 2080
sudo -n /usr/sbin/networksetup -setsocksfirewallproxystate "Wi-Fi" on
```

При остановке SOCKS5 (`stop()`, `handleProcessTermination()`, `forceCleanup()`) вызывается `SystemProxyHelper.disableSOCKS5()`:

```sh
sudo -n /usr/sbin/networksetup -setsocksfirewallproxystate "Wi-Fi" off
```

### Остановка SOCKS5

```
ProxyManager.stop()
  1. SIGKILL всем дочерним sing-box процессам
  2. killProcess()
  3. SystemProxyHelper.disableSOCKS5()  — снять системный прокси
  4. cleanupMode()                       — удалить временный конфиг из /tmp
  5. isRunning = false
  6. startLaunchDetectionLoop()
```

---

## Профили

Профили — это JSON-файлы конфигурации sing-box, хранящиеся в `~/.singbox/profiles/`. Приложение наблюдает за этой директорией через **FSEvents** и автоматически обновляет список при добавлении/удалении файлов.

### Что хранится в профиле

Стандартный sing-box JSON с:
- `inbounds` — входящие соединения (TUN, SOCKS5 и др.)
- `outbounds` — исходящие (proxy, direct, block)
- `route.rules` — правила маршрутизации трафика
- `route.final` — дефолтный outbound (обычно `"proxy"`)
- `dns` — DNS-серверы, включая fake-ip для TUN

### Настройки профиля

Каждый профиль независимо хранит:
- **SOCKS5 Port** — порт для режима SOCKS5 (по умолчанию 2080), сохраняется в `UserDefaults`
- **App Routing override** — флаг и собственный список приложений вместо глобального

---

## Маршрутизация по приложениям (App Routing)

Позволяет в режиме SOCKS5 явно указать, какие приложения должны идти через прокси, используя механизм `process_name` в sing-box.

### Двухуровневая система

```
GlobalEntries (UserDefaults: appRouting.global.v1)
     │
     └── применяется ко всем профилям, у которых overridesGlobal = false
              │
         ProfileEntries (UserDefaults: appRouting.profile.entries.<path>)
              │
              └── применяется к конкретному профилю если overridesGlobal = true
```

**Разрешение** (`AppRoutingStore.effectiveEntries(for:)`):
- `profile == nil` → глобальный список
- `profile.overridesGlobal == true` → список профиля
- иначе → глобальный список

### AppRoutingEntry

При добавлении приложения через NSOpenPanel из `AppRoutingEntry(appURL:)` считывается:
- `displayName` — из `CFBundleDisplayName` / `CFBundleName` / имени файла
- `processName` — basename исполняемого файла (именно это sing-box сравнивает в `process_name`)
- `bundleIdentifier` — `CFBundleIdentifier`
- `appPath` — путь к `.app` для иконки

### Как добавить приложение

В настройках (General или Profiles) нажать `+` → открывается `NSOpenPanel` с `/Applications`, настроенный на выбор `.app`-пакетов как файлов (`treatsFilePackagesAsDirectories = false`).

---

## Sudoers и права

И TUN, и SOCKS5 запускаются через `sudo -n` (без пароля). Правило устанавливается **один раз** — при первом подключении показывается стандартный диалог macOS `administrator privileges`.

### Правило (`/etc/sudoers.d/yurec`)

```
# Managed by YurecClient — do not edit
%admin ALL=(root) NOPASSWD: /usr/local/bin/sing-box, /opt/homebrew/bin/sing-box, /bin/kill, /usr/sbin/networksetup
```

Содержит:
- пути к sing-box (стандартные + пользовательский, если задан)
- `/bin/kill` — для SIGKILL осиротевших процессов
- `/usr/sbin/networksetup` — для DNS и системного прокси

Правило проверяется через `sudo -n -l <path>` перед каждым запуском. Если путь к бинарнику изменился (например, обновился Homebrew) — правило переустанавливается автоматически.

---

## Автозапуск и авто-подключение

| Настройка | Механизм | Хранение |
|---|---|---|
| **Launch at Login** | `SMAppService.mainApp` (ServiceManagement.framework) | системный реестр launchd |
| **Auto-connect on Launch** | проверяется в `AppDelegate.applicationDidFinishLaunching` | `UserDefaults: autoConnectOnLaunch` |

При авто-подключении используется активный профиль и TUN-режим (или последний использованный — зависит от реализации `AppDelegate`).

---

## Обнаружение внешних процессов

Если sing-box был запущен не через YurecClient (вручную в терминале, другим приложением), клиент его всё равно подхватит.

### Механизм

При запуске и после остановки `ProxyManager` запускает `startLaunchDetectionLoop()` — фоновый поток, который каждые 2 секунды ищет процесс `sing-box` через `sysctl(KERN_PROC_ALL)`. При обнаружении:

1. Читает аргументы процесса через `sysctl(KERN_PROCARGS2)` — ищет флаг `run` и путь к конфигу (`-c <path>`)
2. Определяет активный профиль по пути к конфигу
3. Вызывает `adoptProcess(pid:profilePath:)` — устанавливает `isRunning = true` и начинает слежение

### Слежение за усыновлённым процессом

Для процессов без `terminationHandler` (нет объекта `Process`) используется **kqueue** (`EVFILT_PROC / NOTE_EXIT`). Это позволяет эффективно ждать завершения без постоянного опроса. Если kqueue недоступен — fallback на polling раз в 2 секунды.

---

## Логи

Лог-файл: `~/Library/Logs/YurecClient/sing-box.log`

Stdout и stderr sing-box перенаправляются в этот файл. Каждый запуск добавляет разделитель:

```
--- YurecClient: starting TUN (Full VPN) @ 2025-01-15 12:00:00 +0000 ---
```

Открыть лог можно через меню: **Open Logs** — откроет Finder, выделив файл.

### Управление размером лога

В настройках (General → Logs) доступно:

- **Current size** — текущий размер файла в B / KB / MB
- **Clear Now** — немедленно очищает файл: обнуляет его и сбрасывает позицию записи в начало, работает в том числе пока sing-box запущен
- **Limit log file size** — включает автоматическое ограничение размера
- **Max size** — порог в мегабайтах (по умолчанию 10 MB). Проверяется как при старте, так и в реальном времени во время работы sing-box

### LogForwarder

Вывод sing-box не перенаправляется напрямую в файл — вместо этого stdout/stderr подключены к `Pipe`, а `LogForwarder` читает данные из обоих pipe'ов через `readabilityHandler` на фоновом GCD-потоке и сам пишет в лог-файл.

Это даёт полный контроль над записью:
- Когда накопленный объём превышает лимит → `fileHandle.truncateFile(atOffset: 0)` + `seek(toFileOffset: 0)` → файл обнуляется, запись продолжается с начала
- `Clear Now` вызывает тот же `rotate()` через форвардер — никакого удаления файла не нужно, sing-box продолжает работать без прерываний
- Файл **никогда не превышает** заданный лимит независимо от длительности сессии

---

## Структура проекта

```
YurecClient/
├── AppDelegate.swift
├── Managers/
│   ├── ConnectionMode.swift         — enum .tun / .socks5(port:), requiresRoot
│   ├── ProxyManager.swift           — ядро: запуск, остановка, process lifecycle
│   ├── ProfileManager.swift         — CRUD профилей, FSEvents, активный профиль
│   ├── ConfigTransformer.swift      — трансформация конфига для SOCKS5
│   ├── AppRoutingEntry.swift        — модель приложения в списке маршрутизации
│   ├── AppRoutingStore.swift        — двухуровневое хранилище глобал/профиль
│   ├── SudoersManager.swift         — установка /etc/sudoers.d/yurec
│   └── LaunchAtLoginManager.swift   — SMAppService обёртка
├── Helpers/
│   ├── DNSHelper.swift              — networksetup DNS для TUN
│   └── SystemProxyHelper.swift      — networksetup SOCKS5 proxy
└── UI/
    ├── StatusMenuController.swift   — NSStatusItem, меню, анимации иконки
    ├── StatusBarIconState.swift     — состояние иконки
    ├── StatusBarIconProvider.swift  — рендер иконки по состоянию
    └── Settings/
        ├── SettingsView.swift           — таб-контейнер
        ├── SettingsWindowController.swift
        ├── GeneralTabView.swift         — Launch at Login, бинарник, App Routing (глобал)
        ├── ProfilesTabView.swift        — список профилей, SOCKS5 порт, App Routing (профиль)
        └── AppRoutingListView.swift     — переиспользуемый список с +/- тулбаром
```
