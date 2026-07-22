package main

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

func validConfig() Config {
	return Config{
		RegistrationURL: "https://github.com/AvantiPoint",
		ScaleSetName:    "avp-linux-lg",
		RunnerGroup:     scaleset.DefaultRunnerGroup,
		Labels:          []string{"avp-linux-lg"},
		MinRunners:      0,
		MaxRunners:      20,
		GitHubApp: scaleset.GitHubAppAuth{
			ClientID:       "Iv1.example",
			InstallationID: 123,
			PrivateKey:     "test-private-key",
		},
		SubscriptionID:       "d901cbec-f20d-4272-a0b4-9ee06b850880",
		ResourceGroup:        "gha-runners-prod",
		Location:             "eastus2",
		SubnetID:             "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/runners",
		VMSize:               "Standard_D4s_v5",
		VMAdminUser:          "azureuser",
		VMSSHPublicKey:       "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest runner@example",
		VMPriority:           "Regular",
		PublicIP:             true,
		RunnerVersion:        "2.335.1",
		RunnerSHA256:         "4ef2f25285f0ae4477f1fe1e346db76d2f3ebf03824e2ddd1973a2819bf6c8cf",
		RunnerUser:           defaultRunnerUser,
		OSDiskSizeGB:         128,
		ProvisionConcurrency: 4,
		ReconcileInterval:    time.Minute,
		IdleTimeout:          30 * time.Minute,
		MaxRunnerAge:         12 * time.Hour,
		ARMEndpoint:          defaultARMEndpoint,
	}
}

func TestConfigRequiresScaleToZero(t *testing.T) {
	config := validConfig()
	config.MinRunners = 1
	if err := config.Validate(); err == nil || !strings.Contains(err.Error(), "must be 0") {
		t.Fatalf("expected scale-to-zero validation error, got %v", err)
	}
}

func TestConfigCapsEachPoolAtTwenty(t *testing.T) {
	config := validConfig()
	config.MaxRunners = 21
	if err := config.Validate(); err == nil || !strings.Contains(err.Error(), "between 1 and 20") {
		t.Fatalf("expected capacity validation error, got %v", err)
	}
}

func TestCloudInitProtectsJITAndPowersOff(t *testing.T) {
	config := validConfig()
	cloudInit := renderCloudInit(config, "sensitive-jit-config")
	if strings.Contains(cloudInit, "sensitive-jit-config") {
		t.Fatal("JIT config must not appear in plaintext cloud-init YAML")
	}

	const marker = "    content: "
	index := strings.Index(cloudInit, marker)
	if index < 0 {
		t.Fatal("cloud-init embedded script not found")
	}
	line := strings.Split(cloudInit[index+len(marker):], "\n")[0]
	decoded, err := base64.StdEncoding.DecodeString(line)
	if err != nil {
		t.Fatalf("decode embedded script: %v", err)
	}
	script := string(decoded)
	for _, expected := range []string{
		"ACTIONS_RUNNER_INPUT_JITCONFIG",
		"shutdown -h now",
		"systemctl enable --now docker",
		"find /var/lib/cloud/instances",
		"rm -f -- \"$0\"",
		"sudo -HEu \"$RUNNER_USER\"",
	} {
		if !strings.Contains(script, expected) {
			t.Fatalf("embedded script missing %q", expected)
		}
	}
}

func TestAzureResourceNameIsStableAndBounded(t *testing.T) {
	name := azureResourceName("AVP Linux/Large Runner With A Very Long Invalid Name ################")
	if len(name) > 54 {
		t.Fatalf("resource name length = %d, want <= 54", len(name))
	}
	if name != strings.ToLower(name) || strings.ContainsAny(name, " /#") {
		t.Fatalf("resource name was not sanitized: %q", name)
	}
}

func TestAzureResourceNamePreservesUniqueSuffix(t *testing.T) {
	prefix := strings.Repeat("very-long-scale-set-", 4)
	first := azureResourceName(prefix + "aaaaaaaaaaaa")
	second := azureResourceName(prefix + "bbbbbbbbbbbb")
	if first == second {
		t.Fatalf("long runner names collided: %q", first)
	}
	if !strings.HasSuffix(first, "aaaaaaaaaaaa") || !strings.HasSuffix(second, "bbbbbbbbbbbb") {
		t.Fatalf("unique suffix was not preserved: %q, %q", first, second)
	}
}
