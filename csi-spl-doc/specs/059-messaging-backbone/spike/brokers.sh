#!/bin/bash
# Spec 059 broker spike: start | stop | stats for the three throwaway brokers,
# each bound to 127.0.0.1 only. Dev box only; nothing here touches the hub.
#   bash brokers.sh start|stop|stats
set -euo pipefail

nats_up() {
  docker run -d --name spike-nats -p 127.0.0.1:14222:4222 nats:2.11-alpine -js -sd /data >/dev/null
}

kafka_up() {
  docker run -d --name spike-kafka -p 127.0.0.1:19092:9092 \
    -e KAFKA_NODE_ID=1 -e KAFKA_PROCESS_ROLES=broker,controller \
    -e KAFKA_LISTENERS=PLAINTEXT://:9092,CONTROLLER://:9093 \
    -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://127.0.0.1:19092 \
    -e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
    -e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT \
    -e KAFKA_CONTROLLER_QUORUM_VOTERS=1@localhost:9093 \
    -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 -e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
    -e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 -e KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS=0 \
    -e KAFKA_LOG_DIRS=/var/lib/kafka/data \
    apache/kafka:4.1.0 >/dev/null
}

pg_up() {
  docker run -d --name spike-pg -p 127.0.0.1:15432:5432 \
    -e POSTGRES_USER=spike -e POSTGRES_PASSWORD=spike -e POSTGRES_DB=spike \
    postgres:16-alpine >/dev/null
}

case "${1:-}" in
  start)
    nats_up; kafka_up; pg_up
    ;;
  stop)
    docker rm -f spike-nats spike-kafka spike-pg >/dev/null 2>&1 || true
    ;;
  stats)
    docker stats --no-stream --format '{{.Name}} mem={{.MemUsage}} cpu={{.CPUPerc}}' spike-nats spike-kafka spike-pg
    docker exec spike-nats du -sh /data 2>/dev/null | sed 's/^/spike-nats disk=/'
    docker exec spike-kafka du -sh /var/lib/kafka/data 2>/dev/null | sed 's/^/spike-kafka disk=/'
    docker exec spike-pg du -sh /var/lib/postgresql/data 2>/dev/null | sed 's/^/spike-pg disk=/'
    ;;
  *)
    echo "usage: $0 start|stop|stats" >&2; exit 2
    ;;
esac
