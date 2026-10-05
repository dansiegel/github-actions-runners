package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
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
	GetRunnerByName(ctx context.Context, runnerName string) (*scaleset.RunnerReference, error)
	RemoveRunner(ctx context.Context, runnerID int64) error
}

type runnerLifecycle string

const (
	runnerProvisioning runnerLifecycle = "provisioning"
	runnerIdle     runnerLifecycle = "idle"
	runnerBusy     runnerLifecycle = "busy"
	runnerUnknown  runnerLifecycle = "unknown"
	runnerDeleting runnerLifecycle = "deleting"
)

type runnerEntry struct {
	RunnerVM
	Lifecycle      runnerLifecycle
	Provisioning   bool
	DeleteInFlight bool
	DeleteReason   string
	JobCompleted   bool
	Missing        bool
}

type runnerState struct {
	mu      sync.Mutex
	runners map[string]runnerEntry
	desired int
	deleted map[string]time.Time
}

func newRunnerState() *runnerState {
	return &runnerState{runners: make(map[string]runnerEntry), deleted: make(map[string]time.Time)}
}

func (s *runnerState) activeCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	count := 0
	for _, runner := range s.runners {
		if runner.Lifecycle != runnerDeleting || runner.Missing {
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
	entry, ok := s.runners[vm.RunnerName]
	if !ok {
		entry.Lifecycle = runnerIdle
	} else if entry.Lifecycle == runnerProvisioning {
		entry.Lifecycle = runnerIdle
	}
	entry.RunnerVM = vm
	entry.Provisioning = false
	s.runners[vm.RunnerName] = entry
}

func (s *runnerState) setDesired(count int) {
	s.mu.Lock()
	s.desired = count
	s.mu.Unlock()
}

func (s *runnerState) reserve(name string, cap int) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.runners[name]; exists {
		return false
	}
	if _, deleted := s.deleted[name]; deleted {
		return false
	}
	active := 0
	for _, entry := range s.runners {
		if entry.Lifecycle != runnerDeleting || entry.Missing {
			active++
		}
	}
	if active >= s.desired || (cap > 0 && len(s.runners) >= cap) {
		return false
	}
	s.runners[name] = runnerEntry{
		RunnerVM: RunnerVM{RunnerName: name, VMName: azureResourceName(name), CreatedAt: time.Now().UTC()},
		Lifecycle: runnerProvisioning, Provisioning: true,
	}
	return true
}

func (s *runnerState) markBusy(runnerName string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, deleted := s.deleted[runnerName]; deleted {
		return
	}
	entry, ok := s.runners[runnerName]
	if ok && entry.Lifecycle == runnerDeleting {
		return
	}
	if !ok {
		entry = runnerEntry{RunnerVM: RunnerVM{RunnerName: runnerName, VMName: azureResourceName(runnerName)}, Lifecycle: runnerBusy}
	} else {
		entry.Lifecycle = runnerBusy
	}
	s.runners[runnerName] = entry
}

func (s *runnerState) markCompleted(name string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, deleted := s.deleted[name]; deleted {
		return false
	}
	entry, ok := s.runners[name]
	if entry.JobCompleted {
		return false
	}
	if !ok {
		entry.RunnerVM = RunnerVM{RunnerName: name, VMName: azureResourceName(name)}
		entry.Lifecycle = runnerUnknown
	}
	entry.JobCompleted = true
	s.runners[name] = entry
	// The SDK delivers completion before the message's updated statistics.
	// Avoid a replacement based on that short-lived stale desired count.
	s.desired = max(0, s.desired-1)
	return true
}

func (s *runnerState) markDeleting(runnerName, reason string) (runnerEntry, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, deleted := s.deleted[runnerName]; deleted {
		return runnerEntry{}, false
	}
	entry, ok := s.runners[runnerName]
	if !ok {
		entry = runnerEntry{RunnerVM: RunnerVM{RunnerName: runnerName, VMName: azureResourceName(runnerName)}, Lifecycle: runnerUnknown}
	}
	if entry.DeleteInFlight {
		return entry, false
	}
	entry.Lifecycle = runnerDeleting
	entry.DeleteReason = reason
	entry.DeleteInFlight = !entry.Provisioning
	s.runners[runnerName] = entry
	return entry, entry.DeleteInFlight
}

func (s *runnerState) deletionFailed(previous runnerEntry) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.runners[previous.RunnerName]
	if !ok {
		return
	}
	entry.DeleteInFlight = false
	s.runners[previous.RunnerName] = entry
}

func (s *runnerState) preserveBusy(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.runners[name]
	if ok {
		if entry.JobCompleted {
			entry.Lifecycle = runnerDeleting
			entry.DeleteInFlight = false
			entry.DeleteReason = "job completed"
			s.runners[name] = entry
			return
		}
		entry.Lifecycle = runnerBusy
		entry.DeleteInFlight = false
		entry.DeleteReason = ""
		s.runners[name] = entry
	}
}

func (s *runnerState) awaitMissingRegistration(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry := s.runners[name]
	entry.Lifecycle = runnerDeleting
	entry.Missing = true
	entry.DeleteInFlight = false
	entry.DeleteReason = "runner VM missing"
	s.runners[name] = entry
}

func (s *runnerState) remove(runnerName string) {
	s.mu.Lock()
	delete(s.runners, runnerName)
	s.deleted[runnerName] = time.Now()
	s.mu.Unlock()
}

func (s *runnerState) recordJIT(name string, id int) {
	s.mu.Lock()
	entry := s.runners[name]
	entry.RunnerID = id
	s.runners[name] = entry
	s.mu.Unlock()
}

func (s *runnerState) provisionFailed(name string) {
	s.mu.Lock()
	entry := s.runners[name]
	entry.Provisioning = false
	s.runners[name] = entry
	s.mu.Unlock()
}

func (s *runnerState) idleForDeletion(limit int) []runnerEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	active := 0
	for _, entry := range s.runners {
		if entry.Lifecycle != runnerDeleting || entry.Missing {
			active++
		}
	}
	limit = min(limit, max(0, active-s.desired))
	entries := make([]runnerEntry, 0)
	for _, runner := range s.runners {
		if runner.Lifecycle == runnerIdle && !runner.Provisioning {
			entries = append(entries, runner)
		}
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].CreatedAt.Before(entries[j].CreatedAt) })
	if len(entries) > limit {
		entries = entries[:limit]
	}
	for i := range entries {
		entries[i].Lifecycle = runnerDeleting
		entries[i].DeleteInFlight = true
		entries[i].DeleteReason = "queue demand decreased"
		s.runners[entries[i].RunnerName] = entries[i]
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
		if _, deleted := s.deleted[vm.RunnerName]; deleted {
			continue
		}
		entry, ok := s.runners[vm.RunnerName]
		if !ok {
			entry = runnerEntry{RunnerVM: vm, Lifecycle: runnerUnknown}
		} else {
			vm.RunnerID = entry.RunnerID
			entry.RunnerVM = vm
		}
		s.runners[vm.RunnerName] = entry
	}
	// A missing list entry is not proof of deletion: ARM lists can lag a
	// successful create, and creates/deletes may still be in flight. Only the
	// owning cleanup path removes tracked capacity after deletion succeeds.
	for name, entry := range s.runners {
		if !seen[name] {
			entry.PowerState = ""
		}
		result = append(result, entry)
	}
	// Tombstones prevent a list snapshot taken during deletion from adopting
	// the deleted VM again. UUID runner names are never reused.
	for name, deletedAt := range s.deleted {
		if !seen[name] && time.Since(deletedAt) > time.Hour {
			delete(s.deleted, name)
		}
	}
	return result
}

// provisionGate bounds concurrent Azure/JIT operations, not runner fleet size.
type provisionGate struct {
	slots chan struct{}
}

func newProvisionGate(concurrency int) *provisionGate {
	return &provisionGate{slots: make(chan struct{}, concurrency)}
}

type AzureScaler struct {
	config     Config
	scaleSetID int
	jitClient  jitProvider
	provider   vmProvider
	state      *runnerState
	logger     *slog.Logger
	ctx        context.Context
	wake       chan struct{}
	workers    sync.WaitGroup
	cleanup    sync.WaitGroup
	gate       *provisionGate

	provisionMu           sync.Mutex
	provisionBlockedUntil time.Time
}

func (s *AzureScaler) HandleDesiredRunnerCount(ctx context.Context, assignedJobs int) (int, error) {
	target := max(0, assignedJobs)
	if s.config.MaxRunners > 0 {
		target = min(s.config.MaxRunners, target)
	}
	s.state.setDesired(target)
	current := s.state.activeCount()
	s.logger.Info("Reconciling desired runner capacity", "assignedJobs", assignedJobs, "current", current, "target", target, "max", s.config.MaxRunners)

	if current > target {
		s.scaleDownIdle(current - target)
	}
	s.wakeProvisioning()
	return s.state.activeCount(), nil
}

func (s *AzureScaler) Start(ctx context.Context, gate *provisionGate) {
	s.ctx = ctx
	s.gate = gate
	s.wake = make(chan struct{}, cap(gate.slots))
	for range cap(gate.slots) {
		s.workers.Add(1)
		go func() {
			defer s.workers.Done()
			s.runProvisioner()
		}()
	}
	s.workers.Add(1)
	go func() {
		defer s.workers.Done()
		s.RunReconciler(ctx)
	}()
}

func (s *AzureScaler) Wait() {
	s.workers.Wait()
	s.cleanup.Wait()
}

func (s *AzureScaler) wakeProvisioning() {
	for range cap(s.wake) {
		select {
		case s.wake <- struct{}{}:
		default:
			return
		}
	}
}

func (s *AzureScaler) runProvisioner() {
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-s.wake:
		}
		for s.ctx.Err() == nil {
			select {
			case <-s.ctx.Done():
				return
			case s.gate.slots <- struct{}{}:
			}
			if s.ctx.Err() != nil || s.provisionBlocked() {
				<-s.gate.slots
				break
			}
			name := newRunnerName(s.config.ScaleSetName)
			if !s.state.reserve(name, s.config.MaxRunners) {
				<-s.gate.slots
				break
			}
			if _, err := s.startRunner(s.ctx, name); err != nil {
				s.blockProvisioning(err)
				s.state.provisionFailed(name)
				s.deleteRunner(name, "provisioning failed")
			}
			<-s.gate.slots
			// Successful parallel attempts must not clear a newer failure's
			// backoff. Reconciliation wakes us again after the pause expires.
			s.trimIdleExcess()
		}
	}
}

func newRunnerName(profile string) string {
	// Preserve the full random identity within Azure's name budget, even for
	// long profile labels. No later normalization needs to truncate it.
	return takeString(azureResourceName(profile), 21) + "-" + strings.ReplaceAll(uuid.NewString(), "-", "")
}

func (s *AzureScaler) trimIdleExcess() {
	s.state.mu.Lock()
	target := s.state.desired
	s.state.mu.Unlock()
	if excess := s.state.activeCount() - target; excess > 0 {
		s.scaleDownIdle(excess)
	}
}

func (s *AzureScaler) provisionBlocked() bool {
	s.provisionMu.Lock()
	defer s.provisionMu.Unlock()
	return time.Now().Before(s.provisionBlockedUntil)
}

func (s *AzureScaler) blockProvisioning(err error) {
	delay := provisionBackoffFor(err)
	s.provisionMu.Lock()
	until := time.Now().Add(delay)
	if until.After(s.provisionBlockedUntil) {
		s.provisionBlockedUntil = until
	}
	s.provisionMu.Unlock()
	s.logger.Error("Pausing runner provisioning after Azure create failed", "backoff", delay.String(), "error", err)
}

func provisionBackoffFor(err error) time.Duration {
	message := ""
	if err != nil {
		message = err.Error()
	}
	switch {
	case strings.Contains(message, "OperationNotAllowed") || strings.Contains(message, "Quota"):
		return 10 * time.Minute
	case strings.Contains(message, "AllocationFailed"):
		return 5 * time.Minute
	default:
		return 2 * time.Minute
	}
}

func (s *AzureScaler) HandleJobStarted(_ context.Context, job *scaleset.JobStarted) error {
	s.logger.Info("Job started", "runner", job.RunnerName, "repository", job.RepositoryName, "jobId", job.JobID)
	s.state.markBusy(job.RunnerName)
	return nil
}

func (s *AzureScaler) HandleJobCompleted(_ context.Context, job *scaleset.JobCompleted) error {
	s.logger.Info("Job completed", "runner", job.RunnerName, "repository", job.RepositoryName, "jobId", job.JobID, "result", job.Result)
	if s.state.markCompleted(job.RunnerName) {
		s.deleteRunner(job.RunnerName, "job completed")
	}
	return nil
}

func (s *AzureScaler) startRunner(ctx context.Context, runnerName string) (RunnerVM, error) {
	jit, err := s.jitClient.GenerateJitRunnerConfig(ctx, &scaleset.RunnerScaleSetJitRunnerSetting{
		Name:       runnerName,
		WorkFolder: "_work",
	}, s.scaleSetID)
	if err != nil {
		return RunnerVM{}, fmt.Errorf("generating JIT config for %s: %w", runnerName, err)
	}
	s.state.recordJIT(runnerName, jitRunnerID(jit))
	vm, err := s.provider.Create(ctx, runnerName, jit.EncodedJITConfig)
	if err != nil {
		// Keep the reservation until cleanup of the JIT registration and any
		// partially created VM, NIC, disk, or public IP succeeds.
		return RunnerVM{}, fmt.Errorf("provisioning %s: %w", runnerName, err)
	}
	vm.RunnerID = jitRunnerID(jit)
	s.state.addIdle(vm)
	s.state.mu.Lock()
	entry := s.state.runners[runnerName]
	s.state.mu.Unlock()
	if entry.Lifecycle == runnerDeleting {
		s.deleteRunner(runnerName, entry.DeleteReason)
	}
	s.logger.Info("Provisioned ephemeral runner", "runner", runnerName, "vm", vm.VMName)
	return vm, nil
}

func (s *AzureScaler) scaleDownIdle(count int) {
	for _, entry := range s.state.idleForDeletion(count) {
		s.startDelete(entry)
	}
}

func (s *AzureScaler) deleteRunner(runnerName, reason string) {
	entry, shouldDelete := s.state.markDeleting(runnerName, reason)
	if !shouldDelete {
		return
	}
	s.startDelete(entry)
}

func (s *AzureScaler) startDelete(entry runnerEntry) {
	runnerName := entry.RunnerName
	s.logger.Info("Deleting ephemeral runner", "runner", runnerName, "vm", entry.VMName, "reason", entry.DeleteReason)
	s.cleanup.Add(1)
	go func() {
		defer s.cleanup.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
		defer cancel()
		registrationErr := s.forgetGitHubRunner(ctx, entry)
		missing := entry.Missing || entry.DeleteReason == "runner VM missing"
		if err := registrationErr; err != nil && !missing {
			if errors.Is(err, scaleset.JobStillRunningError) && entry.DeleteReason != "hard runner lifetime exceeded" && entry.DeleteReason != "runner VM stopped" {
				s.state.preserveBusy(runnerName)
				s.logger.Warn("Preserving runner whose job is still running", "runner", runnerName)
				return
			}
			if entry.DeleteReason != "hard runner lifetime exceeded" && entry.DeleteReason != "runner VM stopped" {
				s.state.deletionFailed(entry)
				return
			}
		}
		if err := s.provider.Delete(ctx, entry.VMName); err != nil {
			s.logger.Error("Failed to delete ephemeral runner", "runner", runnerName, "vm", entry.VMName, "error", err)
			s.state.deletionFailed(entry)
			return
		}
		if missing && registrationErr != nil {
			// Azure resources are gone, but retain the lost assignment until
			// GitHub releases it. Otherwise stale running-job statistics would
			// create an idle replacement for a job that cannot be reassigned yet.
			s.state.awaitMissingRegistration(runnerName)
			return
		}
		s.state.remove(runnerName)
		s.logger.Info("Deleted ephemeral runner", "runner", runnerName, "vm", entry.VMName)
	}()
}

func jitRunnerID(jit *scaleset.RunnerScaleSetJitRunnerConfig) int {
	if jit == nil || jit.Runner == nil {
		return 0
	}
	return jit.Runner.ID
}

func (s *AzureScaler) forgetGitHubRunner(ctx context.Context, entry runnerEntry) error {
	runnerID := entry.RunnerID
	if runnerID == 0 && entry.RunnerName != "" {
		runner, err := s.jitClient.GetRunnerByName(ctx, entry.RunnerName)
		if err != nil {
			s.logger.Error("Failed to look up GitHub runner registration", "runner", entry.RunnerName, "error", err)
			return err
		}
		if runner == nil {
			return nil
		}
		runnerID = runner.ID
	}
	if runnerID == 0 {
		return nil
	}
	if err := s.jitClient.RemoveRunner(ctx, int64(runnerID)); err != nil {
		if !isGitHubRunnerMissing(err) {
			s.logger.Error("Failed to remove GitHub runner registration", "runner", entry.RunnerName, "runnerId", runnerID, "error", err)
			return err
		}
		return nil
	}
	s.logger.Info("Removed GitHub runner registration", "runner", entry.RunnerName, "runnerId", runnerID)
	return nil
}

func isGitHubRunnerMissing(err error) bool {
	if err == nil {
		return false
	}
	message := err.Error()
	return strings.Contains(message, "404") || strings.Contains(strings.ToLower(message), "not found")
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
			s.deleteRunner(entry.RunnerName, entry.DeleteReason)
			continue
		}
		if entry.Provisioning {
			continue
		}
		reason := ""
		if entry.PowerState == "" {
			// A list can lag creation. Check a tracked-but-missing VM directly
			// before freeing capacity or removing its GitHub registration.
			if reader, ok := s.provider.(interface {
				PowerState(context.Context, string) (string, error)
			}); ok {
				power, err := reader.PowerState(ctx, entry.VMName)
				if errors.Is(err, errResourceNotFound) {
					reason = "runner VM missing"
				} else if err == nil {
					entry.PowerState = power
				}
			}
		}
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
	s.trimIdleExcess()
	s.wakeProvisioning()
}

var _ listener.Scaler = (*AzureScaler)(nil)
