package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
	"github.com/google/uuid"
)

var (
	version   = "dev"
	commitSHA = "unknown"
)

func main() {
	config, err := LoadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "configuration error: %v\n", err)
		os.Exit(2)
	}
	logger := newLogger(config.LogLevel)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	if err := run(ctx, config, logger); err != nil && !errors.Is(err, context.Canceled) {
		logger.Error("Runner scale controller stopped", "error", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, config Config, logger *slog.Logger) error {
	pools, err := config.PoolConfigs()
	if err != nil {
		return err
	}
	gate := newProvisionGate(config.ProvisionConcurrency)
	var workers sync.WaitGroup
	for _, pool := range pools {
		workers.Add(1)
		go func(pool Config) {
			defer workers.Done()
			poolLogger := logger.With("pool", pool.ScaleSetName)
			for ctx.Err() == nil {
				if err := runPool(ctx, pool, poolLogger, gate); err != nil && !errors.Is(err, context.Canceled) {
					poolLogger.Error("Profile listener stopped; retrying in one minute", "error", err)
				}
				if err := sleepContext(ctx, time.Minute); err != nil {
					return
				}
			}
		}(pool)
	}
	logger.Info("Shared runner controller started", "profiles", len(pools), "provisionConcurrency", config.ProvisionConcurrency)
	workers.Wait()
	return ctx.Err()
}

func runPool(parent context.Context, config Config, logger *slog.Logger, gate *provisionGate) error {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	client, err := scaleset.NewClientWithGitHubApp(scaleset.ClientWithGitHubAppConfig{
		GitHubConfigURL: config.RegistrationURL,
		GitHubAppAuth:   config.GitHubApp,
		SystemInfo:      systemInfo(0),
	})
	if err != nil {
		return fmt.Errorf("creating GitHub runner scale set client: %w", err)
	}

	runnerGroupID := 1
	if config.RunnerGroup != scaleset.DefaultRunnerGroup {
		group, err := client.GetRunnerGroupByName(ctx, config.RunnerGroup)
		if err != nil {
			return fmt.Errorf("resolving runner group %q: %w", config.RunnerGroup, err)
		}
		runnerGroupID = group.ID
	}

	scaleSet, err := client.GetRunnerScaleSet(ctx, runnerGroupID, config.ScaleSetName)
	if err != nil {
		return fmt.Errorf("looking up runner scale set: %w", err)
	}
	desired := &scaleset.RunnerScaleSet{
		Name:          config.ScaleSetName,
		RunnerGroupID: runnerGroupID,
		Labels:        config.ScaleSetLabels(),
		RunnerSetting: scaleset.RunnerSetting{DisableUpdate: true},
	}
	if scaleSet == nil {
		scaleSet, err = client.CreateRunnerScaleSet(ctx, desired)
		if err != nil {
			return fmt.Errorf("creating runner scale set: %w", err)
		}
		logger.Info("Created GitHub runner scale set", "name", scaleSet.Name, "id", scaleSet.ID)
	} else {
		desired.ID = scaleSet.ID
		scaleSet, err = client.UpdateRunnerScaleSet(ctx, scaleSet.ID, desired)
		if err != nil {
			return fmt.Errorf("updating runner scale set: %w", err)
		}
		logger.Info("Using existing GitHub runner scale set", "name", scaleSet.Name, "id", scaleSet.ID)
	}
	client.SetSystemInfo(systemInfo(scaleSet.ID))

	provider, err := NewAzureVMManager(config, logger.WithGroup("azure"))
	if err != nil {
		return err
	}
	scaler := &AzureScaler{
		config:     config,
		scaleSetID: scaleSet.ID,
		jitClient:  client,
		provider:   provider,
		state:      newRunnerState(),
		logger:     logger.WithGroup("scaler"),
	}
	hostname, err := os.Hostname()
	if err != nil || hostname == "" {
		hostname = "controller"
	}
	owner := takeString(fmt.Sprintf("%s-%s-%s", hostname, azureResourceName(config.ScaleSetName), uuid.NewString()[:8]), 63)
	sessionClient, err := client.MessageSessionClient(ctx, scaleSet.ID, owner)
	if err != nil {
		return fmt.Errorf("creating GitHub scale set message session: %w", err)
	}
	defer func() {
		closeCtx, closeCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer closeCancel()
		if err := sessionClient.Close(closeCtx); err != nil {
			logger.Warn("Failed to close GitHub message session", "error", err)
		}
	}()

	scaleListener, err := listener.New(sessionClient, listener.Config{
		ScaleSetID: scaleSet.ID,
		MaxRunners: config.ListenerMaxRunners(),
		Logger:     logger.WithGroup("listener"),
	})
	if err != nil {
		return fmt.Errorf("creating runner scale listener: %w", err)
	}
	if err := scaler.AdoptExisting(ctx); err != nil {
		return fmt.Errorf("adopting existing runner VMs: %w", err)
	}
	scaler.Start(ctx, gate)
	defer func() {
		cancel()
		scaler.Wait()
	}()

	logger.Info("Runner scale controller ready", "scaleSet", config.ScaleSetName, "minRunners", 0, "maxRunners", config.MaxRunners, "vmSize", config.VMSize)
	if err := scaleListener.Run(ctx, scaler); err != nil && !errors.Is(err, context.Canceled) {
		return fmt.Errorf("runner scale listener: %w", err)
	}
	return ctx.Err()
}

func systemInfo(scaleSetID int) scaleset.SystemInfo {
	return scaleset.SystemInfo{
		System:     "azure-ephemeral-vm-runners",
		Subsystem:  "controller",
		Version:    version,
		CommitSHA:  commitSHA,
		ScaleSetID: scaleSetID,
	}
}

func newLogger(level string) *slog.Logger {
	var slogLevel slog.Level
	switch strings.ToLower(level) {
	case "debug":
		slogLevel = slog.LevelDebug
	case "warn":
		slogLevel = slog.LevelWarn
	case "error":
		slogLevel = slog.LevelError
	default:
		slogLevel = slog.LevelInfo
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slogLevel}))
}
