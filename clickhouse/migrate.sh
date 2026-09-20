#!/bin/sh
set -eu

client() {
    clickhouse-client --host "$CLICKHOUSE_HOST" --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --database "$CLICKHOUSE_DB" "$@"
}

client --query "CREATE TABLE IF NOT EXISTS schema_migrations (version String, applied_at DateTime DEFAULT now()) ENGINE = MergeTree ORDER BY version"

for file in /migrations/*.sql; do
    version=$(basename "$file")
    applied=$(client --query "SELECT count() FROM schema_migrations WHERE version = '$version'")
    if [ "$applied" = "0" ]; then
        echo "applying $version"
        client --multiquery <"$file"
        client --query "INSERT INTO schema_migrations (version) VALUES ('$version')"
    else
        echo "skipping $version, already applied"
    fi
done
