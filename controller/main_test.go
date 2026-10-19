package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"
)

func TestListenerRetriesWhileScalerCleanupIsRunning(t *testing.T) {
	scaler, _ := testScaler(t, 1)
	cleanupBlocked := make(chan struct{})
	scaler.cleanup.Add(1)
	go func() { defer scaler.cleanup.Done(); <-cleanupBlocked }()
	defer close(cleanupBlocked)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	attempts := 0
	closed := false
	err := retryListener(ctx, slog.New(slog.NewTextHandler(io.Discard, nil)), time.Millisecond, func() error {
		attempts++
		if attempts == 2 {
			if !closed {
				t.Fatal("previous session was not closed before retry")
			}
			cancel()
			return ctx.Err()
		}
		defer func() { closed = true }()
		return errors.New("listener connection failed")
	})
	if !errors.Is(err, context.Canceled) || attempts != 2 {
		t.Fatalf("attempts=%d error=%v", attempts, err)
	}
}
