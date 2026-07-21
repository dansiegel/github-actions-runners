package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"sync"
	"time"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
	"github.com/google/uuid"
)

type vmProvider interface {
	Create(ctx context.Context, runnerName, encodedJITConfig string) (RunnerVM, error)
	Delete(ctx context.Context, vmName string) error
	List(ctx context.Context) ([]RunnerVM, error)
}

type jitProvider interface {
	GenerateJitRunnerConfig(ctx context.Context, runnerSetting *scaleset.RunnerScaleSetJitRunnerSetting, runnerScaleSetID int) (*scaleset.RunnerScaleSetJitRunnerConfig, error)
}

type runnerLifecycle string

const (
	runnerIdle     runnerLifecycle = "idle"
	runnerBusy     runnerLifecycle = "busy"
	runnerUnknown  runnerLifecycle = "unknown"
	runnerDeleting runnerLifecycle = "deleting"
)

type runnerEntry struct {
	RunnerVM
	Lifecycle runnerLifecycle
}

type runnerState struct {
	mu      sync.Mutex
	runners map[string]runnerEntry
}

func newRunnerState() *runnerState {
	return &runnerState{runners: make(map[string]runnerEntry)}
}

func (s *runnerState) activeCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	count := 0
	for _, runner := range s.runners {
		if runner.Lifecycle != runnerDeleting {
			count++
		}
	}
	return count
}

func (s *runnerState) resourceCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.runners)
}

func (s *runnerState) addIdle(vm RunnerVM) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.runners[vm.RunnerName] = runnerEntry{RunnerVM: vm, Lifecycle: runnerIdle}
}

func (s *runnerState) markBusy(runnerName string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.runners[runnerName]
	if !ok {
		entry = runnerEntry{RunnerVM: RunnerVM{RunnerName: runnerName, VMName: azureResourceName(runnerName)}, Lifecycle: runnerBusy}
	} else {
		entry.Lifecycle = runnerBusy
	}
	s.runners[runnerName] = entry
}

func (s *runnerState) markDeleting(runnerName string) (runnerEntry, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.runners[runnerName]
	if !ok {
		previous := runnerEntry{RunnerVM: RunnerVM{RunnerName: runnerName, VMName: azureResourceName(runnerName)}, Lifecycle: runnerUnknown}
		deleting := previous
		deleting.Lifecycle = runnerDeleting
		s.runners[runnerName] = deleting
		return previous, true
	}
	if entry.Lifecycle == runnerDeleting {
		return entry, false
	}
	previous := entry
	entry.Lifecycle = runnerDeleting
	s.runners[runnerName] = entry
	return previous, true
}

func (s *runnerState) deletionFailed(previous runnerEntry) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.runners[previous.RunnerName]
	if !ok {
		return
	}
	if entry.Lifecycle == runnerDeleting {
		s.runners[previous.RunnerName] = previous
	}
}

func (s *runnerState) remove(runnerName string) {
	s.mu.Lock()
	delete(s.runners, runnerName)
	s.mu.Unlock()
}

func (s *runnerState) idleForDeletion(limit int) []runnerEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	entries := make([]runnerEntry, 0)
	for _, runner := range s.runners {
		if runner.Lifecycle == runnerIdle {
			entries = append(entries, runner)
		}
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].CreatedAt.Before(entries[j].CreatedAt) })
	if len(entries) > limit {
		entries = entries[:limit]
	}
	return entries
}

func (s *runnerState) reconcileCloud(cloud []RunnerVM) []runnerEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	seen := make(map[string]bool, len(cloud))
	result := make([]runnerEntry, 0, len(cloud))
	for _, vm := range cloud {
		seen[vm.RunnerName] = true
		entry, ok := s.runners[vm.RunnerName]
		if !ok {
			entry = runnerEntry{RunnerVM: vm, Lifecycle: runnerUnknown}
		} else {
			entry.RunnerVM = vm
		}
		s.runners[vm.RunnerName] = entry
		result = append(result, entry)
	}
	for name := range s.runners {
		if !seen[name] {
			delete(s.runners, name)
		}
	}
	return result
}

type AzureScaler struct {
	config     Config
	scaleSetID int
	jitClient  jitProvider
	provider   vmProvider
	state      *runnerState
	logger     *slog.Logger
}

func (s *AzureScaler) HandleDesiredRunnerCount(ctx context.Context, assignedJobs int) (int, error) {
	target := min(s.config.MaxRunners, s.config.MinRunners+assignedJobs)
	current := s.state.activeCount()
	s.logger.Info("Reconciling desired runner capacity", "assignedJobs", assignedJobs, "current", current, "target", target, "max", s.config.MaxRunners)

	if current < target {
		// VMs already being deleted still consume Azure capacity and cost. Do
		// not replace them until deletion completes, which keeps the hard
		// resource ceiling at MaxRunners even during rapid queue churn.
		availableSlots := max(0, s.config.MaxRunners-s.state.resourceCount())
		scaleUp := min(target-current, availableSlots)
		if err := s.scaleUp(ctx, scaleUp); err != nil {
			return s.state.activeCount(), err
		}
	} else if current > target {
		s.scaleDownIdle(current - target)
	}
	return s.state.activeCount(), nil
}

func (s *AzureScaler) HandleJobStarted(_ context.Context, job *scaleset.JobStarted) error {
	s.logger.Info("Job started", "runner", job.RunnerName, "repository", job.RepositoryName, "jobId", job.JobID)
	s.state.markBusy(job.RunnerName)
	return nil
}

func (s *AzureScaler) HandleJobCompleted(_ context.Context, job *scaleset.JobCompleted) error {
	s.logger.Info("Job completed", "runner", job.RunnerName, "repository", job.RepositoryName, "jobId", job.JobID, "result", job.Result)
	s.deleteRunner(job.RunnerName, "job completed")
	return nil
}

func (s *AzureScaler) scaleUp(ctx context.Context, count int) error {
	s.logger.Info("Scaling up ephemeral Azure runners", "count", count)
	semaphore := make(chan struct{}, s.config.ProvisionConcurrency)
	var wg sync.WaitGroup
	var errorMu sync.Mutex
	var result error

	for range count {
		wg.Add(1)
		go func() {
			defer wg.Done()
			select {
			case semaphore <- struct{}{}:
				defer func() { <-semaphore }()
			case <-ctx.Done():
				errorMu.Lock()
				result = errors.Join(result, ctx.Err())
				errorMu.Unlock()
				return
			}
			if _, err := s.startRunner(ctx); err != nil {
				errorMu.Lock()
				result = errors.Join(result, err)
				errorMu.Unlock()
			}
		}()
	}
	wg.Wait()
	return result
}

func (s *AzureScaler) startRunner(ctx context.Context) (RunnerVM, error) {
	runnerName := takeString(fmt.Sprintf("%s-%s", azureResourceName(s.config.ScaleSetName), uuid.NewString()[:12]), 63)
	jit, err := s.jitClient.GenerateJitRunnerConfig(ctx, &scaleset.RunnerScaleSetJitRunnerSetting{
		Name:       runnerName,
		WorkFolder: "_work",
	}, s.scaleSetID)
	if err != nil {
		return RunnerVM{}, fmt.Errorf("generating JIT config for %s: %w", runnerName, err)
	}
	vm, err := s.provider.Create(ctx, runnerName, jit.EncodedJITConfig)
	if err != nil {
		return RunnerVM{}, fmt.Errorf("provisioning %s: %w", runnerName, err)
	}
	s.state.addIdle(vm)
	s.logger.Info("Provisioned ephemeral runner", "runner", runnerName, "vm", vm.VMName)
	return vm, nil
}

func (s *AzureScaler) scaleDownIdle(count int) {
	for _, entry := range s.state.idleForDeletion(count) {
		s.deleteRunner(entry.RunnerName, "queue demand decreased")
	}
}

func (s *AzureScaler) deleteRunner(runnerName, reason string) {
	entry, shouldDelete := s.state.markDeleting(runnerName)
	if !shouldDelete {
		return
	}
	s.logger.Info("Deleting ephemeral runner", "runner", runnerName, "vm", entry.VMName, "reason", reason)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
		defer cancel()
		if err := s.provider.Delete(ctx, entry.VMName); err != nil {
			s.logger.Error("Failed to delete ephemeral runner", "runner", runnerName, "vm", entry.VMName, "error", err)
			s.state.deletionFailed(entry)
			return
		}
		s.state.remove(runnerName)
		s.logger.Info("Deleted ephemeral runner", "runner", runnerName, "vm", entry.VMName)
	}()
}

func (s *AzureScaler) AdoptExisting(ctx context.Context) error {
	cloud, err := s.provider.List(ctx)
	if err != nil {
		return err
	}
	entries := s.state.reconcileCloud(cloud)
	s.logger.Info("Adopted existing Azure runner VMs", "count", len(entries))
	return nil
}

func (s *AzureScaler) RunReconciler(ctx context.Context) {
	ticker := time.NewTicker(s.config.ReconcileInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.reconcile(ctx)
		}
	}
}

func (s *AzureScaler) reconcile(ctx context.Context) {
	cloud, err := s.provider.List(ctx)
	if err != nil {
		s.logger.Error("Runner VM reconciliation failed", "error", err)
		return
	}
	entries := s.state.reconcileCloud(cloud)
	now := time.Now().UTC()
	for _, entry := range entries {
		if entry.Lifecycle == runnerDeleting {
			continue
		}
		reason := ""
		switch entry.PowerState {
		case "PowerState/stopped", "PowerState/deallocated":
			reason = "runner VM stopped"
		}
		if reason == "" && !entry.CreatedAt.IsZero() && now.Sub(entry.CreatedAt) > s.config.MaxRunnerAge {
			reason = "hard runner lifetime exceeded"
		}
		if reason == "" && entry.Lifecycle == runnerIdle && !entry.CreatedAt.IsZero() && now.Sub(entry.CreatedAt) > s.config.IdleTimeout {
			reason = "idle runner timeout exceeded"
		}
		if reason != "" {
			s.deleteRunner(entry.RunnerName, reason)
		}
	}
}

var _ listener.Scaler = (*AzureScaler)(nil)
