#!/usr/bin/env bash
# Checks the two properties `clickhouse/migrate.sh` relies on but nothing
# previously verified directly (P3 from the external review):
#
#   1. every real migration in clickhouse/migrations/ applies in order,
#      from a clean database, in one pass;
#   2. a migration that fails partway through a multi-statement file
#      leaves the database in a state a retry can recover from — because
#      `--multiquery` runs statements one at a time with no transaction
#      wrapping them, so a later statement failing leaves earlier ones in
#      this same file already applied, while `schema_migrations` never
#      gets a row for it (the INSERT only runs after the whole file
#      succeeds). The real migrations only get away with this because
#      every CREATE TABLE/VIEW/MATERIALIZED VIEW in them is paired with
#      `IF NOT EXISTS`, `OR REPLACE`, or its own `DROP ... IF EXISTS` —
#      this test is what would actually catch a future migration that
#      forgets that discipline, a static grep would not.
set -u

cd "$(dirname "$0")/../.."

NETWORK="netstream-migrations-test"
CONTAINER="netstream-migrations-test-ch"
FAILED=0
# Under the repo, not /tmp: Docker Desktop only shares bind-mount sources
# that live inside directories it already knows about (the project tree),
# not the host's whole filesystem - a /tmp mktemp dir mounts with "mounts
# denied" instead of the migrations it's supposed to hold.
WORKDIR=$(mktemp -d tests/clickhouse/.tmp-XXXXXX)
WORKDIR=$(cd "$WORKDIR" && pwd)

check() {
    local label=$1 actual=$2 expected=$3
    if [ "$actual" = "$expected" ]; then
        echo "  OK   $label"
    else
        echo "  FAIL $label"
        echo "       expected: $expected"
        echo "       actual:   $actual"
        FAILED=1
    fi
}

ch() {
    docker exec "$CONTAINER" clickhouse-client --user netstream --password netstream-dev --database netstream --format TSV --query "$1"
}

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1
    docker network rm "$NETWORK" >/dev/null 2>&1
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "== starting a clean ClickHouse"
docker network create "$NETWORK" >/dev/null 2>&1
docker run -d --rm --name "$CONTAINER" --network "$NETWORK" \
    -e CLICKHOUSE_DB=netstream -e CLICKHOUSE_USER=netstream -e CLICKHOUSE_PASSWORD=netstream-dev \
    -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
    clickhouse/clickhouse-server:25.8 >/dev/null

run_migrate() {
    docker run --rm --network "$NETWORK" \
        -e CLICKHOUSE_HOST="$CONTAINER" -e CLICKHOUSE_DB=netstream \
        -e CLICKHOUSE_USER=netstream -e CLICKHOUSE_PASSWORD=netstream-dev \
        -v "$WORKDIR/migrate.sh:/migrate.sh:ro" \
        -v "$1:/migrations:ro" \
        --entrypoint /bin/sh \
        clickhouse/clickhouse-server:25.8 /migrate.sh
}

# `docker exec` (a client inside the same container, over its loopback)
# can see ClickHouse answer `SELECT 1` a moment before the native port is
# actually accepting connections from *other* containers on this network
# - the exact path `run_migrate` uses. Waiting via that same path instead
# of `docker exec` is what actually proves `run_migrate` won't hit the
# same "Connection refused" race.
for _ in $(seq 1 30); do
    docker run --rm --network "$NETWORK" clickhouse/clickhouse-server:25.8 \
        clickhouse-client --host "$CONTAINER" --user netstream --password netstream-dev --query "SELECT 1" \
        >/dev/null 2>&1 && break
    sleep 1
done

cp clickhouse/migrate.sh "$WORKDIR/migrate.sh"

echo "== every real migration applies in order from a clean database"
real_migrations=$(mktemp -d tests/clickhouse/.tmp-XXXXXX); real_migrations=$(cd "$real_migrations" && pwd)
cp clickhouse/migrations/*.sql "$real_migrations/"
first_run=$(run_migrate "$real_migrations" 2>&1)
applied_order=$(echo "$first_run" | grep '^applying' | sed 's/^applying //')
expected_order=$(cd clickhouse/migrations && ls *.sql | sort)
check "migrations applied in filename order" "$applied_order" "$expected_order"
check "no migration was skipped on the first run" "$(echo "$first_run" | grep -c '^skipping')" 0

echo "== re-running is a no-op (same property the e2e suite checks, kept here as a baseline)"
second_run=$(run_migrate "$real_migrations" 2>&1)
check "second run skips every migration" "$(echo "$second_run" | grep -c '^skipping')" "$(ls clickhouse/migrations/*.sql | wc -l)"
check "second run applies nothing" "$(echo "$second_run" | grep -c '^applying')" 0

echo "== recovery after a migration fails partway through"
docker exec "$CONTAINER" clickhouse-client --user netstream --password netstream-dev --query "DROP DATABASE netstream" >/dev/null 2>&1
docker exec "$CONTAINER" clickhouse-client --user netstream --password netstream-dev --query "CREATE DATABASE netstream" >/dev/null 2>&1
docker exec "$CONTAINER" clickhouse-client --user netstream --password netstream-dev --database netstream --query "DROP TABLE IF EXISTS schema_migrations" >/dev/null 2>&1

broken_migrations=$(mktemp -d tests/clickhouse/.tmp-XXXXXX); broken_migrations=$(cd "$broken_migrations" && pwd)
cp clickhouse/migrations/*.sql "$broken_migrations/"
# A migration whose second statement is guaranteed to fail (bogus type),
# after a first statement that succeeds and is idempotent on retry -
# exactly the shape every real migration already has to be.
cat >"$broken_migrations/999_test_partial_failure.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS partial_failure_probe (x UInt8) ENGINE = Memory;

ALTER TABLE partial_failure_probe ADD COLUMN IF NOT EXISTS y NotARealType;
EOF

broken_run=$(run_migrate "$broken_migrations" 2>&1)
broken_exit=$?
check "the broken migration run fails" "$([ "$broken_exit" -ne 0 ] && echo yes)" yes
check "the first (valid) statement of the failed file was applied" \
    "$(ch "SELECT count() FROM system.tables WHERE database = 'netstream' AND name = 'partial_failure_probe'")" \
    1
check "the failed migration was not recorded as applied" \
    "$(ch "SELECT count() FROM schema_migrations WHERE version = '999_test_partial_failure.sql'")" \
    0
check "every earlier migration still got recorded" \
    "$(ch "SELECT count() FROM schema_migrations")" \
    "$(ls clickhouse/migrations/*.sql | wc -l)"

echo "== retrying after the fix recovers cleanly"
cat >"$broken_migrations/999_test_partial_failure.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS partial_failure_probe (x UInt8) ENGINE = Memory;

ALTER TABLE partial_failure_probe ADD COLUMN IF NOT EXISTS y UInt8;
EOF

retry_run=$(run_migrate "$broken_migrations" 2>&1)
check "retry re-applies only the fixed migration" "$(echo "$retry_run" | grep -c '^applying')" 1
check "retry skips every already-applied migration" \
    "$(echo "$retry_run" | grep -c '^skipping')" \
    "$(ls clickhouse/migrations/*.sql | wc -l)"
check "the fixed migration is now recorded as applied" \
    "$(ch "SELECT count() FROM schema_migrations WHERE version = '999_test_partial_failure.sql'")" \
    1
check "the probe table has the column the fixed statement added" \
    "$(ch "SELECT count() FROM system.columns WHERE database = 'netstream' AND table = 'partial_failure_probe' AND name = 'y'")" \
    1

rm -rf "$real_migrations" "$broken_migrations"

echo
if [ $FAILED -eq 0 ]; then echo "RESULT: OK"; else echo "RESULT: FAILED"; fi
exit $FAILED
