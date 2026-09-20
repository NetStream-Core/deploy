default:
    just --list

up:
    docker compose up -d

down:
    docker compose down

reset:
    docker compose down -v

ps:
    docker compose ps

logs *ARGS:
    docker compose logs -f {{ARGS}}

sql *ARGS:
    docker compose exec clickhouse clickhouse-client --user netstream --password netstream-dev --database netstream {{ARGS}}

validate:
    docker run --rm -v "$PWD/collector/edge.yaml:/cfg.yaml:ro" otel/opentelemetry-collector-contrib:0.161.0 validate --config /cfg.yaml
    docker run --rm -v "$PWD/collector/gateway.yaml:/cfg.yaml:ro" -e CLICKHOUSE_DB=x -e CLICKHOUSE_USER=x -e CLICKHOUSE_PASSWORD=x otel/opentelemetry-collector-contrib:0.161.0 validate --config /cfg.yaml

e2e:
    ./tests/e2e/run.sh
