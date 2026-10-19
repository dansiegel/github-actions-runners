package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"
)

const deploymentAPIVersion = "2025-04-01"
const windowsDeploymentStateTag = "runner-windows-deployment"

func (m *AzureVMManager) deploymentID(vmName string) string {
	return fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Resources/deployments/%s", m.config.SubscriptionID, m.config.ResourceGroup, vmName)
}

func (m *AzureVMManager) createRunnerVM(ctx context.Context, vmName string, vmBody map[string]any) error {
	if m.config.OSType != "Windows" {
		return m.put(ctx, m.vmID(vmName), computeAPIVersion, vmBody)
	}
	properties := vmBody["properties"].(map[string]any)
	profile := properties["osProfile"].(map[string]any)
	customData := profile["customData"]
	profile["customData"] = "[parameters('customData')]"
	vmBody["type"] = "Microsoft.Compute/virtualMachines"
	vmBody["apiVersion"] = computeAPIVersion
	vmBody["name"] = vmName
	deployment := map[string]any{"properties": map[string]any{
		"mode": "Incremental",
		"parameters": map[string]any{
			"customData": map[string]any{"value": customData},
		},
		"template": map[string]any{
			"$schema":        "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
			"contentVersion": "1.0.0.0",
			"parameters": map[string]any{
				"adminPassword": map[string]any{"type": "securestring", "defaultValue": "[concat('Aa1!', newGuid())]"},
				"customData":    map[string]any{"type": "securestring"},
			},
			"resources": []any{vmBody},
		},
	}}
	body, err := json.Marshal(deployment)
	if err != nil {
		return err
	}
	// newGuid() is evaluated by Azure for this deployment. Never re-PUT an
	// uncertain deployment: that would evaluate a fresh default credential.
	// Poll the same deterministic deployment instead; later fleet retries use
	// a new runner/resource identity after cleanup.
	// Persist and read back the marker on the existing NIC/IP before the only
	// PUT. A new process must remain conservative even during ARM visibility lag.
	m.windowsDeployments.Store(vmName, false)
	if err := m.persistWindowsDeploymentState(ctx, vmName, "pending"); err != nil {
		return err
	}
	m.windowsDeployments.Store(vmName, true)
	_, putErr := m.requestWithRetry(ctx, http.MethodPut, m.resourceURL(m.deploymentID(vmName), deploymentAPIVersion), body, false, http.StatusOK, http.StatusCreated, http.StatusAccepted)
	var responseErr *armHTTPError
	if errors.As(putErr, &responseErr) && responseErr.method == http.MethodPut &&
		responseErr.statusCode >= 400 && responseErr.statusCode < 500 &&
		responseErr.statusCode != http.StatusRequestTimeout &&
		responseErr.statusCode != http.StatusConflict &&
		responseErr.statusCode != http.StatusTooManyRequests {
		// The PUT itself was rejected. A GET/polling failure after acceptance,
		// transport failure, timeout, conflict or server failure is uncertain.
		m.windowsDeployments.Store(vmName, false)
		return errors.Join(putErr, m.persistWindowsDeploymentState(ctx, vmName, "terminal"))
	}
	if err := m.waitWindowsDeployment(ctx, vmName, false); err != nil {
		return errors.Join(putErr, err)
	}
	// Delete completed deployment metadata; this never deletes its VM resources.
	if err := m.delete(ctx, m.deploymentID(vmName), deploymentAPIVersion); err != nil && !errors.Is(err, errResourceNotFound) {
		m.logger.Warn("Windows deployment metadata cleanup deferred", "vm", vmName)
	}
	return nil
}

func (m *AzureVMManager) waitWindowsDeployment(ctx context.Context, vmName string, cleanup bool) error {
	missingReads := 0
	cancelSubmitted := false
	interval := m.deploymentPollInterval
	if interval <= 0 {
		interval = 3 * time.Second
	}
	for {
		body, err := m.get(ctx, m.deploymentID(vmName), deploymentAPIVersion)
		if errors.Is(err, errResourceNotFound) {
			if missingReads < 5 {
				missingReads++
				if err := sleepContext(ctx, interval); err != nil {
					return err
				}
				continue
			}
			// An uncertain PUT is not disproved by missing reads. Leave network
			// resources intact and let cleanup retry until a terminal state is
			// observed, rather than allowing a late deployment to recreate a VM.
			if cleanup {
				submitted, known := m.windowsDeployments.Load(vmName)
				if known && submitted == false {
					return nil
				}
				if !known {
					if err := m.checkWindowsDeploymentMarkers(ctx, vmName); err != nil {
						return err
					}
					return nil
				}
			}
		}
		if err != nil {
			return err
		}
		missingReads = 0
		var deployment struct {
			Properties struct {
				ProvisioningState string          `json:"provisioningState"`
				Error             deploymentError `json:"error"`
			} `json:"properties"`
		}
		if err := json.Unmarshal(body, &deployment); err != nil {
			return fmt.Errorf("decoding Windows deployment state: %w", err)
		}
		state := strings.ToLower(deployment.Properties.ProvisioningState)
		switch state {
		case "succeeded":
			if err := m.persistWindowsDeploymentState(ctx, vmName, "terminal"); err != nil {
				return err
			}
			m.windowsDeployments.Store(vmName, false)
			return nil
		case "failed", "canceled", "cancelled":
			if err := m.persistWindowsDeploymentState(ctx, vmName, "terminal"); err != nil {
				return err
			}
			m.windowsDeployments.Store(vmName, false)
			if cleanup {
				return nil
			}
			return fmt.Errorf("Windows deployment %s (%s)", deployment.Properties.ProvisioningState, strings.Join(deployment.Properties.Error.codes(), ","))
		case "":
			return fmt.Errorf("missing Windows deployment state")
		}
		// Azure only accepts cancellation in these two states. Transitional
		// states (including Ready/Creating/Updating) must be read again first.
		if cleanup && !cancelSubmitted && (state == "accepted" || state == "running") {
			if _, err := m.request(ctx, http.MethodPost, m.resourceURL(m.deploymentID(vmName)+"/cancel", deploymentAPIVersion), nil, http.StatusOK, http.StatusAccepted, http.StatusNoContent); err != nil {
				return err
			}
			cancelSubmitted = true
		}
		if err := sleepContext(ctx, interval); err != nil {
			return err
		}
	}
}

func (m *AzureVMManager) finishWindowsDeployment(ctx context.Context, vmName string, cancel bool) error {
	if err := m.waitWindowsDeployment(ctx, vmName, cancel); err != nil {
		return err
	}
	if err := m.delete(ctx, m.deploymentID(vmName), deploymentAPIVersion); err != nil && !errors.Is(err, errResourceNotFound) {
		return err
	}
	return nil
}

// These tags use the existing network resource write permissions, create no
// extra resource and contain no credential or JIT data. Both resources retain a
// terminal marker so a crash between individual deletes remains recoverable.
func (m *AzureVMManager) persistWindowsDeploymentState(ctx context.Context, vmName, state string) error {
	nicFound := false
	for _, id := range []string{m.nicID(vmName), m.publicIPID(vmName)} {
		raw, err := m.get(ctx, id, networkAPIVersion)
		if errors.Is(err, errResourceNotFound) {
			continue
		}
		if err != nil {
			return err
		}
		var resource struct {
			Tags map[string]string `json:"tags"`
		}
		if err := json.Unmarshal(raw, &resource); err != nil {
			return err
		}
		if resource.Tags == nil {
			resource.Tags = map[string]string{}
		}
		resource.Tags[windowsDeploymentStateTag] = state
		body, err := json.Marshal(map[string]any{"tags": resource.Tags})
		if err != nil {
			return err
		}
		if _, err := m.request(ctx, http.MethodPatch, m.resourceURL(id, networkAPIVersion), body, http.StatusOK); err != nil {
			return err
		}
		raw, err = m.get(ctx, id, networkAPIVersion)
		if err != nil {
			return err
		}
		var observed struct {
			Tags map[string]string `json:"tags"`
		}
		if err := json.Unmarshal(raw, &observed); err != nil {
			return err
		}
		if observed.Tags[windowsDeploymentStateTag] != state {
			return fmt.Errorf("Windows deployment marker was not persisted on existing network resource")
		}
		if id == m.nicID(vmName) {
			nicFound = true
		}
	}
	if state == "pending" && !nicFound {
		return fmt.Errorf("Windows deployment requires its durable NIC marker before submission")
	}
	return nil
}

func (m *AzureVMManager) checkWindowsDeploymentMarkers(ctx context.Context, vmName string) error {
	for _, id := range []string{m.nicID(vmName), m.publicIPID(vmName)} {
		raw, err := m.get(ctx, id, networkAPIVersion)
		if errors.Is(err, errResourceNotFound) {
			continue
		}
		if err != nil {
			return err
		}
		var resource struct {
			Tags map[string]string `json:"tags"`
		}
		if err := json.Unmarshal(raw, &resource); err != nil {
			return err
		}
		switch resource.Tags[windowsDeploymentStateTag] {
		case "not-submitted", "terminal":
		default:
			return fmt.Errorf("%w: adopted Windows network resources have an uncertain deployment marker", errResourceNotFound)
		}
	}
	return nil
}

// Retain nested quota/allocation codes for the shared backoff policy without
// copying provider messages (which might contain user-supplied data) into logs.
type deploymentError struct {
	Code    string            `json:"code"`
	Details []deploymentError `json:"details"`
}

func (e deploymentError) codes() []string {
	result := []string{e.Code}
	for _, detail := range e.Details {
		result = append(result, detail.codes()...)
	}
	return result
}
