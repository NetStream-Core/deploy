# deploy

Инфраструктура NetStream-Core: приём телеметрии от агентов и хранение.

```
agent --OTLP--> otel-edge --> Kafka --> otel-gateway --> ClickHouse
```

| Сервис | Образ | Назначение |
|---|---|---|
| `otel-edge` | `otel/opentelemetry-collector-contrib:0.161.0` | Принимает OTLP от агентов (gRPC 4317, HTTP 4318), пишет в Kafka |
| `kafka` | `confluentinc/cp-kafka:7.9.10` | Буфер между приёмом и хранением (KRaft, один брокер, хранение 7 дней) |
| `gateway`, `victim`, `attacker`, `client` | собираются из `lab/` | Лаборатория для датасета (только с `compose.lab.yml`) |
| `otel-gateway` | `otel/opentelemetry-collector-contrib:0.161.0` | Читает из Kafka, пишет в ClickHouse |
| `clickhouse` | `clickhouse/clickhouse-server:25.8` | Хранилище потоков, DNS-событий и срабатываний блоклиста |
| `migrate` | `clickhouse/clickhouse-server:25.8` | Применяет миграции из `clickhouse/migrations` |
| `grafana` | `grafana/grafana:12.4.11` | Дашборды поверх ClickHouse (плагин `grafana-clickhouse-datasource` 4.21.3, ставится при первом запуске) |
| `kafka-ui` | `provectuslabs/kafka-ui:v0.7.2` | Отладка, только с `--profile debug` |

## Запуск

```bash
just up        # docker compose up -d
just ps
just sql       # clickhouse-client внутри контейнера
just demo      # запуск и демо-данные с «атаками» (см. ниже)
just lab-up    # лаборатория с реальными атаками (см. «Лаборатория»)
just down      # остановить, данные сохраняются
just reset     # остановить и удалить данные
```

Порты открыты только на `127.0.0.1` и переопределяются через `.env` (см. `.env.example`): `EDGE_GRPC_PORT`, `EDGE_HTTP_PORT`, `KAFKA_HOST_PORT`, `CLICKHOUSE_HTTP_PORT`, `CLICKHOUSE_NATIVE_PORT`, `GRAFANA_PORT`. Учётные данные ClickHouse по умолчанию (`netstream` / `netstream-dev`) предназначены только для локальной разработки.

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

## Дашборды

Grafana доступна на `http://127.0.0.1:3000` (пользователь `admin`, пароль по умолчанию `netstream-dev`, только для разработки). Дашборды загружаются из `grafana/dashboards` и в интерфейсе не редактируются: изменения вносятся в JSON. Для демонстраций без входа можно задать `GRAFANA_ANONYMOUS=true`: тогда открывается режим только для чтения (только на локальной машине).

| Дашборд | Что показывает |
|---|---|
| `NetStream / Traffic` | Пакеты и объём по направлениям, TCP-рукопожатия и отношение SYN к SYN-ACK (признак SYN-flood), число различных портов назначения на источник (признак сканирования), самые активные пары адресов, доля транспортов, время последней записи от каждого сенсора |
| `NetStream / DNS and blocklist` | Запросы по типам, длина и энтропия имён, число уникальных поддоменов (признак DNS-туннелирования), подозрительные запросы, домены с наибольшим числом уникальных имён, срабатывания блоклиста по действиям |

Переменная **Sensor** фильтрует данные по `host_id`. Сведённые к минутам панели читают `flows_1m`, детальные (таблицы, порты) читают `flows`.

## Демо-данные

```bash
just demo
```

`tools/seed.py` отправляет через edge-collector около 22 тысяч записей на сенсор за последние 90 минут: обычный трафик и три «атаки» в известных окнах времени (минут назад): сканирование портов 70–65, срабатывания блоклиста 52–48, SYN-flood 45–35, DNS-туннель 25–15. Параметры: `--hosts`, `--minutes`, `--seed`, `--endpoint`. Данные детерминированы при одинаковом `--seed`.

## Лаборатория для датасета

Стенд из четырёх контейнеров поверх основного стека. Агент работает на шлюзе и видит трафик так, как его видел бы сенсор в реальной сети.

```
attacker 10.10.0.10 ┐                               ┌ victim 10.20.0.10 (nginx, dnsmasq)
                    ├── lan ── gateway (агент) ── dmz ┘
client   10.10.0.20 ┘         10.10.0.2 / 10.20.0.2
```

Агент подключается к LAN-интерфейсу шлюза: входящий трафик клиентов и атакующего он видит через XDP, ответы жертвы через TC. Обычный клиент (`client`) постоянно создаёт фоновый трафик (HTTP-запросы и DNS-запросы обычных имён), поэтому атаки происходят на фоне нормальной активности.

```bash
just lab-agent ../agent      # копирует release-бинарник и prog.bpf.o из checkout агента
just lab-up                  # стек и лаборатория
just lab-run syn_flood duration=30 rate=1000
just lab-run port_scan ports=1-1024 rate=100
just lab-run dns_tunnel duration=30 rate=20 qtype=mixed
just lab-run c2_beacon duration=30 rate=2
just lab-down
```

Docker Desktop нужен на Linux-ядре с поддержкой eBPF (проверено на `6.10.14-linuxkit`); шлюз запускается в привилегированном контейнере, права `sudo` на хосте не требуются.

| Сценарий | Инструмент | Параметры (по умолчанию) |
|---|---|---|
| `syn_flood` | `hping3 -S` | `rate` пакетов/с (1000), `duration` (30), `port` (80), `keep=1` фиксирует порт источника |
| `port_scan` | `nmap -sS` | `ports` (1-1024), `rate` пакетов/с (100), `timing` (4) |
| `dns_tunnel` | `dns_tunnel.py`, эмуляция туннеля | `rate` запросов/с (20), `duration` (30), `qtype` `TXT`, `NULL` или `mixed` |
| `c2_beacon` | `beacon.py` | `rate` (2), `duration` (30): запросы к домену из блоклиста |
| `benign` | `benign.py` | Фоновый клиент работает всегда; сценарий только фиксирует окно |

Каждый запуск записывается в таблицу `labels`: сценарий, метка, инструмент, параметры, адреса атакующего и жертвы, начало и конец окна. Времена берутся с часов шлюза, на которых агент ставит метки записям.

**Размеченные данные.** Представления `labeled_flows` и `labeled_dns` добавляют к записям столбцы `label` и `run_id`: запись относится к атаке, если её источник или получатель это адрес атакующего и время попадает в окно запуска. Всё остальное получает метку `benign`. Для потоков учитывается, что запись создаётся в конце интервала съёма (`ts - interval_ms` до `ts`), для DNS-запросов добавляется допуск в секунду.

```sql
SELECT label, count() AS records, sum(packets) AS packets FROM labeled_flows GROUP BY label;
```

**Ограничения.**
- Ключ потока это пятёрка (адреса, порты, протокол), а порт источника при флуде меняется с каждым пакетом. Поэтому флуд порождает до сотен потоков в секунду, а таблица потоков в ядре ограничена 10240 записями. Скорости выше нескольких тысяч пакетов в секунду приведут к потере записей; фактическая скорость `hping3` заметно ниже заданной. Для эксперимента можно использовать `keep=1`.
- Источник адресов в атаках не подделывается: метка определяется по адресу атакующего.
- DNS-туннель эмулируется: нагрузка кодируется в base32 и разбивается на метки имени, как это делают реальные инструменты. Использование `iodine` или `dnscat2` можно добавить отдельным сценарием.
- Все узлы работают на одной машине и одном ядре, поэтому задержки и потери не соответствуют реальной сети.

## Тесты

```bash
just e2e
```

Тест поднимает отдельный проект `netstream-e2e` на свободных портах, отправляет три записи через edge-collector и проверяет: содержимое типизированных таблиц и агрегата, идемпотентность миграций, то, что при остановленном gateway данные накапливаются в Kafka и доходят после его запуска, что Grafana поднимает источник данных и оба дашборда, и что всплеск из десятков тысяч записей сохраняется без потерь. `KEEP=1 just e2e` оставляет стек запущенным для отладки. `just lab-e2e` запускает лабораторию, выполняет все сценарии и проверяет размеченные данные.

## Ограничения

- Размер сообщения Kafka ограничен: edge собирает батчи по 1024 записи, сжимает их (zstd), лимит брокера и продюсера 4 МиБ. Слишком крупный батч отбрасывается без повторов, поэтому на это есть регрессионная проверка в e2e.
- Один брокер Kafka без репликации, без TLS и аутентификации: конфигурация для разработки и стенда.
- Метрики агента попадают в топик `netstream.metrics.v1`, но потребителя у него пока нет.
- Очередь отправки в edge-collector хранится в памяти: при его перезапуске непереданные данные теряются.
