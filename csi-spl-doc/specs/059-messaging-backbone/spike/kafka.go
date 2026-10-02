// SPDX-License-Identifier: AGPL-3.0-only

package main

import (
	"context"
	"errors"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kgo"
)

// Single-node Kafka (KRaft): one topic per subject (dots kept), one consumer
// group per group, auto-commit OFF and a commit after each processed record,
// idempotent producer with acks=all (franz-go default).
type kafkaBackend struct{ broker string }

func (b *kafkaBackend) Name() string      { return "kafka" }
func (b *kafkaBackend) Container() string { return "spike-kafka" }

func (b *kafkaBackend) Setup(ctx context.Context, groups map[string][]string, partitions int) error {
	cl, err := kgo.NewClient(kgo.SeedBrokers(b.broker))
	if err != nil {
		return err
	}
	defer cl.Close()
	adm := kadm.NewClient(cl)
	var topics []string
	for s := range groups {
		topics = append(topics, s)
	}
	if _, err := adm.DeleteTopics(ctx, topics...); err != nil {
		return err
	}
	var gs []string
	for _, g := range groups {
		gs = append(gs, g...)
	}
	adm.DeleteGroups(ctx, gs...) //nolint:errcheck // absent on a fresh broker
	if partitions < 1 {
		partitions = 1
	}
	// A topic delete is async: retry the create until the old one is gone.
	deadline := time.Now().Add(30 * time.Second)
	for {
		res, err := adm.CreateTopics(ctx, int32(partitions), 1, nil, topics...)
		if err == nil {
			ok := true
			for _, r := range res {
				if r.Err != nil {
					ok = false
					if time.Now().After(deadline) {
						return r.Err
					}
				}
			}
			if ok {
				return nil
			}
		} else if time.Now().After(deadline) {
			return err
		}
		time.Sleep(500 * time.Millisecond)
	}
}

type kafkaProducer struct{ cl *kgo.Client }

func (b *kafkaBackend) Producer(context.Context) (Producer, error) {
	cl, err := kgo.NewClient(kgo.SeedBrokers(b.broker), kgo.RequiredAcks(kgo.AllISRAcks()),
		kgo.ProducerLinger(0), kgo.RecordDeliveryTimeout(5*time.Second))
	if err != nil {
		return nil, err
	}
	return &kafkaProducer{cl}, nil
}

func (p *kafkaProducer) Publish(ctx context.Context, subject, id string, data []byte) error {
	ctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	return p.cl.ProduceSync(ctx, &kgo.Record{Topic: subject, Key: []byte(id), Value: data}).FirstErr()
}

func (p *kafkaProducer) Close() { p.cl.Close() }

type kafkaConsumer struct {
	cl       *kgo.Client
	buf      []*kgo.Record
	assigned atomic.Bool
	marks    bool // SPIKE_KAFKA_COMMIT=marks: Kafka's usual batched commit
}

func (b *kafkaBackend) Consumer(_ context.Context, subject, group, name string) (Consumer, error) {
	c := &kafkaConsumer{marks: os.Getenv("SPIKE_KAFKA_COMMIT") == "marks"}
	opts := []kgo.Opt{kgo.SeedBrokers(b.broker), kgo.ConsumerGroup(group),
		kgo.OnPartitionsAssigned(func(context.Context, *kgo.Client, map[string][]int32) { c.assigned.Store(true) }),
		kgo.ConsumeTopics(subject),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()),
		kgo.SessionTimeout(6 * time.Second), kgo.HeartbeatInterval(1 * time.Second),
		kgo.ClientID(strings.ReplaceAll(name, ".", "-")),
		kgo.FetchMaxWait(100 * time.Millisecond)}
	if !c.marks {
		opts = append(opts, kgo.DisableAutoCommit())
	} else {
		// commit what was marked (processed) every 200 ms, and on a revoke
		opts = append(opts, kgo.AutoCommitMarks(), kgo.AutoCommitInterval(200*time.Millisecond))
	}
	cl, err := kgo.NewClient(opts...)
	if err != nil {
		return nil, err
	}
	c.cl = cl
	return c, nil
}

func (c *kafkaConsumer) Next(ctx context.Context, wait time.Duration) (*Msg, error) {
	if len(c.buf) == 0 {
		pctx, cancel := context.WithTimeout(ctx, wait)
		fs := c.cl.PollRecords(pctx, 10)
		cancel()
		fs.EachRecord(func(r *kgo.Record) { c.buf = append(c.buf, r) })
		if len(c.buf) == 0 {
			// An error-only fetch (the broker restarting) is not idle.
			for _, fe := range fs.Errors() {
				if !errors.Is(fe.Err, context.DeadlineExceeded) && !errors.Is(fe.Err, context.Canceled) {
					return nil, fe.Err
				}
			}
			return nil, errIdle
		}
	}
	r := c.buf[0]
	c.buf = c.buf[1:]
	if c.marks {
		return &Msg{Data: r.Value, Ack: func(context.Context) error { c.cl.MarkCommitRecords(r); return nil }}, nil
	}
	return &Msg{Data: r.Value, Ack: func(ctx context.Context) error { return c.cl.CommitRecords(ctx, r) }}, nil
}

func (c *kafkaConsumer) Ready() bool { return c.assigned.Load() }

func (c *kafkaConsumer) Close() { c.cl.Close() }
