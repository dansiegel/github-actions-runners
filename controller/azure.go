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
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
)

const (
	computeAPIVersion = "2024-07-01"
	networkAPIVersion = "2024-05-01"
)

var errResourceNotFound = errors.New("Azure resource not found")

type RunnerVM struct {
	RunnerName string
	VMName     string
	CreatedAt  time.Time
	PowerState string
}

type AzureVMManager struct {
	config     Config
	credential azcore.TokenCredential
	httpClient *http.Client
	logger     *slog.Logger
}

func NewAzureVMManager(config Config, logger *slog.Logger) (*AzureVMManager, error) {
	var credential azcore.TokenCredential
	var err error
	if clientID := strings.TrimSpace(os.Getenv("AZURE_CLIENT_ID")); clientID != "" {
		credential, err = azidentity.NewManagedIdentityCredential(&azidentity.ManagedIdentityCredentialOptions{
			ID: azidentity.ClientID(clientID),
		})
	} else {
		credential, err = azidentity.NewDefaultAzureCredential(nil)
	}
	if err != nil {
		return nil, fmt.Errorf("creating Azure credential: %w", err)
	}
	return &AzureVMManager{
		config:     config,
		credential: credential,
		httpClient: &http.Client{Timeout: 2 * time.Minute},
		logger:     logger,
	}, nil
}

func (m *AzureVMManager) Create(ctx context.Context, runnerName, encodedJITConfig string) (RunnerVM, error) {
	vmName := azureResourceName(runnerName)
	createdAt := time.Now().UTC()
	tags := map[string]string{
		"managed-by":         "gha-runner-scale-controller",
		"runner-scale-set":   m.config.ScaleSetName,
		"github-runner-name": runnerName,
		"runner-created-at":  createdAt.Format(time.RFC3339),
		"ephemeral":          "true",
	}

	if m.config.PublicIP {
		if err := m.put(ctx, m.publicIPID(vmName), networkAPIVersion, map[string]any{
			"location": m.config.Location,
			"tags":     tags,
			"sku": map[string]any{
				"name": "Standard",
			},
			"properties": map[string]any{
				"publicIPAllocationMethod": "Static",
				"publicIPAddressVersion":   "IPv4",
				"deleteOption":             "Delete",
			},
		}); err != nil {
			return RunnerVM{}, fmt.Errorf("creating public IP for %s: %w", runnerName, err)
		}
	}

	ipProperties := map[string]any{
		"privateIPAllocationMethod": "Dynamic",
		"privateIPAddressVersion":   "IPv4",
		"subnet": map[string]any{
			"id": m.config.SubnetID,
		},
	}
	if m.config.PublicIP {
		ipProperties["publicIPAddress"] = map[string]any{
			"id":         m.publicIPID(vmName),
			"properties": map[string]any{"deleteOption": "Delete"},
		}
	}

	if err := m.put(ctx, m.nicID(vmName), networkAPIVersion, map[string]any{
		"location": m.config.Location,
		"tags":     tags,
		"properties": map[string]any{
			"ipConfigurations": []any{
				map[string]any{
					"name":       "ipconfig1",
					"properties": ipProperties,
				},
			},
			"enableAcceleratedNetworking": false,
		},
	}); err != nil {
		_ = m.delete(ctx, m.publicIPID(vmName), networkAPIVersion)
		return RunnerVM{}, fmt.Errorf("creating NIC for %s: %w", runnerName, err)
	}

	imageReference := map[string]any{
		"publisher": "Canonical",
		"offer":     "ubuntu-24_04-lts",
		"sku":       "server",
		"version":   "latest",
	}
	if m.config.ImageID != "" {
		imageReference = map[string]any{"id": m.config.ImageID}
	}

	vmProperties := map[string]any{
		"hardwareProfile": map[string]any{
			"vmSize": m.config.VMSize,
		},
		"osProfile": map[string]any{
			"computerName":  takeString(vmName, 63),
			"adminUsername": m.config.VMAdminUser,
			"customData":    base64.StdEncoding.EncodeToString([]byte(renderCloudInit(m.config, encodedJITConfig))),
			"linuxConfiguration": map[string]any{
				"disablePasswordAuthentication": true,
				"ssh": map[string]any{
					"publicKeys": []any{
						map[string]any{
							"path":    fmt.Sprintf("/home/%s/.ssh/authorized_keys", m.config.VMAdminUser),
							"keyData": m.config.VMSSHPublicKey,
						},
					},
				},
			},
		},
		"storageProfile": map[string]any{
			"imageReference": imageReference,
			"osDisk": map[string]any{
				"createOption": "FromImage",
				"deleteOption": "Delete",
				"diskSizeGB":   m.config.OSDiskSizeGB,
				"caching":      "ReadWrite",
				"managedDisk": map[string]any{
					"storageAccountType": "Premium_LRS",
				},
			},
		},
		"networkProfile": map[string]any{
			"networkInterfaces": []any{
				map[string]any{
					"id": m.nicID(vmName),
					"properties": map[string]any{
						"primary":      true,
						"deleteOption": "Delete",
					},
				},
			},
		},
		"diagnosticsProfile": map[string]any{
			"bootDiagnostics": map[string]any{"enabled": true},
		},
	}
	if m.config.VMPriority == "Spot" {
		vmProperties["priority"] = "Spot"
		vmProperties["evictionPolicy"] = "Delete"
		vmProperties["billingProfile"] = map[string]any{"maxPrice": -1}
	}

	if err := m.put(ctx, m.vmID(vmName), computeAPIVersion, map[string]any{
		"location":   m.config.Location,
		"tags":       tags,
		"properties": vmProperties,
	}); err != nil {
		_ = m.Delete(context.WithoutCancel(ctx), vmName)
		return RunnerVM{}, fmt.Errorf("creating VM for %s: %w", runnerName, err)
	}

	return RunnerVM{RunnerName: runnerName, VMName: vmName, CreatedAt: createdAt, PowerState: "PowerState/starting"}, nil
}

func (m *AzureVMManager) Delete(ctx context.Context, vmName string) error {
	vmName = azureResourceName(vmName)
	var result error
	if err := m.delete(ctx, m.vmID(vmName), computeAPIVersion); err != nil && !errors.Is(err, errResourceNotFound) {
		return fmt.Errorf("deleting VM %s: %w", vmName, err)
	}
	if err := m.delete(ctx, m.nicID(vmName), networkAPIVersion); err != nil && !errors.Is(err, errResourceNotFound) {
		result = errors.Join(result, fmt.Errorf("deleting NIC for %s: %w", vmName, err))
	}
	if err := m.delete(ctx, m.publicIPID(vmName), networkAPIVersion); err != nil && !errors.Is(err, errResourceNotFound) {
		result = errors.Join(result, fmt.Errorf("deleting public IP for %s: %w", vmName, err))
	}
	return result
}

func (m *AzureVMManager) List(ctx context.Context) ([]RunnerVM, error) {
	path := fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Compute/virtualMachines", m.config.SubscriptionID, m.config.ResourceGroup)
	var response struct {
		Value []struct {
			Name string            `json:"name"`
			Tags map[string]string `json:"tags"`
		} `json:"value"`
		NextLink string `json:"nextLink"`
	}

	body, err := m.get(ctx, path, computeAPIVersion)
	if err != nil {
		return nil, fmt.Errorf("listing Azure VMs: %w", err)
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return nil, fmt.Errorf("decoding Azure VM list: %w", err)
	}

	result := make([]RunnerVM, 0, len(response.Value))
	for _, vm := range response.Value {
		if vm.Tags["managed-by"] != "gha-runner-scale-controller" || vm.Tags["runner-scale-set"] != m.config.ScaleSetName {
			continue
		}
		createdAt, _ := time.Parse(time.RFC3339, vm.Tags["runner-created-at"])
		powerState, err := m.PowerState(ctx, vm.Name)
		if err != nil && !errors.Is(err, errResourceNotFound) {
			m.logger.Warn("Unable to read runner power state", "vm", vm.Name, "error", err)
		}
		result = append(result, RunnerVM{
			RunnerName: vm.Tags["github-runner-name"],
			VMName:     vm.Name,
			CreatedAt:  createdAt,
			PowerState: powerState,
		})
	}
	return result, nil
}

func (m *AzureVMManager) PowerState(ctx context.Context, vmName string) (string, error) {
	path := m.vmID(azureResourceName(vmName)) + "/instanceView"
	body, err := m.get(ctx, path, computeAPIVersion)
	if err != nil {
		return "", err
	}
	var response struct {
		Statuses []struct {
			Code string `json:"code"`
		} `json:"statuses"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return "", fmt.Errorf("decoding instance view: %w", err)
	}
	for _, status := range response.Statuses {
		if strings.HasPrefix(status.Code, "PowerState/") {
			return status.Code, nil
		}
	}
	return "PowerState/unknown", nil
}

func (m *AzureVMManager) vmID(name string) string {
	return fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Compute/virtualMachines/%s", m.config.SubscriptionID, m.config.ResourceGroup, name)
}

func (m *AzureVMManager) nicID(name string) string {
	return fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Network/networkInterfaces/%s-nic", m.config.SubscriptionID, m.config.ResourceGroup, name)
}

func (m *AzureVMManager) publicIPID(name string) string {
	return fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Network/publicIPAddresses/%s-pip", m.config.SubscriptionID, m.config.ResourceGroup, name)
}

func (m *AzureVMManager) put(ctx context.Context, resourceID, apiVersion string, value any) error {
	body, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("encoding request: %w", err)
	}
	_, err = m.request(ctx, http.MethodPut, m.resourceURL(resourceID, apiVersion), body, http.StatusOK, http.StatusCreated)
	return err
}

func (m *AzureVMManager) get(ctx context.Context, resourceID, apiVersion string) ([]byte, error) {
	return m.request(ctx, http.MethodGet, m.resourceURL(resourceID, apiVersion), nil, http.StatusOK)
}

func (m *AzureVMManager) delete(ctx context.Context, resourceID, apiVersion string) error {
	_, err := m.request(ctx, http.MethodDelete, m.resourceURL(resourceID, apiVersion), nil, http.StatusOK, http.StatusAccepted, http.StatusNoContent)
	return err
}

func (m *AzureVMManager) resourceURL(resourceID, apiVersion string) string {
	separator := "?"
	if strings.Contains(resourceID, "?") {
		separator = "&"
	}
	return m.config.ARMEndpoint + resourceID + separator + "api-version=" + url.QueryEscape(apiVersion)
}

func (m *AzureVMManager) request(ctx context.Context, method, requestURL string, body []byte, accepted ...int) ([]byte, error) {
	for attempt := 0; attempt < 5; attempt++ {
		accessToken, err := m.credential.GetToken(ctx, policy.TokenRequestOptions{Scopes: []string{"https://management.azure.com/.default"}})
		if err != nil {
			return nil, fmt.Errorf("getting Azure access token: %w", err)
		}
		var reader io.Reader
		if body != nil {
			reader = bytes.NewReader(body)
		}
		req, err := http.NewRequestWithContext(ctx, method, requestURL, reader)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Authorization", "Bearer "+accessToken.Token)
		req.Header.Set("Accept", "application/json")
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}

		resp, err := m.httpClient.Do(req)
		if err != nil {
			if attempt == 4 {
				return nil, err
			}
			if err := sleepContext(ctx, time.Duration(attempt+1)*time.Second); err != nil {
				return nil, err
			}
			continue
		}
		responseBody, readErr := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
		resp.Body.Close()
		if readErr != nil {
			return nil, readErr
		}
		if resp.StatusCode == http.StatusNotFound {
			return nil, errResourceNotFound
		}
		if (resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500) && attempt < 4 {
			delay := retryDelay(resp.Header, attempt)
			if err := sleepContext(ctx, delay); err != nil {
				return nil, err
			}
			continue
		}
		if !containsStatus(accepted, resp.StatusCode) {
			return nil, fmt.Errorf("Azure ARM %s %s returned %d: %s", method, requestURL, resp.StatusCode, strings.TrimSpace(string(responseBody)))
		}

		operationURL := resp.Header.Get("Azure-AsyncOperation")
		if operationURL == "" {
			operationURL = resp.Header.Get("Location")
		}
		if operationURL != "" {
			if err := m.waitForOperation(ctx, operationURL, resp.Header); err != nil {
				return nil, err
			}
		}
		return responseBody, nil
	}
	return nil, fmt.Errorf("Azure ARM request exhausted retries")
}

func (m *AzureVMManager) waitForOperation(ctx context.Context, operationURL string, headers http.Header) error {
	delay := retryDelay(headers, 0)
	for {
		if err := sleepContext(ctx, delay); err != nil {
			return err
		}
		body, err := m.request(ctx, http.MethodGet, operationURL, nil, http.StatusOK, http.StatusCreated, http.StatusAccepted, http.StatusNoContent)
		if err != nil {
			return fmt.Errorf("polling Azure operation: %w", err)
		}
		if len(body) == 0 {
			return nil
		}
		var operation struct {
			Status string `json:"status"`
			Error  any    `json:"error"`
		}
		if err := json.Unmarshal(body, &operation); err != nil {
			return fmt.Errorf("decoding Azure operation: %w", err)
		}
		switch strings.ToLower(operation.Status) {
		case "", "succeeded":
			return nil
		case "failed", "canceled", "cancelled":
			encoded, _ := json.Marshal(operation.Error)
			return fmt.Errorf("Azure operation %s: %s", operation.Status, encoded)
		default:
			delay = 3 * time.Second
		}
	}
}

func containsStatus(values []int, target int) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func retryDelay(headers http.Header, attempt int) time.Duration {
	if raw := headers.Get("Retry-After"); raw != "" {
		if seconds, err := strconv.Atoi(raw); err == nil && seconds > 0 && seconds <= 60 {
			return time.Duration(seconds) * time.Second
		}
	}
	return time.Duration(1<<min(attempt, 5)) * time.Second
}

func sleepContext(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func azureResourceName(value string) string {
	value = strings.ToLower(value)
	var builder strings.Builder
	for _, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= '0' && char <= '9') || char == '-' {
			builder.WriteRune(char)
		} else {
			builder.WriteByte('-')
		}
	}
	result := strings.Trim(builder.String(), "-")
	if result == "" {
		result = "runner"
	}
	if len(result) > 54 {
		// Preserve the random runner-name suffix so long scale-set names cannot
		// collapse multiple ephemeral runners onto the same Azure resource name.
		result = result[:41] + "-" + result[len(result)-12:]
	}
	return result
}

func takeString(value string, length int) string {
	if len(value) <= length {
		return value
	}
	return value[:length]
}
