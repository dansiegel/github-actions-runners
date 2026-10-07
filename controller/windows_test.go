package main

import (
    "encoding/base64"
    "encoding/json"
    "strings"
    "os"
    "testing"
)

func TestWindowsProfilesRequireExplicitImage(t *testing.T) {
    c := validConfig()
    c.ImageID = "/images/linux"
    c.WindowsRunnerSHA256 = defaultWindowsRunnerSHA256
    c.Pools = []RunnerPool{{Name:"linux-profile", VMSize:"Standard_D4s_v5"}, {Name:"windows-profile", VMSize:"Standard_D4s_v5", OSType:"Windows"}}
    if c.Validate() == nil { t.Fatal("Windows inherited Linux image") }
    c.Pools[1].ImageID = "/images/windows"
    pools, err := c.PoolConfigs()
    if err != nil { t.Fatal(err) }
    if pools[0].OSType != "Linux" || pools[0].ImageID != c.ImageID || pools[0].RunnerSHA256 != c.RunnerSHA256 || pools[1].OSType != "Windows" || pools[1].ImageID != "/images/windows" || pools[1].RunnerSHA256 != defaultWindowsRunnerSHA256 { t.Fatal("OS configuration leaked across profiles") }
    pools[1].VMSSHPublicKey = ""
    if err := pools[1].Validate(); err != nil { t.Fatal("Windows unexpectedly requires Linux SSH",err) }
    disabled := false
    c.Pools[1].Enabled = &disabled
    c.Pools[1].ImageID = ""
    if err := c.Validate(); err != nil { t.Fatal("disabled Windows placeholder rejected",err) }
}

func TestWindowsRejectsPlaintextPasswordsAndInvalidSchema(t *testing.T) {
    for _, raw := range []string{`[{"name":"win","vmSize":"Standard_D4s_v5","osType":null}]`, `[{"name":"win","vmSize":"Standard_D4s_v5","osType":"windows"}]`, `[{"name":"win","vmSize":"Standard_D4s_v5","adminPassword":"not-accepted"}]`} {
        c := validConfig()
        if json.Unmarshal([]byte(raw), &c.Pools) == nil && c.Validate() == nil { t.Fatal("invalid OS/password field accepted") }
    }
}

func TestWindowsBootstrapPayloadIsDataAndUsesSecureParameter(t *testing.T) {
    c := validConfig()
    c.OSType = "Windows"
    c.ImageID = "/images/windows"
    c.RunnerSHA256 = defaultWindowsRunnerSHA256
    profile, err := renderOSProfile(c,"avp-windows-lp-unique-one","one-time-jit")
    if err != nil { t.Fatal(err) }
    if profile["linuxConfiguration"] != nil || profile["adminPassword"] != "[parameters('adminPassword')]" { t.Fatal("Windows profile includes Linux setup or a password value") }
    name := profile["computerName"].(string)
    if len(name) > 15 { t.Fatal("Windows computer name exceeds NetBIOS limit") }
    other,_ := renderOSProfile(c,"avp-windows-lp-unique-two","one-time-jit")
    if other["computerName"] == name { t.Fatal("long label caused hostname collision") }
    payload,err := base64.StdEncoding.DecodeString(profile["customData"].(string))
    if err != nil { t.Fatal(err) }
    if strings.Contains(string(payload), "one-time-jit") { t.Fatal("JIT envelope missing") }
    var data windowsBootstrapData
    if err := json.Unmarshal(payload,&data); err != nil { t.Fatal(err) }
    decoded,_ := base64.StdEncoding.DecodeString(data.JITConfig)
    if string(decoded) != "one-time-jit" || data.SchemaVersion != 1 || data.RunnerSHA256 != c.RunnerSHA256 { t.Fatal("bootstrap contract mismatch") }
    if _,err := renderOSProfile(c,"name",strings.Repeat("x",65536)); err == nil { t.Fatal("oversize payload accepted") }
}

func TestWindowsCatalogIsDisabledAndMatchesLinuxHardware(t *testing.T) {
    // The existing example test validates the six enabled Linux profiles.
    // Check that each Windows counterpart requires independent qualification.
    c := validConfig()
    data,err := os.ReadFile("../runner-pools.example.json")
    if err != nil { t.Fatal(err) }
    if err := json.Unmarshal(data,&c.Pools); err != nil { t.Fatal(err) }
    windowsCount := 0
    for _, pool := range c.Pools {
        if pool.OSType == "Windows" { windowsCount++ }
        for _, label := range pool.Labels {
            if label == "avp-windows-s" || label == "avp-windows-sp" { t.Fatal("excluded 2-GiB Windows profile remains in the catalog") }
        }
    }
    if windowsCount != 6 { t.Fatalf("Windows catalog count = %d, want 6", windowsCount) }
    for _, suffix := range []string{"m","mp","l","lp","xl","xlp"} {
        var linux, windows *RunnerPool
        for i := range c.Pools {
            p := &c.Pools[i]
            for _,label := range p.Labels { if label == "avp-linux-"+suffix {linux=p}; if label == "avp-windows-"+suffix {windows=p} }
        }
        if linux == nil || windows == nil || windows.OSType != "Windows" || windows.Enabled == nil || *windows.Enabled || windows.VMSize != linux.VMSize || windows.OSDiskTier != linux.OSDiskTier || windows.MaxRunners != 0 { t.Fatalf("invalid Windows counterpart %s", suffix) }
    }
}

func TestOperatingSystemTagsPreserveUniqueProfileRouting(t *testing.T) {
    c := validConfig()
    c.Pools = []RunnerPool{
        {Name:"legacy", VMSize:"Standard_D4s_v5", Labels:[]string{"avp-linux","avp-linux-l"}},
        {Name:"medium", VMSize:"Standard_D2s_v5", Labels:[]string{"avp-linux-m","linux"}},
        {Name:"windows", VMSize:"Standard_D4s_v5", OSDiskTier:"P20", OSType:"Windows", ImageID:"/images/windows", Labels:[]string{"avp-windows-lp","WINDOWS"}},
    }
    pools,err := c.PoolConfigs()
    if err != nil {t.Fatal(err)}
    want := [][]string{{"avp-linux","avp-linux-l","Linux"},{"avp-linux-m","Linux"},{"avp-windows-lp","Windows"}}
    for i,pool := range pools {
        labels := pool.ScaleSetLabels()
        if len(labels)!=len(want[i]) {t.Fatalf("pool %s labels: %v",pool.ScaleSetName,labels)}
        for j,label := range labels {if label.Name!=want[i][j] {t.Fatalf("pool %s label %d: %s",pool.ScaleSetName,j,label.Name)}}
    }
    // OS tags may repeat across matching pools, but profile aliases cannot.
    c.Pools[0].Labels = append(c.Pools[0].Labels,"Linux")
    if err:=c.Validate();err!=nil{t.Fatal(err)}
    c.Pools[1].Labels = []string{"avp-linux","Linux"}
    if c.Validate()==nil{t.Fatal("duplicate profile label accepted")}
    for _,labels := range [][]string{{"Windows","profile"},{"macOS","profile"},{"Linux"}} {
        c:=validConfig();c.Labels=labels
        if c.Validate()==nil{t.Fatalf("invalid Linux routing labels accepted: %v",labels)}
    }
}
