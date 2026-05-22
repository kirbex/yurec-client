# Ограничение: системные приложения Apple с общим сетевым процессом

## Суть проблемы

Маршрутизация по имени процесса в sing-box работает так: когда приложение открывает TCP-соединение, sing-box определяет имя процесса, который его инициировал, и применяет соответствующее правило. Это отлично работает для сторонних приложений (Telegram, Claude, VS Code и т.д.), у которых есть собственный сетевой стек.

**Системные приложения Apple устроены иначе.** Safari, Mail, News, App Store и ряд других приложений делегируют все сетевые операции в **общий системный XPC-сервис WebKit**:

```
com.apple.WebKit.Networking
```

Этот процесс живёт не внутри `Safari.app` — он находится в системном фреймворке:

```
/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/
  WebKit.framework/Versions/A/XPCServices/
    com.apple.WebKit.Networking.xpc/Contents/MacOS/
      com.apple.WebKit.Networking
```

## Что происходит при добавлении Safari в список приложений

```
Пользователь добавляет Safari.app
  │
  └─ allProcessNames сканирует Safari.app/Contents/
       находит: "Safari" (основной процесс)
       не находит: com.apple.WebKit.Networking (он не в бандле приложения)

Пользователь открывает страницу в Safari
  │
  ├─ Safari.app/Safari           — рендеринг, UI
  └─ com.apple.WebKit.Networking — все TCP-соединения (HTTP/HTTPS)

sing-box смотрит кто открыл соединение:
  process_name = "com.apple.WebKit.Networking"
  правило для "Safari" → не совпадает
  → route.final = direct → трафик идёт напрямую, минуя VPN
```

## Затронутые приложения

Все приложения, которые используют `com.apple.WebKit.Networking` для сетевых запросов:

| Приложение | Поведение |
|---|---|
| Safari | Весь веб-трафик через WebKit.Networking |
| Mail | Загрузка содержимого писем (изображения, web-части) |
| News | Весь контент |
| App Store | Запросы к API Apple |
| Другие системные приложения | Зависит от реализации |

## Почему это нельзя решить «в лоб»

Добавление `com.apple.WebKit.Networking` в список маршрутизации технически возможно, но имеет серьёзный побочный эффект: **все** перечисленные выше приложения начнут ходить через VPN, а не только Safari. Пользователь добавил Safari, но получит заодно Mail, News и App Store.

Это архитектурное ограничение macOS — один shared-процесс на всю систему, разделить его по приложениям на уровне process_name невозможно.

## Приложения, которые работают корректно

Для сравнения — приложения с собственным сетевым стеком:

| Приложение | Сетевой процесс | Маршрутизация |
|---|---|---|
| Telegram | `Telegram` | ✅ Работает |
| Claude | `Claude`, `Claude Helper (Renderer)`, ... | ✅ Работает |
| VS Code | `Code`, `Code Helper`, ... | ✅ Работает |
| ChatGPT | `ChatGPT`, `ChatGPT Helper (Renderer)`, ... | ✅ Работает |
| Chrome / Edge | `Google Chrome Helper`, `msedge`, ... | ✅ Работает |
| Firefox | `firefox` | ✅ Работает |
| Safari | `Safari` → сеть через `com.apple.WebKit.Networking` | ❌ Не работает |

## Возможные направления решения

Подробно: [ipv6-server-protection-options.md](ipv6-server-protection-options.md) — аналогичный формат анализа вариантов, если будет принято решение разбирать эту проблему.

Варианты в общих чертах:
1. **Предупреждение в UI** — при добавлении Safari показывать сообщение, что маршрутизация не будет работать из-за архитектуры WebKit
2. **Добавлять `com.apple.WebKit.Networking` с явным предупреждением** — пользователь осознанно принимает, что Mail и News тоже пойдут через VPN
3. **Детектировать affected-приложения автоматически** — при сканировании бандла проверять, есть ли у приложения собственный сетевой процесс или оно использует shared WebKit
