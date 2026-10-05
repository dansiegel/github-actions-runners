package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/actions/scaleset"
)

func validConfig() Config {
	return Config{
		RegistrationURL: "https://github.com/example-org",
		ScaleSetName:    "linux-4vcpu",
		RunnerGroup:     scaleset.DefaultRunnerGroup,
		Labels:          []string{"linux-4vcpu"},
		MinRunners:      0,
		MaxRunners:      20,
		GitHubApp: scaleset.GitHubAppAuth{
			ClientID:       "Iv1.example",
			InstallationID: 123,
			PrivateKey:     "test-private-key",
		},
		SubscriptionID:       "00000000-0000-0000-0000-000000000000",
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

func TestConfigAllowsUncappedAndExplicitCapacity(t *testing.T) {
	for _, cap := range []int{0, 1, 21, 1000, math.MaxInt32} {
		config := validConfig()
		config.MaxRunners = cap
		if err := config.Validate(); err != nil {
			t.Fatalf("capacity %d: %v", cap, err)
		}
		want := cap
		if cap == 0 { want = math.MaxInt32 }
		if config.ListenerMaxRunners() != want { t.Fatalf("capacity %d not translated correctly", cap) }
	}
	config := validConfig()
	config.MaxRunners = -1
	if config.Validate() == nil { t.Fatal("negative capacity accepted") }
}

func TestPoolConfigurationIsolationAndDisabledProfiles(t *testing.T) {
	config := validConfig()
	config.MaxRunners = 8 // Legacy value must not leak into omitted pool caps.
	disabled := false
	for i := range 10 {
		config.Pools = append(config.Pools, RunnerPool{Name: fmt.Sprintf("profile-%d", i), VMSize: "Standard_D4s_v5", OSDiskTier: "P20"})
	}
	config.Pools[0].Enabled = &disabled
	pools, err := config.PoolConfigs()
	if err != nil { t.Fatal(err) }
	if len(pools) != 9 { t.Fatalf("enabled profiles = %d", len(pools)) }
	for _, pool := range pools {
		if pool.MaxRunners != 0 || pool.MinRunners != 0 || pool.OSDiskTier != "P20" || pool.ImageID != config.ImageID { t.Fatalf("profile leaked configuration: %+v", pool) }
		if len(pool.Labels) != 1 || pool.Labels[0] != pool.ScaleSetName { t.Fatal("profile label mismatch") }
	}
	pools[0].Labels[0] = "changed"
	if pools[1].Labels[0] == "changed" { t.Fatal("profiles share mutable labels") }
}

func TestPoolConfigurationRejectsAmbiguousAndInvalidProfiles(t *testing.T) {
	for _, raw := range []string{
		`[{"name":"same","vmSize":"Standard_D4s_v5"},{"name":"SAME","vmSize":"Standard_D4s_v5"}]`,
		`[{"name":"one","vmSize":"Standard_D4s_v5","labels":["shared"]},{"name":"two","vmSize":"Standard_D4s_v5","labels":["SHARED"]}]`,
		`[{"name":"one","vmSize":"Standard_D4s_v5","enabled":false}]`,
		`[{"name":"one","vmSize":"Standard_D4s_v5","maxRunners":-1}]`,
		`[{"name":"one","vmSize":"Standard_D4s_v5","maxRunners":null}]`,
		`[{"name":"one","vmSize":"Standard_D4s_v5","maxRunners":1.5}]`,
		`[{"name":"one","vmSize":"Standard_D4s_v5","enabled":null}]`,
		`[{"name":"one","vmSize":"Standard_D4s_v5","enabled":"false"}]`,
		`[{"name":"one","vmSize":"Standard_D4s_v5","osDiskTier":"P99"}]`,
		`[{"name":"one","vmSize":"wrong"}]`,
		`[{"name":"one","vmSize":"Standard_D4s_v5","maxRunner":20}]`,
		`[{"name":"one","vmSize":"Standard_D4s_v5","maxrunners":null}]`,
		`[{"name":"one","vmSize":"Standard_D4s_v5","imageId":null}]`,
		`[{"name":"one","vmSize":"Standard_D4s_v5","imageId":42}]`,
	} {
		config := validConfig()
		if err := json.Unmarshal([]byte(raw), &config.Pools); err == nil {
			if err := config.Validate(); err == nil { t.Fatalf("invalid configuration accepted: %s", raw) }
		}
	}
}

func TestExampleProfilesResolveToRequestedHardwareAndDisk(t *testing.T) {
	data, err := os.ReadFile("../runner-pools.example.json")
	if err != nil { t.Fatal(err) }
	config := validConfig()
	if err := json.Unmarshal(data, &config.Pools); err != nil { t.Fatal(err) }
	if len(config.Pools) != 16 { t.Fatalf("profile count = %d", len(config.Pools)) }
	pools, err := config.PoolConfigs()
	if err != nil { t.Fatal(err) }
	if len(pools) != 6 { t.Fatalf("qualified profiles = %d", len(pools)) }
	seen := make(map[string]bool)
	for _, pool := range pools {
		key := pool.VMSize+"/"+pool.OSDiskTier
		if seen[key] { t.Fatalf("duplicate hardware profile %s",key) }
		seen[key] = true
		size, err := pool.EffectiveOSDiskSizeGB()
		if err != nil || (pool.OSDiskTier == "P10" && size != 128) || (pool.OSDiskTier == "P20" && size != 512) { t.Fatalf("wrong disk for %s: %d %v",key,size,err) }
		if pool.MaxRunners != 0 { t.Fatal("example profile has an artificial cap") }
	}
	for _, sku := range []string{"Standard_D2s_v5","Standard_D4s_v5","Standard_D8s_v5"} {
		for _, tier := range []string{"P10","P20"} { if !seen[sku+"/"+tier] { t.Fatalf("missing profile %s/%s",sku,tier) } }
	}
}

func TestLegacySingleProfileRemainsCompatible(t *testing.T) {
	config := validConfig()
	pools, err := config.PoolConfigs()
	if err != nil { t.Fatal(err) }
	if len(pools) != 1 || pools[0].ScaleSetName != config.ScaleSetName || pools[0].MaxRunners != config.MaxRunners || pools[0].OSDiskSizeGB != config.OSDiskSizeGB { t.Fatal("legacy configuration changed") }
}

func TestProfileImageOverridesKeepSharedFallback(t *testing.T) {
	config := validConfig()
	config.ImageID = "/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/images/shared"
	config.Pools = []RunnerPool{
		{Name:"shared",VMSize:"Standard_D4s_v5"},
		{Name:"override",VMSize:"Standard_D4s_v5",ImageID:"  /subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/images/override  "},
		{Name:"empty",VMSize:"Standard_D4s_v5",ImageID:"  "},
	}
	pools,err := config.PoolConfigs()
	if err != nil {t.Fatal(err)}
	if pools[0].ImageID != config.ImageID || pools[2].ImageID != config.ImageID {t.Fatal("shared image fallback changed")}
	if pools[1].ImageID != "/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/images/override" {t.Fatal("profile image override was not applied")}
}

func TestLegacyRunnerIdentityHardwareAndImageRemainPinned(t *testing.T) {
	config := validConfig()
	config.MaxRunners = 8
	config.ImageID = "/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/images/new-shared"
	legacyImage := "/subscriptions/test/resourceGroups/test/providers/Microsoft.Compute/images/qualified-legacy"
	config.Pools = []RunnerPool{{
		Name:"avp-linux", VMSize:"Standard_D4s_v5", Priority:"Regular", OSDiskTier:"P10", ImageID:legacyImage,
		Labels:[]string{"avp-linux","avp-linux-l"},
	}}
	pools,err := config.PoolConfigs()
	if err != nil {t.Fatal(err)}
	legacy := pools[0]
	diskSize,err := legacy.EffectiveOSDiskSizeGB()
	if err != nil {t.Fatal(err)}
	if legacy.ScaleSetName != "avp-linux" || legacy.VMSize != "Standard_D4s_v5" || legacy.ImageID != legacyImage || diskSize != 128 || legacy.VMPriority != "Regular" || legacy.RunnerGroup != config.RunnerGroup || legacy.RegistrationURL != config.RegistrationURL {
		t.Fatal("legacy identity, hardware, image, or ownership changed")
	}
	labels := legacy.ScaleSetLabels()
	if len(labels) != 2 || labels[0].Name != "avp-linux" || labels[1].Name != "avp-linux-l" {t.Fatal("legacy label or alias changed")}
	if legacy.MaxRunners != 0 {t.Fatal("legacy environment cap leaked into uncapped profile")}
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
		".installed-version",
	} {
		if !strings.Contains(script, expected) {
			t.Fatalf("embedded script missing %q", expected)
		}
	}
}

func TestAzureResourceNameIsStableAndBounded(t *testing.T) {
	name := azureResourceName("Example Linux/Large Runner With A Very Long Invalid Name ################")
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

func TestOSDiskTierMappingAndDefaultPreservation(t *testing.T) {
	for _, test := range []struct {
		tier             string
		configured, want int
		rejected         bool
	}{
		{"", 128, 128, false}, {"", 256, 256, false}, {"P10", 128, 128, false},
		{"P15", 128, 256, false}, {"P20", 128, 512, false}, {"P30", 128, 1024, false},
		{"P99", 128, 0, true}, {"p20", 128, 0, true}, {"P10", 256, 0, true}, {"P20", 32, 0, true},
	} {
		t.Run(fmt.Sprintf("%s-size-%d", test.tier, test.configured), func(t *testing.T) {
			config := validConfig()
			config.OSDiskTier = test.tier
			config.OSDiskSizeGB = test.configured
			got, err := config.EffectiveOSDiskSizeGB()
			if (err != nil) != test.rejected || got != test.want {
				t.Fatalf("size=%d error=%v", got, err)
			}
			if (config.Validate() != nil) != test.rejected {
				t.Fatal("configuration validation disagrees")
			}
		})
	}
}
