// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"context"
	"errors"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// NATS JetStream: one file-backed stream over the test's subjects, one
// durable pull consumer per group (two processes on one durable = a work
// queue), explicit ack, AckWait 5 s, publish dedup by Nats-Msg-Id.
type natsBackend struct{ url string }

const natsStream = "SPOOL"

func (b *natsBackend) Name() string      { return "nats" }
func (b *natsBackend) Container() string { return "spike-nats" }

func (b *natsBackend) connect() (*nats.Conn, jetstream.JetStream, error) {
	nc, err := nats.Connect(b.url, nats.MaxReconnects(-1), nats.ReconnectWait(200*time.Millisecond),
		nats.RetryOnFailedConnect(true))
	if err != nil {
		return nil, nil, err
	}
	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, nil, err
	}
	return nc, js, nil
}

func (b *natsBackend) Setup(ctx context.Context, groups map[string][]string, _ int) error {
	nc, js, err := b.connect()
	if err != nil {
		return err
	}
	defer nc.Close()
	if err := js.DeleteStream(ctx, natsStream); err != nil && !errors.Is(err, jetstream.ErrStreamNotFound) {
		return err
	}
	var subjects []string
	for s := range groups {
		subjects = append(subjects, s)
	}
	if _, err := js.CreateStream(ctx, jetstream.StreamConfig{
		Name: natsStream, Subjects: subjects, Storage: jetstream.FileStorage,
		Duplicates: 2 * time.Minute,
	}); err != nil {
		return err
	}
	for s, gs := range groups {
		for _, g := range gs {
			if _, err := js.CreateOrUpdateConsumer(ctx, natsStream, jetstream.ConsumerConfig{
				Durable: g, FilterSubject: s, AckPolicy: jetstream.AckExplicitPolicy,
				AckWait: 5 * time.Second, DeliverPolicy: jetstream.DeliverAllPolicy, MaxAckPending: 1000,
			}); err != nil {
				return err
			}
		}
	}
	return nil
}

type natsProducer struct {
	nc *nats.Conn
	js jetstream.JetStream
}

func (b *natsBackend) Producer(context.Context) (Producer, error) {
	nc, js, err := b.connect()
	if err != nil {
		return nil, err
	}
	return &natsProducer{nc, js}, nil
}

func (p *natsProducer) Publish(ctx context.Context, subject, id string, data []byte) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	_, err := p.js.Publish(ctx, subject, data, jetstream.WithMsgID(id))
	return err
}

func (p *natsProducer) Close() { p.nc.Close() }

type natsConsumer struct {
	nc *nats.Conn
	it jetstream.MessagesContext
}

func (b *natsBackend) Consumer(ctx context.Context, _, group, _ string) (Consumer, error) {
	nc, js, err := b.connect()
	if err != nil {
		return nil, err
	}
	c, err := js.Consumer(ctx, natsStream, group)
	if err != nil {
		nc.Close()
		return nil, err
	}
	it, err := c.Messages(jetstream.PullMaxMessages(10))
	if err != nil {
		nc.Close()
		return nil, err
	}
	return &natsConsumer{nc, it}, nil
}

func (c *natsConsumer) Next(_ context.Context, wait time.Duration) (*Msg, error) {
	m, err := c.it.Next(jetstream.NextMaxWait(wait))
	if err != nil {
		if errors.Is(err, nats.ErrTimeout) || errors.Is(err, jetstream.ErrNoMessages) {
			return nil, errIdle
		}
		return nil, err
	}
	return &Msg{Data: m.Data(), Ack: func(ctx context.Context) error { return m.DoubleAck(ctx) }}, nil
}

func (c *natsConsumer) Ready() bool { return true }

func (c *natsConsumer) Close() { c.it.Stop(); c.nc.Close() }
