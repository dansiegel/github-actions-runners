package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
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
