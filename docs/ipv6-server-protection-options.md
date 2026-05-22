# Защита от отсутствия IPv6 на VPN-сервере

## Контекст

Текущий фикс (`DNSHelper.hasGlobalIPv6()` → `strategy: ipv4_only`) решает проблему когда **у клиента** нет IPv6. Но есть ещё один сценарий: у клиента IPv6 есть, а у VPN-сервера — нет.

В TUN-режиме (`route.final = "proxy"`) весь трафик проходит через сервер. Если клиент пытается подключиться по IPv6, а сервер не может пробросить соединение дальше — возникнет та же картина: `ERR_CONNECTION_RESET`.

### Когда sniff спасает, когда нет

```
sniff сработал (TLS с SNI — большинство сайтов):
  sing-box → VLESS → сервер получает "example.com"
  сервер сам резолвит → нет IPv6 → берёт IPv4 ✅

sniff НЕ сработал (plain HTTP, QUIC, нестандартный TLS):
  sing-box → VLESS → сервер получает "2001:db8::1"
  сервер пытается IPv6 → нет IPv6 → RST ❌
```

---

## Вариант 1 — `domain_strategy` на proxy-outbound

Sing-box поддерживает `domain_strategy` на уровне outbound. Когда цель — домен (после sniff), sing-box **сам** резолвит его до передачи на сервер и выбирает IPv4. Сервер получает уже IPv4-адрес и не нуждается в IPv6.

### Изменение в `ConfigTransformer`

В `makeSocks5Config` и `makeTunConfig` обходим все proxy-outbounds и добавляем поле:

```swift
if var outbounds = config["outbounds"] as? [[String: Any]] {
    let proxyTypes: Set<String> = ["vless", "vmess", "trojan", "shadowsocks", "hysteria2"]
    config["outbounds"] = outbounds.map { outbound in
        guard let type = outbound["type"] as? String,
              proxyTypes.contains(type) else { return outbound }
        var o = outbound
        o["domain_strategy"] = "ipv4_only"
        return o
    }
}
```

### Покрытие

| Сценарий | Покрыто |
|---|---|
| sniff сработал, сервер без IPv6 | ✅ |
| sniff НЕ сработал, сервер без IPv6 | ❌ |

### Плюсы и минусы

- ✅ Минимальное изменение, не влияет на прямые соединения
- ✅ Не требует сетевых проверок, применяется мгновенно
- ✅ Покрывает 95%+ реальных случаев (plain HTTP практически вымер, QUIC уже блокируется отдельным правилом)
- ❌ Не защищает от raw IPv6 при провале sniff

---

## Вариант 2 — Активная проверка IPv6 через VPN после подключения

После старта VPN делаем тестовый запрос через прокси к известному IPv6-only эндпоинту. Если не отвечает — перегенерируем конфиг с `strategy: ipv4_only` и рестартуем.

### Логика

```
1. VPN поднялся
2. Ждём N секунд (VPN полностью инициализировался)
3. curl --proxy socks5://127.0.0.1:<port> https://ipv6only.arpa/
   (или любой публичный IPv6-only эндпоинт)
4. Успех → сервер имеет IPv6, конфиг не меняем
5. Таймаут/ошибка → сервер без IPv6
   → пересобрать конфиг с ipv4_only
   → рестарт sing-box (незаметно для пользователя)
```

### Примерная реализация в ProxyManager

```swift
private func checkServerIPv6(socksPort: Int) async -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = [
        "--proxy", "socks5://127.0.0.1:\(socksPort)",
        "--max-time", "5",
        "--silent", "--output", "/dev/null",
        "--write-out", "%{http_code}",
        "https://ipv6only.arpa/"
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return output.hasPrefix("2") || output.hasPrefix("3")
}
```

### Покрытие

| Сценарий | Покрыто |
|---|---|
| sniff сработал, сервер без IPv6 | ✅ |
| sniff НЕ сработал, сервер без IPv6 | ✅ |

### Плюсы и минусы

- ✅ Полное покрытие всех сценариев
- ✅ Точно отражает реальные возможности сервера
- ❌ Добавляет ~3–5 сек задержки к старту (или тихий рестарт после подключения)
- ❌ Требует надёжного IPv6-only тест-эндпоинта (может быть недоступен)
- ❌ Усложняет логику ProxyManager (тихий рестарт, состояния)

---

## Сравнительная таблица

| | Текущий фикс | + Вариант 1 | + Вариант 2 |
|---|---|---|---|
| Клиент без IPv6, SOCKS5 hybrid | ✅ | ✅ | ✅ |
| Сервер без IPv6, sniff сработал | ❌ | ✅ | ✅ |
| Сервер без IPv6, sniff провалился | ❌ | ❌ | ✅ |
| Сложность реализации | — | низкая | высокая |
| Влияние на UX | нет | нет | небольшое (задержка) |

---

## Рекомендация

На практике sniff проваливается редко: plain HTTP исчез, QUIC (UDP 443) уже блокируется отдельным правилом для proxy-процессов. Поэтому **Вариант 1** даёт хорошее покрытие при минимальной сложности.

**Вариант 2** имеет смысл если появятся жалобы пользователей с IPv6-сетями, у которых сервер без IPv6.
