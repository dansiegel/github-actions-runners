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

func (m *AzureVMManager) deploymentID(vmName string) string {
    return fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Resources/deployments/%s", m.config.SubscriptionID, m.config.ResourceGroup, vmName)
}

func (m *AzureVMManager) createRunnerVM(ctx context.Context, vmName string, vmBody map[string]any) error {
    if m.config.OSType != "Windows" { return m.put(ctx, m.vmID(vmName), computeAPIVersion, vmBody) }
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
            "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
            "contentVersion": "1.0.0.0",
            "parameters": map[string]any{
                "adminPassword": map[string]any{"type": "securestring", "defaultValue": "[concat('Aa1!', newGuid())]"},
                "customData": map[string]any{"type": "securestring"},
            },
            "resources": []any{vmBody},
        },
    }}
    body, err := json.Marshal(deployment)
    if err != nil { return err }
    // newGuid() is evaluated by Azure for this deployment. Never re-PUT an
    // uncertain deployment: that would evaluate a fresh default credential.
    // Poll the same deterministic deployment instead; later fleet retries use
    // a new runner/resource identity after cleanup.
    _, putErr := m.requestWithRetry(ctx, http.MethodPut, m.resourceURL(m.deploymentID(vmName), deploymentAPIVersion), body, false, http.StatusOK, http.StatusCreated, http.StatusAccepted)
    if err := m.waitWindowsDeployment(ctx, vmName, false); err != nil { return errors.Join(putErr, err) }
    // Delete completed deployment metadata; this never deletes its VM resources.
    if err := m.delete(ctx, m.deploymentID(vmName), deploymentAPIVersion); err != nil && !errors.Is(err, errResourceNotFound) {
        m.logger.Warn("Windows deployment metadata cleanup deferred", "vm", vmName)
    }
    return nil
}

func (m *AzureVMManager) waitWindowsDeployment(ctx context.Context, vmName string, cleanup bool) error {
    missingReads := 0
    for {
        body, err := m.get(ctx, m.deploymentID(vmName), deploymentAPIVersion)
        if errors.Is(err, errResourceNotFound) && cleanup { return nil }
        if errors.Is(err, errResourceNotFound) && missingReads < 5 {
            // A lost PUT response can precede deployment visibility. Read back
            // the same identity; never regenerate its credential by resubmitting.
            missingReads++
            if err := sleepContext(ctx, 3*time.Second); err != nil { return err }
            continue
        }
        if err != nil { return err }
        var deployment struct { Properties struct {
            ProvisioningState string `json:"provisioningState"`
            Error deploymentError `json:"error"`
        } `json:"properties"` }
        if err := json.Unmarshal(body, &deployment); err != nil { return fmt.Errorf("decoding Windows deployment state: %w", err) }
        switch strings.ToLower(deployment.Properties.ProvisioningState) {
        case "succeeded": return nil
        case "failed", "canceled", "cancelled":
            if cleanup { return nil }
            return fmt.Errorf("Windows deployment %s (%s)", deployment.Properties.ProvisioningState, strings.Join(deployment.Properties.Error.codes(), ","))
        case "accepted", "running", "creating", "updating", "canceling", "cancelling":
        default: return fmt.Errorf("unexpected Windows deployment state %q", deployment.Properties.ProvisioningState)
        }
        if err := sleepContext(ctx, 3*time.Second); err != nil { return err }
    }
}

func (m *AzureVMManager) finishWindowsDeployment(ctx context.Context, vmName string, cancel bool) error {
    body, err := m.get(ctx, m.deploymentID(vmName), deploymentAPIVersion)
    if errors.Is(err, errResourceNotFound) { return nil }
    if err != nil { return err }
    var deployment struct { Properties struct { ProvisioningState string `json:"provisioningState"` } `json:"properties"` }
    if err := json.Unmarshal(body, &deployment); err != nil { return err }
    state := strings.ToLower(deployment.Properties.ProvisioningState)
    if cancel && state != "succeeded" && state != "failed" && state != "canceled" && state != "cancelled" {
        if _, err := m.request(ctx, http.MethodPost, m.resourceURL(m.deploymentID(vmName)+"/cancel", deploymentAPIVersion), nil, http.StatusOK, http.StatusAccepted, http.StatusNoContent); err != nil { return err }
    }
    if err := m.waitWindowsDeployment(ctx, vmName, true); err != nil { return err }
    if err := m.delete(ctx, m.deploymentID(vmName), deploymentAPIVersion); err != nil && !errors.Is(err, errResourceNotFound) { return err }
    return nil
}

// Retain nested quota/allocation codes for the shared backoff policy without
// copying provider messages (which might contain user-supplied data) into logs.
type deploymentError struct {
    Code string `json:"code"`
    Details []deploymentError `json:"details"`
}
func (e deploymentError) codes() []string {
    result := []string{e.Code}
    for _, detail := range e.Details { result = append(result, detail.codes()...) }
    return result
}
