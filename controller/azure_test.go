package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
)

type fakeCredential struct{}

func (fakeCredential) GetToken(context.Context, policy.TokenRequestOptions) (azcore.AccessToken, error) {
	return azcore.AccessToken{Token: "test-token", ExpiresOn: time.Now().Add(time.Hour)}, nil
}

func TestAzureCreateUsesJITCustomDataWithoutRunnerIdentity(t *testing.T) {
	var mu sync.Mutex
	bodies := make(map[string]map[string]any)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("authorization header = %q", r.Header.Get("Authorization"))
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Errorf("read request: %v", err)
		}
		var decoded map[string]any
		if err := json.Unmarshal(body, &decoded); err != nil {
			t.Errorf("decode request: %v", err)
		}
		mu.Lock()
		bodies[r.URL.Path] = decoded
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer server.Close()

	config := validConfig()
	config.ARMEndpoint = server.URL
	config.ImageID = "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/images/preinstalled"
	manager := &AzureVMManager{
		config:     config,
		credential: fakeCredential{},
		httpClient: server.Client(),
		logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
	}

	vm, err := manager.Create(context.Background(), "linux-4vcpu-abc123", "one-time-jit")
	if err != nil {
		t.Fatalf("create VM: %v", err)
	}
	vmPath := manager.vmID(vm.VMName)
	mu.Lock()
	vmBody := bodies[vmPath]
	requestCount := len(bodies)
	mu.Unlock()
	if requestCount != 3 {
		t.Fatalf("Azure resource PUT count = %d, want public IP, NIC, and VM", requestCount)
	}
	if _, ok := vmBody["identity"]; ok {
		t.Fatal("runner VM must not have a managed identity")
	}

	properties := vmBody["properties"].(map[string]any)
	osProfile := properties["osProfile"].(map[string]any)
	customData, err := base64.StdEncoding.DecodeString(osProfile["customData"].(string))
	if err != nil {
		t.Fatalf("decode customData: %v", err)
	}
	if strings.Contains(string(customData), "one-time-jit") {
		t.Fatal("JIT value must be envelope-encoded in customData")
	}
	storage := properties["storageProfile"].(map[string]any)
	image := storage["imageReference"].(map[string]any)
	if image["id"] != config.ImageID {
		t.Fatalf("image ID = %v, want %s", image["id"], config.ImageID)
	}
}

func TestVMCreatePollsAcceptedOperationInsteadOfRetryingPut(t *testing.T) {
	var mu sync.Mutex
	vmPuts := 0
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.Path, "/operations/") {
			_, _ = w.Write([]byte(`{"status":"Succeeded"}`))
			return
		}
		if r.Method == http.MethodPut && strings.Contains(r.URL.Path, "/virtualMachines/") {
			mu.Lock()
			vmPuts++
			count := vmPuts
			mu.Unlock()
			if count > 1 {
				t.Errorf("VM PUT was retried after Azure accepted the operation")
			}
			w.Header().Set("Azure-AsyncOperation", server.URL+"/operations/vm")
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":{"code":"InternalServerError"}}`))
			return
		}
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer server.Close()

	config := validConfig()
	config.ARMEndpoint = server.URL
	config.PublicIP = false
	manager := &AzureVMManager{
		config:     config,
		credential: fakeCredential{},
		httpClient: server.Client(),
		logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	if _, err := manager.Create(context.Background(), "linux-4vcpu-abc123", "one-time-jit"); err != nil {
		t.Fatalf("create VM: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if vmPuts != 1 {
		t.Fatalf("VM PUT count = %d, want 1", vmPuts)
	}
}

func TestAzureCreateSelectsCapacityBackedDiskTierBeforeBoot(t *testing.T) {
	for _, test := range []struct {
		tier string
		want int
	}{{"", 128}, {"P20", 512}} {
		t.Run(test.tier, func(t *testing.T) {
			var disk map[string]any
			var mu sync.Mutex
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Error(err)
				}
				if strings.Contains(r.URL.Path, "/virtualMachines/") {
					mu.Lock()
					disk = body["properties"].(map[string]any)["storageProfile"].(map[string]any)["osDisk"].(map[string]any)
					mu.Unlock()
				}
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusCreated)
				_, _ = w.Write([]byte(`{}`))
			}))
			defer server.Close()
			config := validConfig()
			config.ARMEndpoint = server.URL
			config.OSDiskTier = test.tier
			manager := &AzureVMManager{config: config, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
			if _, err := manager.Create(context.Background(), "disk-tier-test", "jit"); err != nil {
				t.Fatal(err)
			}
			mu.Lock()
			defer mu.Unlock()
			if disk["diskSizeGB"] != float64(test.want) || disk["deleteOption"] != "Delete" || disk["managedDisk"].(map[string]any)["storageAccountType"] != "Premium_LRS" {
				t.Fatalf("unexpected disk: %#v", disk)
			}
		})
	}
}

func TestAzureCreateRejectsDiskTierBeforeAllocatingResources(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("invalid disk configuration reached Azure")
		w.WriteHeader(500)
	}))
	defer server.Close()
	config := validConfig()
	config.ARMEndpoint = server.URL
	config.OSDiskTier = "P99"
	manager := &AzureVMManager{config: config, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if _, err := manager.Create(context.Background(), "invalid-disk", "jit"); err == nil {
		t.Fatal("invalid tier accepted")
	}
}
