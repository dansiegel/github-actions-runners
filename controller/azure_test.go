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

	vm, err := manager.Create(context.Background(), "avp-linux-abc123", "one-time-jit")
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
