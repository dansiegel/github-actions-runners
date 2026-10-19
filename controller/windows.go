package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
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
			"computerName":  takeString(azureResourceName(runnerName), 63),
			"adminUsername": c.VMAdminUser,
			"customData":    base64.StdEncoding.EncodeToString([]byte(renderCloudInit(c, jit))),
			"linuxConfiguration": map[string]any{
				"disablePasswordAuthentication": true,
				"ssh": map[string]any{"publicKeys": []any{map[string]any{
					"path":    fmt.Sprintf("/home/%s/.ssh/authorized_keys", c.VMAdminUser),
					"keyData": c.VMSSHPublicKey,
				}}},
			},
		}, nil
	}
	if c.OSType != "Windows" || strings.TrimSpace(c.ImageID) == "" {
		return nil, fmt.Errorf("Windows provisioning requires osType Windows and a qualified imageId")
	}
	if err := validateWindowsInputs(c); err != nil {
		return nil, err
	}
	data, err := json.Marshal(windowsBootstrapData{
		SchemaVersion: 1, RunnerVersion: c.RunnerVersion, RunnerSHA256: c.RunnerSHA256,
		JITConfig: base64.StdEncoding.EncodeToString([]byte(jit)),
	})
	if err != nil {
		return nil, err
	}
	if len(data) > 64*1024 {
		return nil, fmt.Errorf("Windows custom data exceeds Azure's 64 KiB limit")
	}
	// NetBIOS allows 15 characters; truncating the logical label would collide.
	digest := sha256.Sum256([]byte(runnerName))
	return map[string]any{
		"computerName":  "gha-" + hex.EncodeToString(digest[:])[:11],
		"adminUsername": c.VMAdminUser,
		// This is an ARM secure-parameter expression, never a password value.
		"adminPassword": "[parameters('adminPassword')]",
		"customData":    base64.StdEncoding.EncodeToString(data),
		"windowsConfiguration": map[string]any{
			"provisionVMAgent":       true,
			"enableAutomaticUpdates": false,
			"patchSettings":          map[string]any{"patchMode": "Manual"},
		},
	}, nil
}

// Apply Windows constraints before any NIC/IP allocation, including direct
// provider calls. Linux installations can retain their existing administrator.
func validateWindowsInputs(c Config) error {
	user := c.VMAdminUser
	reserved := ",1,123,a,actuser,adm,admin,admin1,admin2,administrator,aspnet,backup,console,david,guest,john,owner,root,server,sql,support_388945a0,support,sys,test,test1,test2,test3,user,user1,user2,"
	if !regexp.MustCompile(`^[A-Za-z0-9_-]{1,20}$`).MatchString(user) || strings.Contains(reserved, ","+strings.ToLower(user)+",") {
		return fmt.Errorf("RUNNER_ADMIN_USERNAME must be a nonreserved Windows account name of 1 through 20 letters, numbers, underscores or hyphens")
	}
	if !regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(c.RunnerSHA256) {
		return fmt.Errorf("Windows runner SHA256 must contain exactly 64 lowercase hexadecimal characters")
	}
	return nil
}
