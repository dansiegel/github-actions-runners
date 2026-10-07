package main

import "testing"

func TestWindowsSupportedProfileCombinations(t *testing.T) {
	for _, profile := range []struct{ label, sku, tier string }{
		{"m", "Standard_D2s_v5", "P10"}, {"mp", "Standard_D2s_v5", "P20"},
		{"l", "Standard_D4s_v5", "P10"}, {"lp", "Standard_D4s_v5", "P20"},
		{"xl", "Standard_D8s_v5", "P10"}, {"xlp", "Standard_D8s_v5", "P20"},
	} {
		t.Run(profile.label, func(t *testing.T) {
			c := validConfig()
			c.OSType, c.ImageID = "Windows", "/images/windows"
			c.VMSize, c.OSDiskTier = profile.sku, profile.tier
			c.ScaleSetName = "avp-windows-" + profile.label
			c.Labels = []string{c.ScaleSetName, "Windows"}
			if err := c.Validate(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestWindowsUnsupportedProfilesFailConfiguration(t *testing.T) {
	for _, tc := range []struct {
		name, sku, tier, label, os string
		size                       int
	}{
		{"small SKU", "Standard_F1als_v7", "P10", "custom", "Windows", 128},
		{"unqualified SKU", "Standard_D16s_v5", "P20", "custom", "Windows", 128},
		{"P15", "Standard_D4s_v5", "P15", "custom", "Windows", 128},
		{"P30", "Standard_D4s_v5", "P30", "custom", "Windows", 128},
		{"implicit P15", "Standard_D4s_v5", "", "custom", "Windows", 256},
		{"excluded S label", "Standard_D4s_v5", "P10", "avp-windows-s", "Windows", 128},
		{"excluded SP alias", "Standard_D4s_v5", "P20", "AVP-WINDOWS-SP", "Windows", 128},
		{"wrong CPU", "Standard_D2s_v5", "P20", "avp-windows-lp", "Windows", 128},
		{"wrong disk", "Standard_D4s_v5", "P10", "avp-windows-lp", "Windows", 128},
		{"wrong OS", "Standard_D4s_v5", "P20", "avp-windows-lp", "Linux", 128},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := validConfig()
			c.OSType, c.ImageID = tc.os, "/images/windows"
			c.VMSize, c.OSDiskTier, c.OSDiskSizeGB = tc.sku, tc.tier, tc.size
			c.Labels = []string{tc.label}
			if err := c.Validate(); err == nil {
				t.Fatal("unsupported Windows combination accepted")
			}
			// Disabled placeholders must fail too; keep a valid Linux pool enabled.
			disabled := false
			c = validConfig()
			c.Pools = []RunnerPool{{Name: "linux", VMSize: "Standard_D4s_v5"}, {Name: tc.label, VMSize: tc.sku, OSDiskTier: tc.tier, OSType: tc.os, Enabled: &disabled}}
			c.OSDiskSizeGB = tc.size
			if err := c.Validate(); err == nil {
				t.Fatal("unsupported disabled Windows placeholder accepted")
			}
		})
	}
}

func TestWindowsProfileNameCannotHideBehindCustomLabel(t *testing.T) {
	c := validConfig()
	c.OSType, c.ImageID, c.ScaleSetName = "Windows", "/images/windows", "avp-windows-s"
	c.Labels = []string{"custom"}
	if c.Validate() == nil {
		t.Fatal("unsupported Windows pool name accepted")
	}
}
