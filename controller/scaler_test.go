package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

type fakeJITClient struct {
	mu    sync.Mutex
	calls int
}

func (f *fakeJITClient) GenerateJitRunnerConfig(_ context.Context, setting *scaleset.RunnerScaleSetJitRunnerSetting, _ int) (*scaleset.RunnerScaleSetJitRunnerConfig, error) {
	f.mu.Lock()
	f.calls++
	f.mu.Unlock()
	return &scaleset.RunnerScaleSetJitRunnerConfig{EncodedJITConfig: "jit-for-" + setting.Name}, nil
}

type fakeVMProvider struct {
	mu      sync.Mutex
	created []RunnerVM
	deleted []string
	cloud   []RunnerVM
}

func (f *fakeVMProvider) Create(_ context.Context, runnerName, _ string) (RunnerVM, error) {
	vm := RunnerVM{RunnerName: runnerName, VMName: azureResourceName(runnerName), CreatedAt: time.Now().UTC(), PowerState: "PowerState/running"}
	f.mu.Lock()
	f.created = append(f.created, vm)
	f.cloud = append(f.cloud, vm)
	f.mu.Unlock()
	return vm, nil
}

func (f *fakeVMProvider) Delete(_ context.Context, vmName string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deleted = append(f.deleted, vmName)
	return nil
}

func (f *fakeVMProvider) List(_ context.Context) ([]RunnerVM, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]RunnerVM(nil), f.cloud...), nil
}

func (f *fakeVMProvider) counts() (created, deleted int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.created), len(f.deleted)
}

func testScaler(maxRunners int) (*AzureScaler, *fakeVMProvider) {
	config := validConfig()
	config.MaxRunners = maxRunners
	config.ProvisionConcurrency = 20
	provider := &fakeVMProvider{}
	return &AzureScaler{
		config:     config,
		scaleSetID: 42,
		jitClient:  &fakeJITClient{},
		provider:   provider,
		state:      newRunnerState(),
		logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
	}, provider
}

func TestScalerExpandsToTwentyAndReturnsToZero(t *testing.T) {
	scaler, provider := testScaler(20)
	count, err := scaler.HandleDesiredRunnerCount(context.Background(), 20)
	if err != nil {
		t.Fatalf("scale up: %v", err)
	}
	if count != 20 {
		t.Fatalf("runner count after scale up = %d, want 20", count)
	}
	created, _ := provider.counts()
	if created != 20 {
		t.Fatalf("created %d VMs, want 20", created)
	}

	count, err = scaler.HandleDesiredRunnerCount(context.Background(), 0)
	if err != nil {
		t.Fatalf("scale down: %v", err)
	}
	if count != 0 {
		t.Fatalf("active runner count after scale down = %d, want 0", count)
	}
	waitFor(t, func() bool {
		_, deleted := provider.counts()
		return deleted == 20
	})
}

func TestScaleDownNeverDeletesBusyRunner(t *testing.T) {
	scaler, provider := testScaler(3)
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 3); err != nil {
		t.Fatalf("scale up: %v", err)
	}

	scaler.state.mu.Lock()
	var busyName string
	for name := range scaler.state.runners {
		busyName = name
		break
	}
	scaler.state.mu.Unlock()
	scaler.HandleJobStarted(context.Background(), &scaleset.JobStarted{RunnerName: busyName})

	count, err := scaler.HandleDesiredRunnerCount(context.Background(), 0)
	if err != nil {
		t.Fatalf("scale down: %v", err)
	}
	if count != 1 {
		t.Fatalf("active runner count = %d, want busy runner preserved", count)
	}
	waitFor(t, func() bool {
		_, deleted := provider.counts()
		return deleted == 2
	})

	if err := scaler.HandleJobCompleted(context.Background(), &scaleset.JobCompleted{RunnerName: busyName, Result: "Succeeded"}); err != nil {
		t.Fatalf("complete busy runner: %v", err)
	}
	waitFor(t, func() bool {
		_, deleted := provider.counts()
		return deleted == 3
	})
}

func TestReconcilerDeletesStoppedOrphan(t *testing.T) {
	scaler, provider := testScaler(2)
	provider.cloud = []RunnerVM{{
		RunnerName: "orphan-runner",
		VMName:     "orphan-runner",
		CreatedAt:  time.Now().Add(-time.Hour),
		PowerState: "PowerState/deallocated",
	}}
	scaler.reconcile(context.Background())
	waitFor(t, func() bool {
		_, deleted := provider.counts()
		return deleted == 1
	})
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal(fmt.Errorf("condition was not met before timeout"))
}
