package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"os"
	"regexp"
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
	Pools           []RunnerPool
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
	OSDiskTier    string

	ProvisionConcurrency int
	ReconcileInterval    time.Duration
	IdleTimeout          time.Duration
	MaxRunnerAge         time.Duration
	ARMEndpoint          string
	LogLevel             string
}

// RunnerPool describes a logical GitHub queue, not an always-on Azure resource.
// A missing or zero MaxRunners follows demand without an operator-imposed cap.
type RunnerPool struct {
	Name       string   `json:"name"`
	VMSize     string   `json:"vmSize"`
	MaxRunners int      `json:"maxRunners"`
	Priority   string   `json:"priority"`
	Labels     []string `json:"labels"`
	OSDiskTier string   `json:"osDiskTier"`
	Enabled    *bool    `json:"enabled,omitempty"`
	ImageID    string   `json:"imageId,omitempty"`
}

func (p *RunnerPool) UnmarshalJSON(data []byte) error {
	type poolJSON RunnerPool
	var decoded poolJSON
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&decoded); err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	allowed := map[string]bool{"name":true, "vmSize":true, "maxRunners":true, "priority":true, "labels":true, "osDiskTier":true, "enabled":true, "imageId":true}
	for key := range fields {
		if !allowed[key] { return fmt.Errorf("unknown runner pool field %q", key) }
	}
	for _, key := range []string{"maxRunners", "enabled", "imageId"} {
		if value, present := fields[key]; present && strings.TrimSpace(string(value)) == "null" {
			return fmt.Errorf("%s cannot be null", key)
		}
	}
	*p = RunnerPool(decoded)
	return nil
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
		VMSize:          env("RUNNER_VM_SIZE", "Standard_D4s_v5"),
		ImageID:         env("RUNNER_IMAGE_ID", ""),
		VMAdminUser:     env("RUNNER_ADMIN_USERNAME", "azureuser"),
		VMSSHPublicKey:  env("RUNNER_ADMIN_SSH_PUBLIC_KEY", ""),
		VMPriority:      env("RUNNER_VM_PRIORITY", "Regular"),
		RunnerVersion:   env("RUNNER_VERSION", "2.337.0"),
		RunnerSHA256:    env("RUNNER_SHA256", "70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613"),
		RunnerUser:      env("RUNNER_USER", defaultRunnerUser),
		OSDiskTier:      env("RUNNER_OS_DISK_TIER", ""),
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
	if c.MaxRunners, err = envInt("MAX_RUNNERS", 0); err != nil {
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
	if raw := env("RUNNER_POOLS_JSON", ""); raw != "" {
		if err := json.Unmarshal([]byte(raw), &c.Pools); err != nil {
			return Config{}, fmt.Errorf("RUNNER_POOLS_JSON must be a runner pool array: %w", err)
		}
		if len(c.Pools) == 0 {
			return Config{}, fmt.Errorf("RUNNER_POOLS_JSON must contain at least one pool")
		}
	}

	return c, c.Validate()
}

func (c *Config) Validate() error {
	if len(c.Pools) > 0 {
		_, err := c.PoolConfigs()
		return err
	}
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
	if c.MaxRunners < 0 || c.MaxRunners > math.MaxInt32 {
		return fmt.Errorf("MAX_RUNNERS must be 0 (uncapped) or a positive int32")
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
	if _, err := c.EffectiveOSDiskSizeGB(); err != nil {
		return err
	}
	if c.ProvisionConcurrency < 1 {
		return fmt.Errorf("PROVISION_CONCURRENCY must be positive")
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

// PoolConfigs also validates disabled profiles so that enabling one cannot
// silently introduce an ambiguous label or an invalid disk configuration.
func (c Config) PoolConfigs() ([]Config, error) {
	if len(c.Pools) == 0 {
		if err := c.Validate(); err != nil {
			return nil, err
		}
		return []Config{c}, nil
	}
	names := make(map[string]bool)
	labels := make(map[string]string)
	result := make([]Config, 0, len(c.Pools))
	for _, pool := range c.Pools {
		name := strings.TrimSpace(pool.Name)
		if !regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`).MatchString(name) || names[strings.ToLower(name)] {
			return nil, fmt.Errorf("runner pool names must be valid and unique: %q", name)
		}
		names[strings.ToLower(name)] = true
		p := c
		p.Pools = nil
		p.ScaleSetName = name
		p.VMSize = strings.TrimSpace(pool.VMSize)
		if !regexp.MustCompile(`^Standard_[A-Za-z0-9_]+$`).MatchString(p.VMSize) {
			return nil, fmt.Errorf("runner pool %q has an invalid VM size", name)
		}
		p.MaxRunners = pool.MaxRunners
		p.VMPriority = strings.TrimSpace(pool.Priority)
		if p.VMPriority == "" {
			p.VMPriority = "Regular"
		}
		p.OSDiskTier = strings.TrimSpace(pool.OSDiskTier)
		if imageID := strings.TrimSpace(pool.ImageID); imageID != "" {
			p.ImageID = imageID
		}
		p.Labels = append([]string(nil), pool.Labels...)
		if len(p.Labels) == 0 {
			p.Labels = []string{name}
		}
		if err := p.Validate(); err != nil {
			return nil, fmt.Errorf("runner pool %q: %w", name, err)
		}
		for _, label := range p.Labels {
			key := strings.ToLower(strings.TrimSpace(label))
			if owner, ok := labels[key]; ok {
				return nil, fmt.Errorf("runner label %q is repeated in pools %q and %q", label, owner, name)
			}
			labels[key] = name
		}
		if pool.Enabled == nil || *pool.Enabled {
			result = append(result, p)
		}
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("at least one runner pool must be enabled")
	}
	return result, nil
}

func (c Config) ListenerMaxRunners() int {
	if c.MaxRunners == 0 {
		// The GitHub message protocol requires a finite int32. SDK zero means
		// no capacity, so it must not be used for an uncapped operator setting.
		return math.MaxInt32
	}
	return c.MaxRunners
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

// EffectiveOSDiskSizeGB selects a capacity-backed Premium SSD tier at VM creation.
// An omitted tier preserves the existing configured size; no existing disk is resized.
func (c Config) EffectiveOSDiskSizeGB() (int, error) {
	if c.OSDiskSizeGB < 64 {
		return 0, fmt.Errorf("RUNNER_OS_DISK_SIZE_GB must be at least 64")
	}
	if c.OSDiskTier == "" {
		return c.OSDiskSizeGB, nil
	}
	sizes := map[string]int{"P10": 128, "P15": 256, "P20": 512, "P30": 1024}
	size, ok := sizes[c.OSDiskTier]
	if !ok {
		return 0, fmt.Errorf("RUNNER_OS_DISK_TIER must be empty, P10, P15, P20, or P30")
	}
	if c.OSDiskSizeGB > size {
		return 0, fmt.Errorf("RUNNER_OS_DISK_SIZE_GB exceeds the selected RUNNER_OS_DISK_TIER capacity")
	}
	return size, nil
}
