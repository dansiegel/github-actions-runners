package main

import (
    "context"
    "encoding/base64"
    "encoding/json"
    "io"
    "log/slog"
    "net/http"
    "net/http/httptest"
    "strings"
    "sync"
    "testing"
)

func TestWindowsCreateUsesKeyVaultSecureReferenceAndDeletesMetadata(t *testing.T) {
    var mu sync.Mutex
    var deployment map[string]any
    deleted := false
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request) {
        w.Header().Set("Content-Type","application/json")
        mu.Lock(); defer mu.Unlock()
        if strings.Contains(r.URL.Path,"/deployments/") {
            switch r.Method {
            case http.MethodPut:
                if err := json.NewDecoder(r.Body).Decode(&deployment); err != nil { t.Error(err) }
                w.WriteHeader(http.StatusCreated)
            case http.MethodGet:
                _,_ = io.WriteString(w,`{"properties":{"provisioningState":"Succeeded"}}`);return
            case http.MethodDelete: deleted=true
            }
        } else if strings.Contains(r.URL.Path,"/virtualMachines/") { t.Error("Windows VM bypassed secure template") }
        _,_ = io.WriteString(w,`{}`)
    }))
    defer server.Close()
    c:=validConfig(); c.OSType="Windows";c.ImageID="/images/windows";c.WindowsAdminSecret=testWindowsSecret();c.ARMEndpoint=server.URL
    manager:=&AzureVMManager{config:c,credential:fakeCredential{},httpClient:server.Client(),logger:slog.New(slog.NewTextHandler(io.Discard,nil))}
    if _,err:=manager.Create(context.Background(),"avp-windows-lp-123","jit-token");err!=nil{t.Fatal(err)}
    mu.Lock();defer mu.Unlock()
    if !deleted {t.Fatal("completed deployment metadata retained")}
    properties:=deployment["properties"].(map[string]any)
    parameters:=properties["parameters"].(map[string]any)
    password:=parameters["adminPassword"].(map[string]any)
    if password["value"] != nil {t.Fatal("password value crossed controller boundary")}
    reference:=password["reference"].(map[string]any)
    if reference["secretVersion"]!=c.WindowsAdminSecret.SecretVersion {t.Fatal("secret version not pinned")}
    template:=properties["template"].(map[string]any)
    definitions:=template["parameters"].(map[string]any)
    for _,name:=range []string{"adminPassword","customData"} {if definitions[name].(map[string]any)["type"]!="securestring" {t.Fatal("sensitive parameter not secure")}}
    resource:=template["resources"].([]any)[0].(map[string]any)
    profile:=resource["properties"].(map[string]any)["osProfile"].(map[string]any)
    if profile["adminPassword"]!="[parameters('adminPassword')]" || profile["customData"]!="[parameters('customData')]" {t.Fatal("credential embedded in template history")}
    if resource["identity"]!=nil {t.Fatal("runner received managed identity")}
    raw,_:=base64.StdEncoding.DecodeString(parameters["customData"].(map[string]any)["value"].(string))
    var data windowsBootstrapData
    if err:=json.Unmarshal(raw,&data);err!=nil{t.Fatal(err)}
    if data.SchemaVersion!=1{t.Fatal("wrong payload")}
}

func TestWindowsDeleteCancelsDeploymentBeforeDeletingVM(t *testing.T) {
    state:="Running"
    var order []string
    server:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
        w.Header().Set("Content-Type","application/json")
        if strings.Contains(r.URL.Path,"/deployments/") {
            if strings.HasSuffix(r.URL.Path,"/cancel") {order=append(order,"cancel");state="Canceled";w.WriteHeader(http.StatusNoContent);return}
            if r.Method==http.MethodGet {_,_=io.WriteString(w,`{"properties":{"provisioningState":"`+state+`"}}`);return}
            if r.Method==http.MethodDelete {order=append(order,"deployment")}
        } else if r.Method==http.MethodDelete {if state!="Canceled"{t.Error("resources deleted before cancellation")};order=append(order,"resource")}
        _,_=io.WriteString(w,`{}`)
    }))
    defer server.Close()
    c:=validConfig();c.OSType="Windows";c.ARMEndpoint=server.URL
    manager:=&AzureVMManager{config:c,credential:fakeCredential{},httpClient:server.Client(),logger:slog.New(slog.NewTextHandler(io.Discard,nil))}
    if err:=manager.Delete(context.Background(),"windows-test");err!=nil{t.Fatal(err)}
    if strings.Join(order,",")!="cancel,deployment,resource,resource,resource" {t.Fatalf("unsafe cleanup order: %v",order)}
}

func TestUnqualifiedWindowsCreatesNoResources(t *testing.T) {
    calls:=0
    server:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){calls++;w.WriteHeader(http.StatusCreated)}))
    defer server.Close()
    c:=validConfig();c.OSType="Windows";c.ARMEndpoint=server.URL
    manager:=&AzureVMManager{config:c,credential:fakeCredential{},httpClient:server.Client(),logger:slog.New(slog.NewTextHandler(io.Discard,nil))}
    if _,err:=manager.Create(context.Background(),"windows-test","jit");err==nil{t.Fatal("unqualified Windows accepted")}
    if calls!=0{t.Fatal("unqualified profile created billable network resources")}
}
