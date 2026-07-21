package main

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/actions/scaleset"
)

const (
	defaultARMEndpoint = "https://management.azure.com"
	defaultRunnerUser  = "actions-runner"
)

type Config struct {
	RegistrationURL string
	ScaleSetName    string
	RunnerGroup     string
	Labels          []string
	MinRunners      int
	MaxRunners      int
	GitHubApp       scaleset.GitHubAppAuth

	SubscriptionID string
	ResourceGroup  string
	Location       string
	SubnetID       string
	VMSize         string
	ImageID        string
	VMAdminUser    string
	VMSSHPublicKey string
	VMPriority     string
	PublicIP       bool

	RunnerVersion string
	RunnerSHA256  string
	RunnerUser    string
	OSDiskSizeGB  int

	ProvisionConcurrency int
	ReconcileInterval    time.Duration
	IdleTimeout          time.Duration
	MaxRunnerAge         time.Duration
	ARMEndpoint          string
	LogLevel             string
}

func LoadConfig() (Config, error) {
	c := Config{
		RegistrationURL: env("GITHUB_CONFIG_URL", ""),
		ScaleSetName:    env("RUNNER_SCALE_SET_NAME", ""),
		RunnerGroup:     env("RUNNER_GROUP", scaleset.DefaultRunnerGroup),
		Labels:          splitCSV(env("RUNNER_LABELS", "")),
		SubscriptionID:  env("AZURE_SUBSCRIPTION_ID", ""),
		ResourceGroup:   env("AZURE_RESOURCE_GROUP", ""),
		Location:        env("AZURE_LOCATION", ""),
		SubnetID:        env("RUNNER_SUBNET_ID", ""),
		VMSize:          env("RUNNER_VM_SIZE", "Standard_D2s_v5"),
		ImageID:         env("RUNNER_IMAGE_ID", ""),
		VMAdminUser:     env("RUNNER_ADMIN_USERNAME", "azureuser"),
		VMSSHPublicKey:  env("RUNNER_ADMIN_SSH_PUBLIC_KEY", ""),
		VMPriority:      env("RUNNER_VM_PRIORITY", "Regular"),
		RunnerVersion:   env("RUNNER_VERSION", "2.335.1"),
		RunnerSHA256:    env("RUNNER_SHA256", "4ef2f25285f0ae4477f1fe1e346db76d2f3ebf03824e2ddd1973a2819bf6c8cf"),
		RunnerUser:      env("RUNNER_USER", defaultRunnerUser),
		ARMEndpoint:     strings.TrimRight(env("AZURE_ARM_ENDPOINT", defaultARMEndpoint), "/"),
		LogLevel:        env("LOG_LEVEL", "info"),
		GitHubApp: scaleset.GitHubAppAuth{
			ClientID:   env("GITHUB_APP_CLIENT_ID", ""),
			PrivateKey: normalizePEM(env("GITHUB_APP_PRIVATE_KEY", "")),
		},
	}

	var err error
	if c.MinRunners, err = envInt("MIN_RUNNERS", 0); err != nil {
		return Config{}, err
	}
	if c.MaxRunners, err = envInt("MAX_RUNNERS", 10); err != nil {
		return Config{}, err
	}
	if c.GitHubApp.InstallationID, err = envInt64("GITHUB_APP_INSTALLATION_ID", 0); err != nil {
		return Config{}, err
	}
	if c.OSDiskSizeGB, err = envInt("RUNNER_OS_DISK_SIZE_GB", 128); err != nil {
		return Config{}, err
	}
	if c.ProvisionConcurrency, err = envInt("PROVISION_CONCURRENCY", 4); err != nil {
		return Config{}, err
	}
	if c.PublicIP, err = envBool("RUNNER_PUBLIC_IP", true); err != nil {
		return Config{}, err
	}
	if c.ReconcileInterval, err = envDuration("RECONCILE_INTERVAL", time.Minute); err != nil {
		return Config{}, err
	}
	if c.IdleTimeout, err = envDuration("RUNNER_IDLE_TIMEOUT", 30*time.Minute); err != nil {
		return Config{}, err
	}
	if c.MaxRunnerAge, err = envDuration("RUNNER_MAX_AGE", 12*time.Hour); err != nil {
		return Config{}, err
	}

	return c, c.Validate()
}

func (c *Config) Validate() error {
	parsed, err := url.ParseRequestURI(c.RegistrationURL)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return fmt.Errorf("GITHUB_CONFIG_URL must be a full HTTPS repository, organization, or enterprise URL")
	}
	if c.ScaleSetName == "" {
		return fmt.Errorf("RUNNER_SCALE_SET_NAME is required")
	}
	if c.RunnerGroup == "" {
		return fmt.Errorf("RUNNER_GROUP is required")
	}
	if len(c.Labels) == 0 {
		c.Labels = []string{c.ScaleSetName}
	}
	for _, label := range c.Labels {
		if strings.TrimSpace(label) == "" {
			return fmt.Errorf("RUNNER_LABELS cannot contain an empty label")
		}
	}
	if err := c.GitHubApp.Validate(); err != nil {
		return fmt.Errorf("GitHub App configuration is invalid: %w", err)
	}
	if c.MinRunners != 0 {
		return fmt.Errorf("MIN_RUNNERS must be 0 so runner compute scales completely to zero")
	}
	if c.MaxRunners < 1 || c.MaxRunners > 20 {
		return fmt.Errorf("MAX_RUNNERS must be between 1 and 20 for each pool")
	}
	for name, value := range map[string]string{
		"AZURE_SUBSCRIPTION_ID":       c.SubscriptionID,
		"AZURE_RESOURCE_GROUP":        c.ResourceGroup,
		"AZURE_LOCATION":              c.Location,
		"RUNNER_SUBNET_ID":            c.SubnetID,
		"RUNNER_VM_SIZE":              c.VMSize,
		"RUNNER_ADMIN_USERNAME":       c.VMAdminUser,
		"RUNNER_ADMIN_SSH_PUBLIC_KEY": c.VMSSHPublicKey,
		"RUNNER_VERSION":              c.RunnerVersion,
		"RUNNER_SHA256":               c.RunnerSHA256,
	} {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("%s is required", name)
		}
	}
	if c.VMPriority != "Regular" && c.VMPriority != "Spot" {
		return fmt.Errorf("RUNNER_VM_PRIORITY must be Regular or Spot")
	}
	if c.OSDiskSizeGB < 64 {
		return fmt.Errorf("RUNNER_OS_DISK_SIZE_GB must be at least 64")
	}
	if c.ProvisionConcurrency < 1 || c.ProvisionConcurrency > 20 {
		return fmt.Errorf("PROVISION_CONCURRENCY must be between 1 and 20")
	}
	if c.ReconcileInterval < 15*time.Second {
		return fmt.Errorf("RECONCILE_INTERVAL must be at least 15s")
	}
	if c.IdleTimeout < 5*time.Minute {
		return fmt.Errorf("RUNNER_IDLE_TIMEOUT must be at least 5m")
	}
	if c.MaxRunnerAge < time.Hour {
		return fmt.Errorf("RUNNER_MAX_AGE must be at least 1h")
	}
	return nil
}

func (c Config) ScaleSetLabels() []scaleset.Label {
	labels := make([]scaleset.Label, 0, len(c.Labels))
	for _, label := range c.Labels {
		labels = append(labels, scaleset.Label{Name: strings.TrimSpace(label)})
	}
	return labels
}

func env(name, fallback string) string {
	if value, ok := os.LookupEnv(name); ok {
		return strings.TrimSpace(value)
	}
	return fallback
}

func envInt(name string, fallback int) (int, error) {
	value := env(name, "")
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer: %w", name, err)
	}
	return parsed, nil
}

func envInt64(name string, fallback int64) (int64, error) {
	value := env(name, "")
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer: %w", name, err)
	}
	return parsed, nil
}

func envBool(name string, fallback bool) (bool, error) {
	value := env(name, "")
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return false, fmt.Errorf("%s must be true or false: %w", name, err)
	}
	return parsed, nil
}

func envDuration(name string, fallback time.Duration) (time.Duration, error) {
	value := env(name, "")
	if value == "" {
		return fallback, nil
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("%s must be a Go duration such as 30m or 12h: %w", name, err)
	}
	return parsed, nil
}

func splitCSV(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
}

func normalizePEM(value string) string {
	return strings.ReplaceAll(value, `\n`, "\n")
}
