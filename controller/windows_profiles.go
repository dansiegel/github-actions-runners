package main

import (
	"fmt"
	"strings"
)

// Windows qualification is limited to the published M/MP, L/LP and XL/XLP
// hardware/disk combinations. A syntactically valid Azure SKU is not sufficient.
// Validate disabled placeholders too, before any listener or resource is created.
func (c Config) validateWindowsProfile() error {
	size, err := c.EffectiveOSDiskSizeGB()
	if err != nil {
		return err
	}
	if c.OSType == "Windows" {
		switch c.VMSize {
		case "Standard_D2s_v5", "Standard_D4s_v5", "Standard_D8s_v5":
		default:
			return fmt.Errorf("unsupported Windows VM size %q: supported profiles require Standard_D2s_v5, Standard_D4s_v5, or Standard_D8s_v5; Windows S/SP are excluded", c.VMSize)
		}
		if (c.OSDiskTier != "" && c.OSDiskTier != "P10" && c.OSDiskTier != "P20") || (size != 128 && size != 512) {
			return fmt.Errorf("unsupported Windows OS disk: supported profiles require P10/128 GiB or P20/512 GiB")
		}
	}
	profiles := map[string]struct {
		sku  string
		size int
	}{
		"m": {"Standard_D2s_v5", 128}, "mp": {"Standard_D2s_v5", 512},
		"l": {"Standard_D4s_v5", 128}, "lp": {"Standard_D4s_v5", 512},
		"xl": {"Standard_D8s_v5", 128}, "xlp": {"Standard_D8s_v5", 512},
	}
	for _, value := range append([]string{c.ScaleSetName}, c.Labels...) {
		label := strings.ToLower(strings.TrimSpace(value))
		if !strings.HasPrefix(label, "avp-windows-") {
			continue
		}
		profile, supported := profiles[strings.TrimPrefix(label, "avp-windows-")]
		if !supported {
			return fmt.Errorf("unsupported Windows profile %q: use M/MP, L/LP, or XL/XLP", value)
		}
		if c.OSType != "Windows" || c.VMSize != profile.sku || size != profile.size {
			return fmt.Errorf("Windows profile %q requires Windows, %s and a %d-GiB OS disk", value, profile.sku, profile.size)
		}
	}
	return nil
}
