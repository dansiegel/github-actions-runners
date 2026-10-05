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

func TestWindowsCreateGeneratesCredentialInsideAzureAndDeletesMetadata(t *testing.T) {
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
    c:=validConfig(); c.OSType="Windows";c.ImageID="/images/windows";c.ARMEndpoint=server.URL
    manager:=&AzureVMManager{config:c,credential:fakeCredential{},httpClient:server.Client(),logger:slog.New(slog.NewTextHandler(io.Discard,nil))}
    if _,err:=manager.Create(context.Background(),"avp-windows-lp-123","jit-token");err!=nil{t.Fatal(err)}
    mu.Lock();defer mu.Unlock()
    if !deleted {t.Fatal("completed deployment metadata retained")}
    properties:=deployment["properties"].(map[string]any)
    parameters:=properties["parameters"].(map[string]any)
    if parameters["adminPassword"] != nil {t.Fatal("controller supplied an administrator credential")}
    template:=properties["template"].(map[string]any)
    definitions:=template["parameters"].(map[string]any)
    for _,name:=range []string{"adminPassword","customData"} {if definitions[name].(map[string]any)["type"]!="securestring" {t.Fatal("sensitive parameter not secure")}}
    if definitions["adminPassword"].(map[string]any)["defaultValue"] != "[concat('Aa1!', newGuid())]" {t.Fatal("credential must be generated inside Azure with password complexity")}
    if template["outputs"] != nil {t.Fatal("deployment must not expose credential outputs")}
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

func TestWindowsUncertainPutPollsWithoutRegeneratingCredential(t *testing.T) {
    puts := 0
    server:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
        w.Header().Set("Content-Type","application/json")
        if strings.Contains(r.URL.Path,"/deployments/") {
            if r.Method==http.MethodPut {puts++;w.WriteHeader(http.StatusInternalServerError);_,_=io.WriteString(w,`{"error":{"code":"InternalServerError"}}`);return}
            if r.Method==http.MethodGet {_,_=io.WriteString(w,`{"properties":{"provisioningState":"Succeeded"}}`);return}
        }
        _,_=io.WriteString(w,`{}`)
    }))
    defer server.Close()
    c:=validConfig();c.OSType="Windows";c.ImageID="/images/windows";c.ARMEndpoint=server.URL
    manager:=&AzureVMManager{config:c,credential:fakeCredential{},httpClient:server.Client(),logger:slog.New(slog.NewTextHandler(io.Discard,nil))}
    if _,err:=manager.Create(context.Background(),"windows-unique","jit");err!=nil{t.Fatal(err)}
    if puts!=1{t.Fatalf("deployment PUT occurred %d times; credential default can be reevaluated",puts)}
}
