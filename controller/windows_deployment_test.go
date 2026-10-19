package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestWindowsCreateGeneratesCredentialInsideAzureAndDeletesMetadata(t *testing.T) {
	var mu sync.Mutex
	var deployment map[string]any
	deleted := false
	server := newWindowsTestServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		mu.Lock()
		defer mu.Unlock()
		if strings.Contains(r.URL.Path, "/deployments/") {
			switch r.Method {
			case http.MethodPut:
				if err := json.NewDecoder(r.Body).Decode(&deployment); err != nil {
					t.Error(err)
				}
				w.WriteHeader(http.StatusCreated)
			case http.MethodGet:
				_, _ = io.WriteString(w, `{"properties":{"provisioningState":"Succeeded"}}`)
				return
			case http.MethodDelete:
				deleted = true
			}
		} else if strings.Contains(r.URL.Path, "/virtualMachines/") {
			t.Error("Windows VM bypassed secure template")
		}
		_, _ = io.WriteString(w, `{}`)
	}))
	defer server.Close()
	c := validConfig()
	c.OSType = "Windows"
	c.ImageID = "/images/windows"
	c.ARMEndpoint = server.URL
	manager := &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if _, err := manager.Create(context.Background(), "avp-windows-lp-123", "jit-token"); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if !deleted {
		t.Fatal("completed deployment metadata retained")
	}
	properties := deployment["properties"].(map[string]any)
	parameters := properties["parameters"].(map[string]any)
	if parameters["adminPassword"] != nil {
		t.Fatal("controller supplied an administrator credential")
	}
	template := properties["template"].(map[string]any)
	definitions := template["parameters"].(map[string]any)
	for _, name := range []string{"adminPassword", "customData"} {
		if definitions[name].(map[string]any)["type"] != "securestring" {
			t.Fatal("sensitive parameter not secure")
		}
	}
	if definitions["adminPassword"].(map[string]any)["defaultValue"] != "[concat('Aa1!', newGuid())]" {
		t.Fatal("credential must be generated inside Azure with password complexity")
	}
	if template["outputs"] != nil {
		t.Fatal("deployment must not expose credential outputs")
	}
	resource := template["resources"].([]any)[0].(map[string]any)
	profile := resource["properties"].(map[string]any)["osProfile"].(map[string]any)
	if profile["adminPassword"] != "[parameters('adminPassword')]" || profile["customData"] != "[parameters('customData')]" {
		t.Fatal("credential embedded in template history")
	}
	if resource["identity"] != nil {
		t.Fatal("runner received managed identity")
	}
	raw, _ := base64.StdEncoding.DecodeString(parameters["customData"].(map[string]any)["value"].(string))
	var data windowsBootstrapData
	if err := json.Unmarshal(raw, &data); err != nil {
		t.Fatal(err)
	}
	if data.SchemaVersion != 1 {
		t.Fatal("wrong payload")
	}
}

func TestWindowsDeleteCancelsDeploymentBeforeDeletingVM(t *testing.T) {
	state := "Running"
	var order []string
	server := newWindowsTestServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.Path, "/deployments/") {
			if strings.HasSuffix(r.URL.Path, "/cancel") {
				order = append(order, "cancel")
				state = "Canceled"
				w.WriteHeader(http.StatusNoContent)
				return
			}
			if r.Method == http.MethodGet {
				_, _ = io.WriteString(w, `{"properties":{"provisioningState":"`+state+`"}}`)
				return
			}
			if r.Method == http.MethodDelete {
				order = append(order, "deployment")
			}
		} else if r.Method == http.MethodDelete {
			if state != "Canceled" {
				t.Error("resources deleted before cancellation")
			}
			order = append(order, "resource")
		}
		_, _ = io.WriteString(w, `{}`)
	}))
	defer server.Close()
	c := validConfig()
	c.OSType = "Windows"
	c.ARMEndpoint = server.URL
	manager := &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if err := manager.Delete(context.Background(), "windows-test"); err != nil {
		t.Fatal(err)
	}
	if strings.Join(order, ",") != "cancel,deployment,resource,resource,resource" {
		t.Fatalf("unsafe cleanup order: %v", order)
	}
}

func TestUnqualifiedWindowsCreatesNoResources(t *testing.T) {
	calls := 0
	server := newWindowsTestServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls++; w.WriteHeader(http.StatusCreated) }))
	defer server.Close()
	c := validConfig()
	c.OSType = "Windows"
	c.ARMEndpoint = server.URL
	manager := &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if _, err := manager.Create(context.Background(), "windows-test", "jit"); err == nil {
		t.Fatal("unqualified Windows accepted")
	}
	if calls != 0 {
		t.Fatal("unqualified profile created billable network resources")
	}
}

func TestWindowsUncertainPutPollsWithoutRegeneratingCredential(t *testing.T) {
	puts := 0
	server := newWindowsTestServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.Path, "/deployments/") {
			if r.Method == http.MethodPut {
				puts++
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = io.WriteString(w, `{"error":{"code":"InternalServerError"}}`)
				return
			}
			if r.Method == http.MethodGet {
				_, _ = io.WriteString(w, `{"properties":{"provisioningState":"Succeeded"}}`)
				return
			}
		}
		_, _ = io.WriteString(w, `{}`)
	}))
	defer server.Close()
	c := validConfig()
	c.OSType = "Windows"
	c.ImageID = "/images/windows"
	c.ARMEndpoint = server.URL
	manager := &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if _, err := manager.Create(context.Background(), "windows-unique", "jit"); err != nil {
		t.Fatal(err)
	}
	if puts != 1 {
		t.Fatalf("deployment PUT occurred %d times; credential default can be reevaluated", puts)
	}
}

func TestMissingWindowsDeploymentAccessCreatesNoBillableResources(t *testing.T) {
	mutations := 0
	server := newWindowsTestServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			mutations++
		}
		w.WriteHeader(http.StatusForbidden)
		_, _ = io.WriteString(w, `{"error":{"code":"AuthorizationFailed"}}`)
	}))
	defer server.Close()
	c := validConfig()
	c.OSType = "Windows"
	c.ImageID = "/images/windows"
	c.ARMEndpoint = server.URL
	manager := &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if _, err := manager.Create(context.Background(), "windows-test", "jit"); err == nil {
		t.Fatal("missing deployment access accepted")
	}
	if mutations != 0 {
		t.Fatal("missing Windows permission allocated billable resources")
	}
}

func TestWindowsCleanupWaitsForCancellableStateAndDelayedVisibility(t *testing.T) {
	for _, initial := range []string{"Creating", "Updating", "Ready", "Canceling"} {
		t.Run(initial, func(t *testing.T) {
			reads, cancels, deletes := 0, 0, 0
			state := initial
			server := newWindowsTestServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.Contains(r.URL.Path, "/deployments/") {
					if strings.HasSuffix(r.URL.Path, "/cancel") {
						if state != "Running" {
							t.Errorf("canceled in state %s", state)
						}
						cancels++
						state = "Canceled"
						w.WriteHeader(http.StatusNoContent)
						return
					}
					if r.Method == http.MethodGet {
						reads++
						if reads <= 5 {
							w.WriteHeader(http.StatusNotFound)
							return
						}
						if reads >= 8 && state != "Canceled" {
							state = "Running"
						}
						io.WriteString(w, `{"properties":{"provisioningState":"`+state+`"}}`)
						return
					}
				}
				if r.Method == http.MethodDelete {
					if state != "Canceled" {
						t.Error("deleted before terminal deployment")
					}
					deletes++
				}
				io.WriteString(w, `{}`)
			}))
			defer server.Close()
			c := validConfig()
			c.OSType = "Windows"
			c.ARMEndpoint = server.URL
			manager := &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil)), deploymentPollInterval: time.Millisecond}
			manager.windowsDeployments.Store("delayed", true)
			if err := manager.Delete(context.Background(), "delayed"); err != nil {
				t.Fatal(err)
			}
			if cancels != 1 || deletes != 4 {
				t.Fatalf("cancels=%d deletes=%d", cancels, deletes)
			}
		})
	}
}

func TestUncertainWindowsDeployment404CannotReleaseResources(t *testing.T) {
	deletes := 0
	visible := false
	server := newWindowsTestServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			deletes++
		}
		if r.Method == http.MethodGet && !visible {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		io.WriteString(w, `{"properties":{"provisioningState":"Canceled"}}`)
	}))
	defer server.Close()
	c := validConfig()
	c.OSType = "Windows"
	c.ARMEndpoint = server.URL
	manager := &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil)), deploymentPollInterval: time.Millisecond}
	manager.windowsDeployments.Store("uncertain", true)
	if err := manager.Delete(context.Background(), "uncertain"); !errors.Is(err, errResourceNotFound) {
		t.Fatalf("missing deployment accepted: %v", err)
	}
	if deletes != 0 {
		t.Fatal("resources released while deployment visibility is uncertain")
	}
	visible = true
	if err := manager.Delete(context.Background(), "uncertain"); err != nil {
		t.Fatal(err)
	}
	if deletes != 4 {
		t.Fatalf("retry did not clean resources: %d", deletes)
	}
}

func TestRejectedWindowsDeploymentReleasesNetworkResources(t *testing.T) {
	for _, status := range []int{400, 401, 403, 404, 405, 422} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			deploymentPuts, resourceDeletes := 0, 0
			server := newWindowsTestServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.Contains(r.URL.Path, "/deployments/") {
					if r.Method == http.MethodPut {
						deploymentPuts++
						w.WriteHeader(status)
						return
					}
					w.WriteHeader(http.StatusNotFound)
					return
				}
				if r.Method == http.MethodDelete {
					resourceDeletes++
				}
				io.WriteString(w, `{}`)
			}))
			defer server.Close()
			c := validConfig()
			c.OSType = "Windows"
			c.ImageID = "/images/windows"
			c.ARMEndpoint = server.URL
			manager := &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil)), deploymentPollInterval: time.Millisecond}
			if _, err := manager.Create(context.Background(), "rejected", "jit"); err == nil {
				t.Fatal("rejected deployment succeeded")
			}
			if submitted, _ := manager.windowsDeployments.Load("rejected"); submitted == true {
				t.Fatal("rejected PUT retained uncertain marker")
			}
			if deploymentPuts != 1 || resourceDeletes != 3 {
				t.Fatalf("PUTs=%d resource deletions=%d", deploymentPuts, resourceDeletes)
			}
		})
	}
}

func TestAcceptedWindowsPutWithForbiddenOperationReadStaysUncertain(t *testing.T) {
	server := newWindowsTestServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut && strings.Contains(r.URL.Path, "/deployments/") {
			w.Header().Set("Azure-AsyncOperation", "http://"+r.Host+"/accepted-operation")
			w.WriteHeader(http.StatusAccepted)
			return
		}
		if r.URL.Path == "/accepted-operation" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		if r.Method == http.MethodPut {
			w.WriteHeader(http.StatusCreated)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()
	c := validConfig()
	c.OSType = "Windows"
	c.PublicIP = false
	c.ImageID = "/images/windows"
	c.ARMEndpoint = server.URL
	manager := &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil)), deploymentPollInterval: time.Millisecond}
	if err := manager.put(context.Background(), manager.nicID("accepted"), networkAPIVersion, map[string]any{"tags": map[string]string{"existing": "preserved"}}); err != nil {
		t.Fatal(err)
	}
	body := map[string]any{"properties": map[string]any{"osProfile": map[string]any{"customData": "fixture"}}}
	if err := manager.createRunnerVM(context.Background(), "accepted", body); err == nil {
		t.Fatal("uncertain operation succeeded")
	}
	if _, submitted := manager.windowsDeployments.Load("accepted"); !submitted {
		t.Fatal("GET denial after accepted PUT cleared uncertainty")
	}
}

func newWindowsTestServer(handler http.Handler) *httptest.Server {
	var mu sync.Mutex
	resources := map[string]map[string]string{}
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		network := strings.Contains(r.URL.Path, "/networkInterfaces/") || strings.Contains(r.URL.Path, "/publicIPAddresses/")
		if network {
			mu.Lock()
			if r.Method == http.MethodPut || r.Method == http.MethodPatch {
				raw, _ := io.ReadAll(r.Body)
				r.Body = io.NopCloser(bytes.NewReader(raw))
				var body struct {
					Tags map[string]string `json:"tags"`
				}
				json.Unmarshal(raw, &body)
				resources[r.URL.Path] = body.Tags
				if r.Method == http.MethodPatch {
					mu.Unlock()
					io.WriteString(w, `{}`)
					return
				}
			}
			if r.Method == http.MethodGet {
				tags, ok := resources[r.URL.Path]
				if !ok {
					mu.Unlock()
					w.WriteHeader(http.StatusNotFound)
					return
				}
				json.NewEncoder(w).Encode(map[string]any{"tags": tags})
				mu.Unlock()
				return
			}
			if r.Method == http.MethodDelete {
				delete(resources, r.URL.Path)
			}
			mu.Unlock()
		}
		handler.ServeHTTP(w, r)
	}))
}

func TestWindowsDeploymentStateSurvivesManagerRestart(t *testing.T) {
	for _, uncertain := range []bool{true, false} {
		t.Run(fmt.Sprint(uncertain), func(t *testing.T) {
			var mu sync.Mutex
			state := ""
			resourceDeletes := 0
			server := newWindowsTestServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				defer mu.Unlock()
				if strings.Contains(r.URL.Path, "/deployments/") {
					if strings.HasSuffix(r.URL.Path, "/cancel") {
						state = "Canceled"
						w.WriteHeader(http.StatusNoContent)
						return
					}
					switch r.Method {
					case http.MethodPut:
						if uncertain {
							w.WriteHeader(http.StatusInternalServerError)
							return
						}
						state = "Succeeded"
						w.WriteHeader(http.StatusCreated)
						return
					case http.MethodGet:
						if state == "" {
							w.WriteHeader(http.StatusNotFound)
							return
						}
						io.WriteString(w, `{"properties":{"provisioningState":"`+state+`"}}`)
						return
					case http.MethodDelete:
						state = ""
						io.WriteString(w, `{}`)
						return
					}
				}
				if r.Method == http.MethodDelete {
					resourceDeletes++
				}
				io.WriteString(w, `{}`)
			}))
			defer server.Close()
			c := validConfig()
			c.OSType = "Windows"
			c.ImageID = "/images/windows"
			c.ARMEndpoint = server.URL
			fresh := func() *AzureVMManager {
				return &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil)), deploymentPollInterval: time.Millisecond}
			}
			manager := fresh()
			_, err := manager.Create(context.Background(), "restart-fixture", "jit")
			if (err != nil) != uncertain {
				t.Fatalf("create uncertainty=%v: %v", uncertain, err)
			}
			expected := "terminal"
			if uncertain {
				expected = "pending"
			}
			for _, id := range []string{manager.nicID("restart-fixture"), manager.publicIPID("restart-fixture")} {
				raw, err := manager.get(context.Background(), id, networkAPIVersion)
				if err != nil {
					t.Fatal(err)
				}
				var resource struct {
					Tags map[string]string `json:"tags"`
				}
				json.Unmarshal(raw, &resource)
				if resource.Tags[windowsDeploymentStateTag] != expected || resource.Tags["managed-by"] != "gha-runner-scale-controller" {
					t.Fatalf("durable state/ownership tags lost: %v", resource.Tags)
				}
			}
			manager = fresh() // No process-local submission knowledge survives.
			if uncertain {
				if err := manager.Delete(context.Background(), "restart-fixture"); !errors.Is(err, errResourceNotFound) {
					t.Fatalf("adopted pending deployment released: %v", err)
				}
				mu.Lock()
				deleted := resourceDeletes
				state = "Running"
				mu.Unlock()
				if deleted != 0 {
					t.Fatal("restart cleanup deleted resources before deployment visibility")
				}
			}
			if err := manager.Delete(context.Background(), "restart-fixture"); err != nil {
				t.Fatal(err)
			}
			mu.Lock()
			defer mu.Unlock()
			if resourceDeletes != 3 {
				t.Fatalf("resource deletes=%d", resourceDeletes)
			}
		})
	}
}

func TestWindowsSubmissionRequiresDurableMarkerReadback(t *testing.T) {
	puts := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			puts++
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		// A no-op PATCH must fail readback before any deployment PUT.
		io.WriteString(w, `{"tags":{"managed-by":"gha-runner-scale-controller","runner-windows-deployment":"not-submitted"}}`)
	}))
	defer server.Close()
	c := validConfig()
	c.OSType = "Windows"
	c.ARMEndpoint = server.URL
	manager := &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	body := map[string]any{"properties": map[string]any{"osProfile": map[string]any{"customData": "fixture"}}}
	if err := manager.createRunnerVM(context.Background(), "no-marker", body); err == nil {
		t.Fatal("submission accepted an unpersisted marker")
	}
	if puts != 0 {
		t.Fatal("deployment submitted before durable marker readback")
	}
}

func TestAdoptedWindowsNetworkWithoutKnownMarkerStaysConservative(t *testing.T) {
	for _, marker := range []string{"", "unknown"} {
		t.Run(marker, func(t *testing.T) {
			deletes := 0
			server := newWindowsTestServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.Contains(r.URL.Path, "/deployments/") {
					w.WriteHeader(http.StatusNotFound)
					return
				}
				if r.Method == http.MethodDelete {
					deletes++
				}
				io.WriteString(w, `{}`)
			}))
			defer server.Close()
			c := validConfig()
			c.OSType = "Windows"
			c.ARMEndpoint = server.URL
			manager := &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil)), deploymentPollInterval: time.Millisecond}
			tags := map[string]string{"managed-by": "gha-runner-scale-controller"}
			if marker != "" {
				tags[windowsDeploymentStateTag] = marker
			}
			if err := manager.put(context.Background(), manager.nicID("adopted"), networkAPIVersion, map[string]any{"tags": tags}); err != nil {
				t.Fatal(err)
			}
			if err := manager.Delete(context.Background(), "adopted"); !errors.Is(err, errResourceNotFound) {
				t.Fatalf("unknown persisted state accepted: %v", err)
			}
			if deletes != 0 {
				t.Fatal("unknown marker released network resources")
			}
		})
	}
}

func TestAdoptedPendingSnapshotSurvivesLaterResource404(t *testing.T) {
	deletes := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			deletes++
		}
		if strings.HasSuffix(r.URL.Path, "/networkInterfaces") {
			io.WriteString(w, `{"value":[{"name":"adopted-nic","tags":{"managed-by":"gha-runner-scale-controller","runner-scale-set":"linux-4vcpu","github-runner-name":"adopted","runner-windows-deployment":"pending"}}]}`)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/virtualMachines") || strings.HasSuffix(r.URL.Path, "/publicIPAddresses") {
			io.WriteString(w, `{"value":[]}`)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()
	c := validConfig()
	c.OSType = "Windows"
	c.ARMEndpoint = server.URL
	manager := &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil)), deploymentPollInterval: time.Millisecond}
	runners, err := manager.List(context.Background())
	if err != nil || len(runners) != 1 {
		t.Fatalf("adoption: %v %v", runners, err)
	}
	if err := manager.Delete(context.Background(), "adopted"); !errors.Is(err, errResourceNotFound) {
		t.Fatalf("lagging GET erased adopted pending state: %v", err)
	}
	if deletes != 0 {
		t.Fatal("adopted uncertainty caused resource deletion")
	}
}

func TestAdoptedWindowsVMSnapshotSurvivesMissingNetworkReads(t *testing.T) {
	deletes := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			deletes++
		}
		if strings.HasSuffix(r.URL.Path, "/virtualMachines") {
			io.WriteString(w, `{"value":[{"name":"adopted","tags":{"managed-by":"gha-runner-scale-controller","runner-scale-set":"linux-4vcpu","github-runner-name":"adopted"}}]}`)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/instanceView") {
			io.WriteString(w, `{"statuses":[{"code":"PowerState/deallocated"}]}`)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/networkInterfaces") || strings.HasSuffix(r.URL.Path, "/publicIPAddresses") {
			io.WriteString(w, `{"value":[]}`)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()
	c := validConfig()
	c.OSType = "Windows"
	c.ARMEndpoint = server.URL
	manager := &AzureVMManager{config: c, credential: fakeCredential{}, httpClient: server.Client(), logger: slog.New(slog.NewTextHandler(io.Discard, nil)), deploymentPollInterval: time.Millisecond}
	runners, err := manager.List(context.Background())
	if err != nil || len(runners) != 1 {
		t.Fatalf("adoption: %v %v", runners, err)
	}
	if err := manager.Delete(context.Background(), "adopted"); !errors.Is(err, errResourceNotFound) {
		t.Fatalf("network misses erased adopted VM evidence: %v", err)
	}
	if deletes != 0 {
		t.Fatal("adopted VM deleted before deployment finality")
	}
}
