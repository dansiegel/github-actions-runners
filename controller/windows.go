package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"regexp"
)

// Windows images contain the bootstrap task. Custom data is data, never a
// downloaded script; Windows does not execute Azure custom data automatically.
type windowsBootstrapData struct {
	SchemaVersion int    `json:"schemaVersion"`
	RunnerVersion string `json:"runnerVersion"`
	RunnerSHA256  string `json:"runnerSHA256"`
	JITConfig     string `json:"jitConfig"`
}

func renderOSProfile(c Config, runnerName, jit string) (map[string]any, error) {
	if c.OSType == "" || c.OSType == "Linux" {
		return map[string]any{
			"computerName": takeString(azureResourceName(runnerName), 63),
			"adminUsername": c.VMAdminUser,
			"customData": base64.StdEncoding.EncodeToString([]byte(renderCloudInit(c, jit))),
			"linuxConfiguration": map[string]any{
				"disablePasswordAuthentication": true,
				"ssh": map[string]any{"publicKeys": []any{map[string]any{
					"path": fmt.Sprintf("/home/%s/.ssh/authorized_keys", c.VMAdminUser),
					"keyData": c.VMSSHPublicKey,
				}}},
			},
		}, nil
	}
	if c.OSType != "Windows" || strings.TrimSpace(c.ImageID) == "" {
		return nil, fmt.Errorf("Windows provisioning requires osType Windows and a qualified imageId")
	}
	if c.WindowsAdminSecret == nil { return nil, fmt.Errorf("Windows provisioning requires a Key Vault administrator secret reference") }
	if err := c.WindowsAdminSecret.Validate(); err != nil { return nil, err }
	data, err := json.Marshal(windowsBootstrapData{
		SchemaVersion: 1, RunnerVersion: c.RunnerVersion, RunnerSHA256: c.RunnerSHA256,
		JITConfig: base64.StdEncoding.EncodeToString([]byte(jit)),
	})
	if err != nil { return nil, err }
	if len(data) > 64*1024 { return nil, fmt.Errorf("Windows custom data exceeds Azure's 64 KiB limit") }
	// NetBIOS allows 15 characters; truncating the logical label would collide.
	digest := sha256.Sum256([]byte(runnerName))
	return map[string]any{
		"computerName": "gha-" + hex.EncodeToString(digest[:])[:11],
		"adminUsername": c.VMAdminUser,
		// This is an ARM secure-parameter expression, never a password value.
		"adminPassword": "[parameters('adminPassword')]",
		"customData": base64.StdEncoding.EncodeToString(data),
		"windowsConfiguration": map[string]any{
			"provisionVMAgent": true,
			"enableAutomaticUpdates": false,
			"patchSettings": map[string]any{"patchMode": "Manual"},
		},
	}, nil
}

// Only resource identifiers cross the controller boundary. Azure resolves the
// user-provisioned secret directly; this process cannot read its value.
type WindowsAdminSecret struct {
    KeyVaultID string `json:"keyVaultId"`
    SecretName string `json:"secretName"`
    SecretVersion string `json:"secretVersion"`
}

func (s *WindowsAdminSecret) UnmarshalJSON(data []byte) error {
    type secretJSON WindowsAdminSecret
    var decoded secretJSON
    decoder := json.NewDecoder(strings.NewReader(string(data)))
    decoder.DisallowUnknownFields()
    if err := decoder.Decode(&decoded); err != nil { return err }
    var fields map[string]json.RawMessage
    if err := json.Unmarshal(data, &fields); err != nil { return err }
    for key, value := range fields {
        if key != "keyVaultId" && key != "secretName" && key != "secretVersion" { return fmt.Errorf("unknown Windows secret reference field %q", key) }
        if string(value) == "null" { return fmt.Errorf("Windows secret reference %s cannot be null", key) }
    }
    *s = WindowsAdminSecret(decoded)
    return s.Validate()
}

func (s WindowsAdminSecret) Validate() error {
    if !regexp.MustCompile(`^/subscriptions/[A-Za-z0-9-]+/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft.KeyVault/vaults/[A-Za-z0-9-]+$`).MatchString(s.KeyVaultID) || !regexp.MustCompile(`^[A-Za-z0-9-]{1,127}$`).MatchString(s.SecretName) || !regexp.MustCompile(`^[a-fA-F0-9]{32}$`).MatchString(s.SecretVersion) {
        return fmt.Errorf("windowsAdminSecret requires a Key Vault resource ID, secret name, and pinned 32-hex secret version")
    }
    return nil
}
