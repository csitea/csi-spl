// SPDX-License-Identifier: AGPL-3.0-only

// Spec 059 broker spike: one Producer / Consumer pair per backend, so the four
// tests in run.go drive NATS JetStream, single-node Kafka and Postgres claims
// (SKIP LOCKED) through the same code. Dev only; nothing here is wired into
// the hub.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Payload is what every backend carries: a msg id (the dedup key) and the
// producer's wall clock, so a consumer on the same host measures latency.
type Payload struct {
	ID   string `json:"id"`
	TSNs int64  `json:"ts_ns"`
}

func encode(id string) []byte {
	b, _ := json.Marshal(Payload{ID: id, TSNs: time.Now().UnixNano()})
	return b
}

func decode(b []byte) (Payload, error) {
	var p Payload
	err := json.Unmarshal(b, &p)
	return p, err
}

// Msg is one delivery; Ack commits it (offset, ack or claim row).
type Msg struct {
	Data []byte
	Ack  func(context.Context) error
}

type Producer interface {
	Publish(ctx context.Context, subject, id string, data []byte) error
	Close()
}

type Consumer interface {
	// Next blocks up to wait for one delivery; errIdle when none arrived.
	Next(ctx context.Context, wait time.Duration) (*Msg, error)
	// Ready reports that the consumer holds its subscription (Kafka: the
	// group has assigned it partitions), so a test may start producing.
	Ready() bool
	Close()
}

var errIdle = errors.New("idle")

// Backend is one broker under test.
type Backend interface {
	Name() string
	// Setup creates the subjects/topics/tables for a test, empty. groups maps
	// a subject to the consumer groups that must each receive it.
	Setup(ctx context.Context, groups map[string][]string, partitions int) error
	Producer(ctx context.Context) (Producer, error)
	Consumer(ctx context.Context, subject, group, name string) (Consumer, error)
	// Container is the docker container restarted by test 4.
	Container() string
}

func backendByName(name string) (Backend, error) {
	switch name {
	case "nats":
		return &natsBackend{url: envOr("SPIKE_NATS_URL", "nats://127.0.0.1:14222")}, nil
	case "kafka":
		return &kafkaBackend{broker: envOr("SPIKE_KAFKA_BROKER", "127.0.0.1:19092")}, nil
	case "pgq":
		return &pgqBackend{dsn: envOr("SPIKE_PG_DSN", "postgres://spike:spike@127.0.0.1:15432/spike?sslmode=disable")}, nil
	}
	return nil, fmt.Errorf("unknown backend %q (nats | kafka | pgq)", name)
}
