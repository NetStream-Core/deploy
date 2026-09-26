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

seed *ARGS:
    python3 tools/seed.py {{ARGS}}

demo: up
    sleep 30
    python3 tools/seed.py

lab-agent AGENT_DIR="../agent":
    mkdir -p lab/gateway/artifacts
    cp {{AGENT_DIR}}/target/release/network-monitor-agent lab/gateway/artifacts/
    cp {{AGENT_DIR}}/public_suffix_list.dat lab/gateway/artifacts/
    python3 lab/build_info.py {{AGENT_DIR}} lab/gateway/artifacts/build_info.json

lab-up:
    docker compose -f compose.yml -f lab/compose.lab.yml up -d --build kafka kafka-init clickhouse migrate otel-edge otel-gateway gateway victim tunnel attacker client

lab-down:
    docker compose -f compose.yml -f lab/compose.lab.yml down -v

lab-run *ARGS:
    ./lab/run.sh {{ARGS}}

e2e:
    ./tests/e2e/run.sh

lab-scenarios:
    ./tests/lab/scenarios.sh

lab-e2e:
    ./tests/lab/run.sh

lab-campaign FILE="lab/campaigns/v1.yaml" *ARGS:
    python3 lab/campaign.py {{FILE}} {{ARGS}}
