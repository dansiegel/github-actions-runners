package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"strings"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

type fakeJITClient struct {
	mu      sync.Mutex
	calls   int
	removed []int64
	byName  map[string]int
	removeErr error
	scaleSetIDs []int
}

func (f *fakeJITClient) GenerateJitRunnerConfig(_ context.Context, setting *scaleset.RunnerScaleSetJitRunnerSetting, scaleSetID int) (*scaleset.RunnerScaleSetJitRunnerConfig, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.scaleSetIDs = append(f.scaleSetIDs, scaleSetID)
	if f.byName == nil {
		f.byName = map[string]int{}
	}
	id := 1000 + f.calls
	f.byName[setting.Name] = id
	return &scaleset.RunnerScaleSetJitRunnerConfig{
		EncodedJITConfig: "jit-for-" + setting.Name,
		Runner:           &scaleset.RunnerReference{ID: id, Name: setting.Name},
	}, nil
}

func (f *fakeJITClient) GetRunnerByName(_ context.Context, runnerName string) (*scaleset.RunnerReference, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if id, ok := f.byName[runnerName]; ok {
		return &scaleset.RunnerReference{ID: id, Name: runnerName}, nil
	}
	if runnerName == "orphan-runner" {
		return &scaleset.RunnerReference{ID: 77, Name: runnerName}, nil
	}
	return nil, nil
}

func (f *fakeJITClient) RemoveRunner(_ context.Context, runnerID int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.removed = append(f.removed, runnerID)
	return f.removeErr
}

func (f *fakeJITClient) snapshot() (calls int, removed []int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls, append([]int64(nil), f.removed...)
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
	for i, vm := range f.cloud {
		if vm.VMName == vmName { f.cloud = append(f.cloud[:i], f.cloud[i+1:]...); break }
	}
	return nil
}

func (f *fakeVMProvider) List(_ context.Context) ([]RunnerVM, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]RunnerVM(nil), f.cloud...), nil
}

func (f *fakeVMProvider) PowerState(_ context.Context, name string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, vm := range f.cloud { if vm.VMName == name { return vm.PowerState, nil } }
	return "", errResourceNotFound
}

func (f *fakeVMProvider) counts() (created, deleted int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.created), len(f.deleted)
}

func testScaler(t *testing.T, maxRunners int) (*AzureScaler, *fakeVMProvider) {
	config := validConfig()
	config.MaxRunners = maxRunners
	config.ProvisionConcurrency = 20
	provider := &fakeVMProvider{}
	scaler := &AzureScaler{
		config:     config,
		scaleSetID: 42,
		jitClient:  &fakeJITClient{},
		provider:   provider,
		state:      newRunnerState(),
		logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	ctx, cancel := context.WithCancel(context.Background())
	scaler.Start(ctx, newProvisionGate(config.ProvisionConcurrency))
	t.Cleanup(func() { cancel(); scaler.Wait() })
	return scaler, provider
}

func TestScalerExpandsToTwentyAndReturnsToZero(t *testing.T) {
	scaler, provider := testScaler(t, 20)
	count, err := scaler.HandleDesiredRunnerCount(context.Background(), 20)
	if err != nil {
		t.Fatalf("scale up: %v", err)
	}
	waitForIdle(t, scaler, 20)
	count = scaler.state.activeCount()
	if count != 20 { t.Fatalf("runner count after scale up = %d", count) }
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
	scaler, provider := testScaler(t, 3)
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 3); err != nil {
		t.Fatalf("scale up: %v", err)
	}

	waitForIdle(t, scaler, 3)
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
	scaler, provider := testScaler(t, 2)
	provider.cloud = []RunnerVM{{
		RunnerName: "orphan-runner",
		VMName:     "orphan-runner",
		CreatedAt:  time.Now().Add(-time.Hour),
		PowerState: "PowerState/deallocated",
	}}
	scaler.reconcile(context.Background())
	jit := scaler.jitClient.(*fakeJITClient)
	waitFor(t, func() bool {
		_, deleted := provider.counts()
		_, removed := jit.snapshot()
		return deleted == 1 && len(removed) == 1 && removed[0] == 77
	})
}

type failingVMProvider struct {
	fakeVMProvider
	err error
}

func (f *failingVMProvider) Create(context.Context, string, string) (RunnerVM, error) {
	return RunnerVM{}, f.err
}

func TestFailedProvisionRemovesRegistrationAndPauses(t *testing.T) {
	provider := &failingVMProvider{err: fmt.Errorf("creating VM: Azure operation Failed: {\"code\":\"OperationNotAllowed\",\"message\":\"exceeding approved standardDSv5Family Cores quota\"}")}
	config := validConfig(); config.MaxRunners = 1
	scaler := startTestScaler(t, config, provider, &fakeJITClient{}, newProvisionGate(1))
	jit := scaler.jitClient.(*fakeJITClient)

	_, err := scaler.HandleDesiredRunnerCount(context.Background(), 1)
	if err != nil {
		t.Fatalf("provision failure must not stop the listener: %v", err)
	}
	waitFor(t, func() bool { calls, removed := jit.snapshot(); return calls == 1 && len(removed) == 1 && scaler.state.resourceCount() == 0 })
	calls, removed := jit.snapshot()
	if calls != 1 {
		t.Fatalf("JIT registrations = %d, want 1", calls)
	}
	if len(removed) != 1 {
		t.Fatalf("removed registrations = %d, want the failed runner removed", len(removed))
	}

	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 1); err != nil {
		t.Fatalf("paused provision: %v", err)
	}
	calls, _ = jit.snapshot()
	if calls != 1 {
		t.Fatalf("JIT registrations during backoff = %d, want 1", calls)
	}
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

func waitForIdle(t *testing.T, scaler *AzureScaler, count int) {
	t.Helper()
	waitFor(t, func() bool {
		scaler.state.mu.Lock()
		defer scaler.state.mu.Unlock()
		if len(scaler.state.runners) != count { return false }
		for _, entry := range scaler.state.runners { if entry.Lifecycle != runnerIdle { return false } }
		return true
	})
}

func startTestScaler(t *testing.T, config Config, provider vmProvider, jit jitProvider, gate *provisionGate) *AzureScaler {
	t.Helper()
	scaler := &AzureScaler{config: config, scaleSetID: 42, provider: provider, jitClient: jit, state: newRunnerState(), logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	ctx, cancel := context.WithCancel(context.Background())
	scaler.Start(ctx, gate)
	t.Cleanup(func() { cancel(); scaler.Wait() })
	return scaler
}

func TestUncappedScalerFollowsDemandBeyondTwenty(t *testing.T) {
	scaler, provider := testScaler(t, 0)
	if _, err := scaler.HandleDesiredRunnerCount(context.Background(), 32); err != nil { t.Fatal(err) }
	waitForIdle(t, scaler, 32)
	created, _ := provider.counts()
	if created != 32 { t.Fatalf("created %d runners for demand 32", created) }
	for range 10 { scaler.HandleDesiredRunnerCount(context.Background(), 32) }
	if created, _ := provider.counts(); created != 32 { t.Fatal("unchanged demand duplicated runners") }
	scaler.HandleDesiredRunnerCount(context.Background(), 0)
	waitFor(t, func() bool { return scaler.state.resourceCount() == 0 })
}

type blockedVMProvider struct {
	fakeVMProvider
	started chan string
	release chan struct{}
}

func (p *blockedVMProvider) Create(ctx context.Context, name, jit string) (RunnerVM, error) {
	select { case p.started <- name: case <-ctx.Done(): return RunnerVM{}, ctx.Err() }
	select { case <-p.release: case <-ctx.Done(): return RunnerVM{}, ctx.Err() }
	return p.fakeVMProvider.Create(ctx, name, jit)
}

func TestLargeDemandReturnsPromptlyAndDoesNotDuplicatePendingCreates(t *testing.T) {
	config := validConfig(); config.MaxRunners = 0
	provider := &blockedVMProvider{started: make(chan string, 2), release: make(chan struct{})}
	scaler := startTestScaler(t, config, provider, &fakeJITClient{}, newProvisionGate(2))
	returned := make(chan struct{})
	go func() { scaler.HandleDesiredRunnerCount(context.Background(), 100000); close(returned) }()
	select { case <-returned: case <-time.After(time.Second): t.Fatal("desired callback waited for VM creation") }
	for range 2 { select { case <-provider.started: case <-time.After(time.Second): t.Fatal("workers did not start") } }
	for range 20 { scaler.HandleDesiredRunnerCount(context.Background(), 100000) }
	scaler.reconcile(context.Background()) // Empty ARM inventory must retain pending reservations.
	if scaler.state.resourceCount() != 2 { t.Fatal("pending reservations were lost or duplicated") }
	scaler.HandleDesiredRunnerCount(context.Background(), 0)
	close(provider.release)
	waitFor(t, func() bool { return scaler.state.resourceCount() == 0 })
	if created, _ := provider.counts(); created != 2 { t.Fatalf("created %d after demand dropped", created) }
}

func TestInFlightCreatePreservesBusyAndCompletedEvents(t *testing.T) {
	for _, completed := range []bool{false, true} {
		t.Run(fmt.Sprintf("completed-%t", completed), func(t *testing.T) {
			config := validConfig(); config.MaxRunners = 0
			provider := &blockedVMProvider{started: make(chan string, 1), release: make(chan struct{})}
			scaler := startTestScaler(t, config, provider, &fakeJITClient{}, newProvisionGate(1))
			scaler.HandleDesiredRunnerCount(context.Background(), 1)
			var name string
			select { case name = <-provider.started: case <-time.After(time.Second): t.Fatal("create did not start") }
			scaler.HandleJobStarted(context.Background(), &scaleset.JobStarted{RunnerName: name})
			scaler.reconcile(context.Background())
			if completed {
				scaler.HandleJobCompleted(context.Background(), &scaleset.JobCompleted{RunnerName: name})
				scaler.HandleDesiredRunnerCount(context.Background(), 0)
				if _, deleted := provider.counts(); deleted != 0 { t.Fatal("deleted before Create settled") }
			}
			close(provider.release)
			if !completed {
				waitFor(t, func() bool { scaler.state.mu.Lock(); defer scaler.state.mu.Unlock(); return !scaler.state.runners[name].Provisioning })
				scaler.state.mu.Lock(); lifecycle := scaler.state.runners[name].Lifecycle; scaler.state.mu.Unlock()
				if lifecycle != runnerBusy { t.Fatalf("Create reset busy state: %s", lifecycle) }
				scaler.HandleJobCompleted(context.Background(), &scaleset.JobCompleted{RunnerName: name})
				scaler.HandleDesiredRunnerCount(context.Background(), 0)
			}
			waitFor(t, func() bool { return scaler.state.resourceCount() == 0 })
			scaler.HandleJobStarted(context.Background(), &scaleset.JobStarted{RunnerName: name})
			scaler.HandleJobCompleted(context.Background(), &scaleset.JobCompleted{RunnerName: name})
			scaler.reconcile(context.Background())
			if scaler.state.resourceCount() != 0 { t.Fatal("late event resurrected runner") }
			if _, deleted := provider.counts(); deleted != 1 { t.Fatalf("delete count = %d", deleted) }
		})
	}
}

type provisionObservation struct { mu sync.Mutex; active, peak int }
type observedVMProvider struct { fakeVMProvider; observation *provisionObservation }
func (p *observedVMProvider) Create(ctx context.Context, name, jit string) (RunnerVM, error) {
	p.observation.mu.Lock(); p.observation.active++; p.observation.peak = max(p.observation.peak, p.observation.active); p.observation.mu.Unlock()
	defer func() { p.observation.mu.Lock(); p.observation.active--; p.observation.mu.Unlock() }()
	if err := sleepContext(ctx, 10*time.Millisecond); err != nil { return RunnerVM{}, err }
	return p.fakeVMProvider.Create(ctx, name, jit)
}

func TestEightProfilesShareProvisioningGateAndKeepJITIsolation(t *testing.T) {
	gate := newProvisionGate(2)
	observation := &provisionObservation{}
	var scalers []*AzureScaler
	var clients []*fakeJITClient
	for i := range 8 {
		config := validConfig(); config.MaxRunners = 0; config.ScaleSetName = fmt.Sprintf("profile-%d", i)
		client := &fakeJITClient{}
		scaler := startTestScaler(t, config, &observedVMProvider{observation: observation}, client, gate)
		scaler.scaleSetID = i+1
		scalers = append(scalers, scaler); clients = append(clients, client)
	}
	for _, scaler := range scalers { scaler.HandleDesiredRunnerCount(context.Background(), 2) }
	for i, scaler := range scalers {
		waitForIdle(t, scaler, 2)
		clients[i].mu.Lock(); ids := append([]int(nil), clients[i].scaleSetIDs...); clients[i].mu.Unlock()
		for _, id := range ids { if id != i+1 { t.Fatal("JIT config crossed profiles") } }
		scaler.state.mu.Lock()
		for name := range scaler.state.runners { if !strings.HasPrefix(name, scaler.config.ScaleSetName+"-") { t.Errorf("runner crossed profiles: %s", name) } }
		scaler.state.mu.Unlock()
	}
	observation.mu.Lock(); peak := observation.peak; observation.mu.Unlock()
	if peak > 2 || peak == 0 { t.Fatalf("global in-flight creates = %d, want 1..2", peak) }
}

type retryDeleteProvider struct { fakeVMProvider; attempts int; attemptMu sync.Mutex }
func (p *retryDeleteProvider) Delete(ctx context.Context, name string) error {
	p.attemptMu.Lock(); p.attempts++; attempt := p.attempts; p.attemptMu.Unlock()
	if attempt == 1 { return fmt.Errorf("temporary deletion failure") }
	return p.fakeVMProvider.Delete(ctx, name)
}

func TestFailedDeletionRemainsPendingAndRetries(t *testing.T) {
	config := validConfig(); config.MaxRunners = 1
	provider := &retryDeleteProvider{}
	scaler := startTestScaler(t, config, provider, &fakeJITClient{}, newProvisionGate(1))
	scaler.HandleDesiredRunnerCount(context.Background(), 1); waitForIdle(t, scaler, 1)
	scaler.HandleDesiredRunnerCount(context.Background(), 0)
	waitFor(t, func() bool { scaler.state.mu.Lock(); defer scaler.state.mu.Unlock(); for _, e := range scaler.state.runners { return e.Lifecycle == runnerDeleting && !e.DeleteInFlight }; return false })
	if scaler.state.resourceCount() != 1 { t.Fatal("failed deletion freed capacity") }
	scaler.reconcile(context.Background())
	waitFor(t, func() bool { return scaler.state.resourceCount() == 0 })
}

func TestGitHubBusyGuardPreventsAzureDeletion(t *testing.T) {
	config := validConfig()
	provider := &fakeVMProvider{}
	client := &fakeJITClient{removeErr: scaleset.JobStillRunningError}
	scaler := startTestScaler(t, config, provider, client, newProvisionGate(1))
	scaler.HandleDesiredRunnerCount(context.Background(), 1); waitForIdle(t, scaler, 1)
	scaler.HandleDesiredRunnerCount(context.Background(), 0)
	waitFor(t, func() bool { scaler.state.mu.Lock(); defer scaler.state.mu.Unlock(); for _, e := range scaler.state.runners { return e.Lifecycle == runnerBusy }; return false })
	if _, deleted := provider.counts(); deleted != 0 { t.Fatal("busy runner deleted") }
}

func TestCompletionWinsOverStaleBusyGuard(t *testing.T) {
	state := newRunnerState(); state.setDesired(1); state.addIdle(RunnerVM{RunnerName:"runner", VMName:"runner"})
	state.markDeleting("runner", "queue demand decreased")
	state.markCompleted("runner")
	state.preserveBusy("runner")
	state.mu.Lock(); entry := state.runners["runner"]; state.mu.Unlock()
	if entry.Lifecycle != runnerDeleting || entry.DeleteInFlight || entry.DeleteReason != "job completed" { t.Fatalf("completion lost: %+v", entry) }
}

func TestRestartAdoptsCapacityWithoutDuplicateProvisioning(t *testing.T) {
	config := validConfig(); config.MaxRunners = 0
	provider := &fakeVMProvider{cloud: []RunnerVM{{RunnerName:"old-1",VMName:"old-1",CreatedAt:time.Now(),PowerState:"PowerState/running"},{RunnerName:"old-2",VMName:"old-2",CreatedAt:time.Now(),PowerState:"PowerState/running"}}}
	client := &fakeJITClient{}
	scaler := startTestScaler(t, config, provider, client, newProvisionGate(2))
	if err := scaler.AdoptExisting(context.Background()); err != nil { t.Fatal(err) }
	scaler.HandleDesiredRunnerCount(context.Background(), 2)
	if calls, _ := client.snapshot(); calls != 0 { t.Fatal("adopted capacity duplicated") }
	scaler.HandleDesiredRunnerCount(context.Background(), 0)
	if scaler.state.activeCount() != 2 { t.Fatal("restart-unknown runners were removed by scale-down") }
}

func TestReservationNamesPreserveFullIdentityAndRejectCollisions(t *testing.T) {
	name := newRunnerName(strings.Repeat("profile",10))
	if len(name) > 54 || len(strings.Split(name,"-")[1]) != 32 || azureResourceName(name) != name { t.Fatalf("bad runner identity: %s", name) }
	state := newRunnerState(); state.setDesired(2)
	if !state.reserve(name,0) || state.reserve(name,0) { t.Fatal("reservation collision was accepted") }
	state.remove(name)
	if state.reserve(name,0) { t.Fatal("deleted identity was reused") }
}

func TestConfirmedMissingRunnerRetainsCleanupUntilItSucceeds(t *testing.T) {
	scaler, provider := testScaler(t,1)
	scaler.HandleDesiredRunnerCount(context.Background(),1); waitForIdle(t,scaler,1)
	scaler.state.mu.Lock(); var name string; for n := range scaler.state.runners {name=n}; scaler.state.mu.Unlock()
	scaler.HandleJobStarted(context.Background(),&scaleset.JobStarted{RunnerName:name})
	provider.mu.Lock(); provider.cloud=nil; provider.mu.Unlock()
	scaler.reconcile(context.Background())
	waitFor(t,func()bool{_,deleted:=provider.counts();return deleted>=1})
	scaler.HandleDesiredRunnerCount(context.Background(),0)
	waitFor(t,func()bool{return scaler.state.resourceCount()==0})
}
