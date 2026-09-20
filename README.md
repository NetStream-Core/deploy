# deploy

Инфраструктура NetStream-Core: приём телеметрии от агентов и хранение.

```
agent --OTLP--> otel-edge --> Kafka --> otel-gateway --> ClickHouse
```

| Сервис | Образ | Назначение |
|---|---|---|
| `otel-edge` | `otel/opentelemetry-collector-contrib:0.161.0` | Принимает OTLP от агентов (gRPC 4317, HTTP 4318), пишет в Kafka |
| `kafka` | `confluentinc/cp-kafka:7.9.10` | Буфер между приёмом и хранением (KRaft, один брокер, хранение 7 дней) |
| `otel-gateway` | `otel/opentelemetry-collector-contrib:0.161.0` | Читает из Kafka, пишет в ClickHouse |
| `clickhouse` | `clickhouse/clickhouse-server:25.8` | Хранилище потоков, DNS-событий и срабатываний блоклиста |
| `migrate` | `clickhouse/clickhouse-server:25.8` | Применяет миграции из `clickhouse/migrations` |
| `kafka-ui` | `provectuslabs/kafka-ui:v0.7.2` | Отладка, только с `--profile debug` |

## Запуск

```bash
just up        # docker compose up -d
just ps
just sql       # clickhouse-client внутри контейнера
just down      # остановить, данные сохраняются
just reset     # остановить и удалить данные
```

Порты открыты только на `127.0.0.1` и переопределяются через `.env` (см. `.env.example`): `EDGE_GRPC_PORT`, `EDGE_HTTP_PORT`, `KAFKA_HOST_PORT`, `CLICKHOUSE_HTTP_PORT`, `CLICKHOUSE_NATIVE_PORT`. Учётные данные ClickHouse по умолчанию (`netstream` / `netstream-dev`) предназначены только для локальной разработки.

Агент направляется на `http://127.0.0.1:4317` (по умолчанию так и есть, см. `OTEL_EXPORTER_OTLP_ENDPOINT`).

## Миграции

Файлы `clickhouse/migrations/NNN_*.sql` применяются раннером `migrate` по порядку и один раз каждый; применённые версии записываются в `schema_migrations`. Раннер запускается при каждом `up`, поэтому схема развивается на непустой базе. Уже применённый файл менять нельзя: изменение оформляется новой миграцией.

| Таблица | Содержимое | Хранение |
|---|---|---|
| `otel_logs` | Сырые записи от collector, промежуточный слой | 3 дня |
| `flows` | Дельты по потокам за интервал съёма | 14 дней |
| `dns_queries` | DNS-запросы с признаками | 14 дней |
| `blocklist_hits` | Срабатывания блоклиста | 90 дней |
| `flows_1m` | Суммы по минутам (host, направление, транспорт) | 90 дней |

Типизированные таблицы заполняются materialized views из `otel_logs` по полю `EventName`.

## Контракт событий

Агент отправляет OTLP-логи. Тип события задаётся полем `event_name` записи, числа передаются целыми (`intValue`), а не строками. Имена атрибутов следуют семантическим соглашениям OpenTelemetry там, где они есть.

**Resource-атрибуты** (общие для всех записей агента)

| Атрибут | Пример |
|---|---|
| `service.name` | `netstream-monitor-agent` |
| `host.id` | идентификатор сенсора |
| `network.interface.name` | `eth0` |

**`netstream.flow`**: дельта по потоку за интервал

| Атрибут | Тип | Колонка |
|---|---|---|
| `network.io.direction` | `receive` или `transmit` | `direction` |
| `network.transport` | `tcp`, `udp`, `icmp`, другое | `transport` |
| `source.address`, `destination.address` | IPv4 | `src_ip`, `dst_ip` |
| `source.port`, `destination.port` | int | `src_port`, `dst_port` |
| `netstream.flow.interval_ms` | int | `interval_ms` |
| `netstream.flow.packets` | int | `packets` |
| `netstream.flow.bytes.ip`, `netstream.flow.bytes.payload` | int | `ip_bytes`, `payload_bytes` |
| `netstream.flow.tcp.syn`, `.synack`, `.fin`, `.rst` | int | `tcp_syn`, `tcp_synack`, `tcp_fin`, `tcp_rst` |

**`netstream.dns.query`**: один DNS-запрос

| Атрибут | Тип | Колонка |
|---|---|---|
| `network.io.direction` | `receive` или `transmit` | `direction` |
| `source.address`, `destination.address` | IPv4 | `src_ip`, `dst_ip` |
| `dns.question.name` | string, нижний регистр | `qname` |
| `netstream.dns.question.type` | `A`, `TXT`, `NULL`, `AAAA`, … | `qtype` |
| `netstream.dns.qname.length`, `.labels`, `.longest_label` | int | `qname_length`, `label_count`, `longest_label` |
| `netstream.dns.qname.entropy`, `.digit_ratio` | double | `entropy`, `digit_ratio` |
| `netstream.dns.unique_subdomains` | int | `unique_subdomains` |

**`netstream.blocklist.hit`**: срабатывание блоклиста

| Атрибут | Тип | Колонка |
|---|---|---|
| `source.address` | IPv4 | `src_ip` |
| `netstream.hit.domain` | string | `domain` |
| `netstream.hit.action` | `observed`, `dropped`, `quarantined` | `action` |

Метки времени записи (`timeUnixNano`) попадают в `ts`.

## Тесты

```bash
just e2e
```

Тест поднимает отдельный проект `netstream-e2e` на свободных портах, отправляет три записи через edge-collector и проверяет: содержимое типизированных таблиц и агрегата, идемпотентность миграций и то, что при остановленном gateway данные накапливаются в Kafka и доходят после его запуска. `KEEP=1 just e2e` оставляет стек запущенным для отладки.

## Ограничения

- Один брокер Kafka без репликации, без TLS и аутентификации: конфигурация для разработки и стенда.
- Метрики агента попадают в топик `netstream.metrics.v1`, но потребителя у него пока нет.
- Очередь отправки в edge-collector хранится в памяти: при его перезапуске непереданные данные теряются.
