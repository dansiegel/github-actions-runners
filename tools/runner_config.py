#!/usr/bin/env python
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any

import yaml

DEFAULT_TOTAL_CAP = 20
DEFAULT_REGION = "eastus"
DEFAULT_RG = "gha-runners-dev"
DEFAULT_VM_SIZE = "Standard_D2s_v5"
DEFAULT_IMAGE = "Ubuntu2404"
VM_SIZE_ARCH_PATTERNS = {
    "x64": (r"^Standard_D[0-9]+s?_v5$", r"^Standard_D[0-9]+ds_v5$"),
    "arm64": (r"^Standard_D[0-9]+ps_v5$", r"^Standard_D[0-9]+pds_v5$", r"^Standard_D[0-9]+pls_v5$", r"^Standard_D[0-9]+plds_v5$"),
}
VM_ARCH_DOCS = {
    "x64": "Azure x64 Dsv5/Ddsv5 VM sizes, for example Standard_D2s_v5",
    "arm64": "Azure Arm64 Dpsv5/Dpdsv5/Dplsv5/Dpldsv5 VM sizes, for example Standard_D2ps_v5",
}
DEFAULT_ORCHESTRATION = "Uniform"
DEFAULT_UPGRADE_POLICY = "automatic"
SPEND_CONFIRMATION = "I_ACCEPT_AZURE_SPEND"
REQUIRED_BASE_LABELS = ["self-hosted", "azure"]
SECRET_PATTERNS = [
    re.compile(r"gh[pousr]_[A-Za-z0-9_]{20,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"(?i)(client_secret|password|token)\s*[:=]\s*['\"]?[A-Za-z0-9_./+=-]{16,}"),
]
ENV_REF = re.compile(r"^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$")
SUPPORTED_RUNNER_ASSETS = {("linux", "x64"), ("linux", "arm64")}
DEFAULT_RUNNER_RELEASE = {
    "version": "2.335.1",
    "sha256": {
        "linux-x64": "4ef2f25285f0ae4477f1fe1e346db76d2f3ebf03824e2ddd1973a2819bf6c8cf",
        "linux-arm64": "6d1e85bfd1a506a8b17c1f1b9b57dba458ffed90898799aaa9f599520b0d9207",
    },
}
DEFAULT_SHARED_PACKAGE_CACHE = {
    "enabled": True,
    "root": "/mnt/actions-cache/packages",
    "maxSizeGb": 20,
    "pruneAfterDays": 14,
    "ownership": "actions-runner:actions-runner",
    "packageManagers": ["apt", "npm", "nuget", "pip", "cargo", "go"],
}
SUPPORTED_PACKAGE_MANAGERS = {"apt", "npm", "nuget", "pip", "cargo", "go"}
SUPPORTED_ACCOUNT_VISIBILITIES = {"private", "public", "untrusted"}



class ConfigError(Exception):
    pass


def load_config(path: str | Path) -> dict[str, Any]:
    text = Path(path).read_text(encoding="utf-8")
    for pattern in SECRET_PATTERNS:
        if pattern.search(text):
            raise ConfigError("config contains a secret-looking literal; use env, command, Key Vault, or GitHub App token source")
    data = yaml.safe_load(text) or {}
    if not isinstance(data, dict):
        raise ConfigError("config root must be an object")
    return data


def get_path(d: dict[str, Any], path: list[str], default: Any = None) -> Any:
    cur: Any = d
    for part in path:
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def resolve_env_ref(value: Any) -> Any:
    if isinstance(value, str):
        match = ENV_REF.match(value)
        if match:
            return os.environ.get(match.group(1), "")
    return value


def require_resolved(value: Any, name: str) -> str:
    resolved = resolve_env_ref(value)
    if not isinstance(resolved, str) or not resolved.strip() or ENV_REF.match(str(resolved or "")):
        raise ConfigError(f"{name} must be configured and resolvable before live Azure mutation")
    return resolved.strip()


def sanitize_name(value: str, max_len: int = 50) -> str:
    value = re.sub(r"[^a-zA-Z0-9-]", "-", value).strip("-").lower()
    value = re.sub(r"-+", "-", value)
    return (value or "runner")[:max_len].strip("-") or "runner"


def ensure_labels(pool: dict[str, Any]) -> list[str]:
    labels = [str(x).lower() for x in pool.get("labels", [])]
    required = REQUIRED_BASE_LABELS + [str(pool.get("os", "linux")).lower(), str(pool.get("arch", "x64")).lower(), str(pool["name"]).lower()]
    for label in required:
        if label and label not in labels:
            labels.append(label)
    return labels


def reviewed_public_visibility_opt_in(cfg: dict[str, Any]) -> bool:
    opt_in = cfg.get("publicVisibilityOptIn") or {}
    return bool(opt_in.get("allowPublicVisibility") is True and opt_in.get("reviewedBy") and opt_in.get("reviewedAt"))


def reviewed_public_shared_cache_opt_in(cfg: dict[str, Any]) -> bool:
    opt_in = cfg.get("publicVisibilityOptIn") or {}
    cache_review = opt_in.get("sharedPackageCacheRisk") or {}
    if not isinstance(cache_review, dict):
        return False
    return bool(
        cache_review.get("allowSharedPackageCache") is True
        and cache_review.get("reviewedBy")
        and cache_review.get("reviewedAt")
        and cache_review.get("reason")
    )


def public_or_untrusted_accounts(accounts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [account for account in accounts if str(account.get("visibility", "private")).lower() in ("public", "untrusted")]


def normalize_account_visibility(account: dict[str, Any], index: int) -> None:
    visibility = str(account.get("visibility", "private")).lower()
    if visibility not in SUPPORTED_ACCOUNT_VISIBILITIES:
        owner = account.get("owner", index)
        allowed = ", ".join(sorted(SUPPORTED_ACCOUNT_VISIBILITIES))
        raise ConfigError(f"accounts[{owner}].visibility must be one of {allowed}; got {visibility}")
    account["visibility"] = visibility


def assert_private_first(cfg: dict[str, Any], accounts: list[dict[str, Any]]) -> None:
    defaults = cfg.setdefault("defaults", {})
    defaults.setdefault("privateFirst", True)
    reviewed_public = reviewed_public_visibility_opt_in(cfg)
    for ai, account in enumerate(accounts):
        visibility = account.get("visibility", "private")
        if visibility == "public" and not reviewed_public:
            owner = account.get("owner", ai)
            raise ConfigError(f"accounts[{owner}].visibility public is not allowed without reviewed publicVisibilityOptIn")
        if defaults.get("privateFirst") is not True and not reviewed_public:
            raise ConfigError("defaults.privateFirst must remain true unless reviewed publicVisibilityOptIn is present")


def assert_shared_package_cache_trust_boundary(cfg: dict[str, Any], accounts: list[dict[str, Any]]) -> None:
    cache = cfg["defaults"]["sharedPackageCache"]
    if not cache.get("enabled", True):
        return
    untrusted = public_or_untrusted_accounts(accounts)
    if not untrusted:
        return
    if reviewed_public_shared_cache_opt_in(cfg):
        cache["publicUntrustedRiskAccepted"] = True
        return
    owners = ", ".join(str(account.get("owner", "<unknown>")) for account in untrusted)
    raise ConfigError(
        "defaults.sharedPackageCache.enabled cannot remain true for public/untrusted accounts "
        f"({owners}) without publicVisibilityOptIn.sharedPackageCacheRisk reviewed acceptance"
    )


def normalize_token_provider(provider: dict[str, Any] | None) -> dict[str, Any]:
    if not isinstance(provider, dict):
        raise ConfigError("github tokenProvider is required; use a command, env, or keyVault reference, not a committed token")
    ptype = provider.get("type")
    if ptype not in ("command", "env", "keyVault"):
        raise ConfigError("github tokenProvider.type must be command, env, or keyVault")
    if ptype == "command":
        if not provider.get("command"):
            raise ConfigError("github tokenProvider.command is required")
        source = provider.get("vmCredentialSource")
        if source is not None:
            validate_vm_credential_source(source)
    if ptype == "env" and not provider.get("env"):
        raise ConfigError("github tokenProvider.env is required")
    if ptype == "keyVault" and not (provider.get("vault") and provider.get("secretName")):
        raise ConfigError("github tokenProvider.keyVault requires vault and secretName")
    return provider


def validate_vm_credential_source(source: Any) -> None:
    if not isinstance(source, dict):
        raise ConfigError("github tokenProvider.vmCredentialSource must be an object")
    if source.get("type") != "managedIdentityGitHubApp":
        raise ConfigError("github tokenProvider.vmCredentialSource.type must be managedIdentityGitHubApp")
    required = [
        "keyVaultName",
        "appIdSecretName",
        "privateKeySecretName",
        "installationIdSecretName",
    ]
    missing = [name for name in required if not source.get(name)]
    if missing:
        raise ConfigError("github tokenProvider.vmCredentialSource missing required fields: " + ", ".join(missing))


def vm_credential_environment(source: dict[str, Any]) -> dict[str, str]:
    def vm_value(value: Any) -> str:
        resolved = resolve_env_ref(value)
        if isinstance(resolved, str) and resolved.strip():
            return resolved.strip()
        return str(value)

    env = {
        "AZURE_KEY_VAULT_NAME": vm_value(source["keyVaultName"]),
        "GITHUB_APP_ID_SECRET_NAME": vm_value(source["appIdSecretName"]),
        "GITHUB_APP_PRIVATE_KEY_SECRET_NAME": vm_value(source["privateKeySecretName"]),
        "GITHUB_APP_INSTALLATION_ID_SECRET_NAME": vm_value(source["installationIdSecretName"]),
    }
    if source.get("managedIdentityClientId"):
        env["AZURE_CLIENT_ID"] = vm_value(source["managedIdentityClientId"])
    return env


def validate_vm_credential_source_for_live_apply(source: dict[str, Any], binding_name: str) -> dict[str, str]:
    validate_vm_credential_source(source)
    env = vm_credential_environment(source)
    resolved_env: dict[str, str] = {}
    for name, value in env.items():
        resolved_env[name] = require_resolved(value, f"token provider {binding_name} vmCredentialSource.{name}")
    return resolved_env


def azure_vm_size_matches_arch(vm_size: str, arch: str) -> bool:
    return any(re.fullmatch(pattern, vm_size) for pattern in VM_SIZE_ARCH_PATTERNS.get(arch, ()))


def validate_pool_azure_compatibility(pool: dict[str, Any]) -> None:
    name = pool.get("name", "<unknown>")
    arch = str(pool.get("arch", "x64")).lower()
    vm_size = str(pool.get("azure", {}).get("vmSize", DEFAULT_VM_SIZE))
    if not azure_vm_size_matches_arch(vm_size, arch):
        expected = VM_ARCH_DOCS.get(arch, "a VM size matching the runner architecture")
        raise ConfigError(f"pool {name} arch {arch} requires {expected}; got {vm_size}")


def normalize_shared_package_cache(defaults: dict[str, Any]) -> dict[str, Any]:
    raw = defaults.get("sharedPackageCache")
    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise ConfigError("defaults.sharedPackageCache must be an object")
    cache = deepcopy(DEFAULT_SHARED_PACKAGE_CACHE)
    cache.update(raw)
    cache["enabled"] = bool(cache.get("enabled", True))
    root_path = str(cache.get("root", "")).strip()
    if not root_path.startswith("/"):
        raise ConfigError("defaults.sharedPackageCache.root must be an absolute Linux path")
    if root_path in ("/", "/tmp", "/var", "/home"):
        raise ConfigError("defaults.sharedPackageCache.root must be a dedicated cache path")
    cache["root"] = root_path.rstrip("/")
    cache["maxSizeGb"] = int(cache.get("maxSizeGb", 20))
    cache["pruneAfterDays"] = int(cache.get("pruneAfterDays", 14))
    if cache["maxSizeGb"] < 1:
        raise ConfigError("defaults.sharedPackageCache.maxSizeGb must be >= 1")
    if cache["pruneAfterDays"] < 1:
        raise ConfigError("defaults.sharedPackageCache.pruneAfterDays must be >= 1")
    managers = cache.get("packageManagers", [])
    if not isinstance(managers, list) or not managers:
        raise ConfigError("defaults.sharedPackageCache.packageManagers must be a non-empty list")
    normalized = []
    for manager in managers:
        name = str(manager).lower()
        if name not in SUPPORTED_PACKAGE_MANAGERS:
            raise ConfigError(f"unsupported shared package cache manager: {name}")
        if name not in normalized:
            normalized.append(name)
    cache["packageManagers"] = normalized
    ownership = str(cache.get("ownership", "actions-runner:actions-runner"))
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*:[a-z_][a-z0-9_-]*", ownership):
        raise ConfigError("defaults.sharedPackageCache.ownership must be user:group")
    cache["ownership"] = ownership
    defaults["sharedPackageCache"] = cache
    return cache


def normalize_runner_release(github: dict[str, Any]) -> dict[str, Any]:
    release = deepcopy(github.get("runnerRelease") or DEFAULT_RUNNER_RELEASE)
    version = str(release.get("version", "")).removeprefix("v")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ConfigError("defaults.github.runnerRelease.version must be a pinned semantic version like 2.335.1")
    checksums = release.get("sha256")
    if not isinstance(checksums, dict):
        raise ConfigError("defaults.github.runnerRelease.sha256 is required")
    normalized_checksums: dict[str, str] = {}
    for os_name, arch in sorted(SUPPORTED_RUNNER_ASSETS):
        key = f"{os_name}-{arch}"
        value = str(checksums.get(key, "")).lower()
        if not re.fullmatch(r"[a-f0-9]{64}", value):
            raise ConfigError(f"defaults.github.runnerRelease.sha256.{key} must be a pinned 64-character sha256")
        normalized_checksums[key] = value
    return {"version": version, "sha256": normalized_checksums}


def runner_asset_metadata(pool: dict[str, Any], github: dict[str, Any]) -> dict[str, str]:
    os_name = str(pool.get("os", "linux")).lower()
    arch = str(pool.get("arch", "x64")).lower()
    if (os_name, arch) not in SUPPORTED_RUNNER_ASSETS:
        raise ConfigError(f"pool {pool.get('name', '<unknown>')} uses unsupported runner asset {os_name}/{arch}")
    release = github["runnerRelease"]
    version = release["version"]
    checksum_key = f"{os_name}-{arch}"
    asset_name = f"actions-runner-{os_name}-{arch}-{version}.tar.gz"
    return {
        "runnerOs": os_name,
        "runnerArch": arch,
        "runnerAssetName": asset_name,
        "runnerDownloadUrl": f"https://github.com/actions/runner/releases/download/v{version}/{asset_name}",
        "runnerSha256": release["sha256"][checksum_key],
    }


def target_registration(account: dict[str, Any], item: dict[str, Any], default_provider: dict[str, Any]) -> dict[str, Any]:
    registration = deepcopy(item.get("registration") or {})
    provider = registration.get("tokenProvider") or account.get("tokenProvider") or default_provider
    registration["tokenProvider"] = normalize_token_provider(provider)
    runner_url = registration.get("runnerUrl")
    if not runner_url:
        raise ConfigError("registration.runnerUrl is required for each repo/org runner binding")
    if not isinstance(runner_url, str) or not runner_url.startswith("https://github.com/"):
        raise ConfigError("registration.runnerUrl must be an https://github.com/ URL")
    return registration


def normalize_config(raw: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    cfg = deepcopy(raw)
    warnings: list[str] = []
    if cfg.get("version") != 1:
        raise ConfigError("version must be 1")
    if cfg.get("project") != "github-actions-runners":
        raise ConfigError("project must be github-actions-runners")

    defaults = cfg.setdefault("defaults", {})
    defaults.setdefault("openSourceReady", True)
    if "totalRunnerCap" not in defaults:
        warnings.append("defaults.totalRunnerCap omitted; using 20")
    total_cap = int(defaults.get("totalRunnerCap", DEFAULT_TOTAL_CAP))
    if total_cap < 1:
        raise ConfigError("defaults.totalRunnerCap must be >= 1")
    defaults["totalRunnerCap"] = total_cap

    azure = defaults.setdefault("azure", {})
    if "region" not in azure:
        warnings.append("defaults.azure.region omitted; using eastus")
    azure.setdefault("region", DEFAULT_REGION)
    azure.setdefault("resourceGroup", DEFAULT_RG)
    identity = azure.setdefault("deploymentIdentity", {})
    identity.setdefault("scope", "resourceGroup")
    identity.setdefault("resourceGroup", azure["resourceGroup"])
    if identity.get("scope") != "resourceGroup" or identity.get("resourceGroup") != azure["resourceGroup"]:
        raise ConfigError("defaults.azure.deploymentIdentity must be resource-group-scoped to the configured resource group")
    network = azure.setdefault("network", {})
    network.setdefault("vnetName", "gha-runners-vnet")
    network.setdefault("addressPrefix", "10.42.0.0/16")
    network.setdefault("subnetName", "runners")
    network.setdefault("subnetPrefix", "10.42.1.0/24")
    network.setdefault("nsgName", "gha-runners-nsg")
    tags = azure.setdefault("tags", {})
    tags.setdefault("project", "github-actions-runners")
    tags.setdefault("environment", "dev")
    tags.setdefault("managed-by", "azure-cli")

    github = defaults.setdefault("github", {})
    github.setdefault("apiBaseUrl", "https://api.github.com")
    github.setdefault("runnerScopeDefault", "repository")
    github.setdefault("ephemeral", True)
    default_provider = normalize_token_provider(github.get("tokenProvider"))
    github["runnerRelease"] = normalize_runner_release(github)
    normalize_shared_package_cache(defaults)

    pools = cfg.get("runnerPools")
    if not isinstance(pools, list) or not pools:
        raise ConfigError("runnerPools must contain at least one pool")
    pool_names: set[str] = set()
    for pool in pools:
        if not isinstance(pool, dict):
            raise ConfigError("runnerPools entries must be objects")
        name = pool.get("name")
        if not name:
            raise ConfigError("runnerPools[].name is required")
        if name in pool_names:
            raise ConfigError(f"duplicate runner pool: {name}")
        pool_names.add(name)
        pool.setdefault("os", "linux")
        pool.setdefault("arch", "x64")
        pool["os"] = str(pool["os"]).lower()
        pool["arch"] = str(pool["arch"]).lower()
        if (pool["os"], pool["arch"]) not in SUPPORTED_RUNNER_ASSETS:
            raise ConfigError(f"pool {name} uses unsupported runner asset {pool['os']}/{pool['arch']}")
        pool.setdefault("minRunners", 0)
        pool.setdefault("ephemeral", github.get("ephemeral", True))
        pool.setdefault("maxRunners", total_cap if len(pools) == 1 else None)
        if pool.get("maxRunners") is None:
            raise ConfigError(f"runnerPools[{name}].maxRunners is required when multiple pools exist")
        pool["minRunners"] = int(pool.get("minRunners", 0))
        pool["maxRunners"] = int(pool.get("maxRunners", 0))
        if pool["minRunners"] < 0 or pool["maxRunners"] < 1:
            raise ConfigError(f"pool {name} must have minRunners >= 0 and maxRunners >= 1")
        if pool["minRunners"] > pool["maxRunners"]:
            raise ConfigError(f"pool {name} minRunners cannot exceed maxRunners")
        if pool.get("minRunners") or pool.get("idleTimeoutMinutes"):
            pool.setdefault("scalingMode", "fixed-capacity-v1")
        azp = pool.setdefault("azure", {})
        azp.setdefault("vmSize", DEFAULT_VM_SIZE)
        azp.setdefault("image", DEFAULT_IMAGE)
        azp.setdefault("orchestrationMode", DEFAULT_ORCHESTRATION)
        azp.setdefault("upgradePolicyMode", DEFAULT_UPGRADE_POLICY)
        azp.setdefault("publicIp", False)
        validate_pool_azure_compatibility(pool)
        pool["labels"] = ensure_labels(pool)

    accounts = cfg.get("accounts", [])
    if not isinstance(accounts, list) or not accounts:
        raise ConfigError("accounts must contain at least one account")
    for ai, account in enumerate(accounts):
        if not isinstance(account, dict):
            raise ConfigError("accounts entries must be objects")
        normalize_account_visibility(account, ai)
    assert_private_first(cfg, accounts)
    assert_shared_package_cache_trust_boundary(cfg, accounts)

    targets: list[dict[str, Any]] = []
    for ai, account in enumerate(accounts):
        kind = account.get("kind")
        owner = account.get("owner")
        if kind not in ("user", "organization"):
            raise ConfigError(f"accounts[{ai}].kind must be user or organization")
        if not owner:
            raise ConfigError(f"accounts[{ai}].owner is required")
        if kind == "user":
            repos = account.get("repositories")
            if not isinstance(repos, list) or not repos:
                raise ConfigError(f"accounts[{owner}].repositories must be a non-empty list for user accounts")
            for repo in repos:
                if repo.get("enabled", True) is False:
                    continue
                pool = repo.get("pool")
                if pool not in pool_names:
                    raise ConfigError(f"repo {owner}/{repo.get('name', '<missing>')} references missing pool {pool}")
                full_name = repo.get("fullName") or f"{owner}/{repo.get('name', '<missing>')}"
                if "/" not in full_name:
                    raise ConfigError(f"repo {full_name} must include owner/name")
                registration = target_registration(account, repo, default_provider)
                targets.append({
                    "bindingName": sanitize_name(f"repo-{full_name}"),
                    "kind": "repository",
                    "owner": owner,
                    "repository": full_name,
                    "pool": pool,
                    "runnerScope": repo.get("runnerScope", "repository"),
                    "capacity": int(repo.get("maxRunners", next(p["maxRunners"] for p in pools if p["name"] == pool))),
                    "registration": registration,
                })
        else:
            repo_spec = account.get("repositories", {})
            includes = repo_spec.get("include", []) if isinstance(repo_spec, dict) else []
            if not includes:
                raise ConfigError(f"organization {owner} must define repositories.include allow-list")
            for pi, pool_ref in enumerate(account.get("pools", [])):
                pool = pool_ref.get("pool")
                if pool not in pool_names:
                    raise ConfigError(f"organization {owner} pools[{pi}] references missing pool {pool}")
                allow = pool_ref.get("repositoryAllowList", includes)
                if not allow:
                    raise ConfigError(f"organization {owner} pool {pool} must define repositoryAllowList")
                registration = target_registration(account, pool_ref, default_provider)
                targets.append({
                    "bindingName": sanitize_name(f"org-{owner}-{pool}"),
                    "kind": "organization",
                    "owner": owner,
                    "repositories": allow,
                    "pool": pool,
                    "runnerScope": pool_ref.get("runnerScope", "organization"),
                    "runnerGroup": account.get("runnerGroup", "default"),
                    "capacity": int(pool_ref.get("maxRunners", next(p["maxRunners"] for p in pools if p["name"] == pool))),
                    "registration": registration,
                })
    if not targets:
        raise ConfigError("at least one enabled runner target binding is required")
    planned_capacity = sum(t["capacity"] for t in targets)
    if planned_capacity > total_cap:
        raise ConfigError(f"total target capacity {planned_capacity} exceeds defaults.totalRunnerCap {total_cap}")
    cfg["targets"] = targets
    cfg["totalPlannedCapacity"] = planned_capacity
    return cfg, warnings


def indent_block(text: str, spaces: int) -> str:
    prefix = " " * spaces
    lines = text.splitlines() or [""]
    return "\n".join(prefix + line for line in lines)


def provisioned_token_provider(provider: dict[str, Any], binding_name: str, root: Path) -> dict[str, Any]:
    if provider["type"] != "command":
        return {
            "vmExecutable": False,
            "mode": provider["type"],
            "reason": "only command token providers can currently be provisioned into VM cloud-init",
        }
    credential_source = provider.get("vmCredentialSource")
    if not credential_source:
        return {
            "vmExecutable": False,
            "mode": "command",
            "reason": "command token providers require vmCredentialSource.managedIdentityGitHubApp before they can run on Azure VMs",
        }
    validate_vm_credential_source(credential_source)
    command = str(provider["command"])
    try:
        parts = shlex.split(command)
    except ValueError as ex:
        raise ConfigError(f"token provider command for {binding_name} is invalid") from ex
    if not parts:
        raise ConfigError(f"token provider command for {binding_name} is empty")
    source = Path(parts[0])
    if source.is_absolute():
        return {
            "vmExecutable": False,
            "mode": "command",
            "reason": "absolute local token provider paths are not VM-portable",
        }
    resolved = (root / source).resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError as ex:
        raise ConfigError(f"token provider command for {binding_name} must stay inside the artifact root") from ex
    if not resolved.is_file():
        return {
            "vmExecutable": False,
            "mode": "command",
            "reason": f"token provider script does not exist: {parts[0]}",
        }
    content = resolved.read_text(encoding="utf-8")
    vm_path = f"/usr/local/bin/gha-runner-token-provider-{binding_name}.sh"
    vm_command = shlex.join([vm_path, *parts[1:]])
    return {
        "vmExecutable": True,
        "mode": "provisioned-script",
        "sourcePath": str(source),
        "vmPath": vm_path,
        "vmCommand": vm_command,
        "scriptContent": content,
        "scriptSha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
        "credentialSource": deepcopy(credential_source),
        "vmEnvironment": vm_credential_environment(credential_source),
    }


def token_provider_environment_exports(binding: dict[str, Any]) -> str:
    contract = binding.get("tokenProviderContract") or {}
    values = contract.get("vmEnvironment") or {}
    if not values:
        return ""
    lines = []
    for key, value in sorted(values.items()):
        escaped = str(value).replace("'", "'\"'\"'")
        lines.append(f"      {key}='{escaped}'")
    return "\n".join(lines)


def shared_package_cache_replacements(binding: dict[str, Any]) -> dict[str, str]:
    cache = binding.get("sharedPackageCache") or DEFAULT_SHARED_PACKAGE_CACHE
    root = str(cache.get("root", DEFAULT_SHARED_PACKAGE_CACHE["root"])).rstrip("/")
    managers = set(cache.get("packageManagers", []))
    values = {
        "{{SHARED_PACKAGE_CACHE_ROOT}}": root,
        "{{SHARED_PACKAGE_CACHE_MAX_SIZE_GB}}": str(cache.get("maxSizeGb", 20)),
        "{{SHARED_PACKAGE_CACHE_PRUNE_AFTER_DAYS}}": str(cache.get("pruneAfterDays", 14)),
        "{{SHARED_PACKAGE_CACHE_OWNERSHIP}}": str(cache.get("ownership", "actions-runner:actions-runner")),
        "{{SHARED_PACKAGE_CACHE_ENABLED}}": "true" if cache.get("enabled", True) else "false",
        "{{NPM_CACHE_DIR}}": f"{root}/npm" if "npm" in managers else "",
        "{{PIP_CACHE_DIR}}": f"{root}/pip" if "pip" in managers else "",
        "{{NUGET_PACKAGES_DIR}}": f"{root}/nuget/packages" if "nuget" in managers else "",
        "{{DOTNET_CLI_HOME_DIR}}": f"{root}/dotnet-home" if "nuget" in managers else "",
        "{{CARGO_HOME_DIR}}": f"{root}/cargo" if "cargo" in managers else "",
        "{{GOMODCACHE_DIR}}": f"{root}/go/pkg/mod" if "go" in managers else "",
        "{{GOCACHE_DIR}}": f"{root}/go/build" if "go" in managers else "",
        "{{XDG_CACHE_HOME_DIR}}": f"{root}/xdg" if any(m in managers for m in ("pip", "go", "cargo")) else "",
        "{{APT_CACHE_DIR}}": f"{root}/apt/archives" if "apt" in managers else "",
    }
    return values


def token_provider_write_file(binding: dict[str, Any]) -> str:
    contract = binding.get("tokenProviderContract") or {}
    if not contract.get("vmExecutable"):
        return ""
    return (
        f"  - path: {contract['vmPath']}\n"
        "    owner: root:root\n"
        "    permissions: '0755'\n"
        "    content: |\n"
        f"{indent_block(contract['scriptContent'], 6)}"
    )


def validate_token_provider_contract_for_live_apply(plan: dict[str, Any], root: Path) -> None:
    for binding in plan["runnerBindings"]:
        contract = binding.get("tokenProviderContract") or {}
        if not contract.get("vmExecutable"):
            reason = contract.get("reason", "provider is not executable in the VM environment")
            raise ConfigError(f"token provider for {binding['bindingName']} is not VM-executable before live Azure mutation: {reason}")
        source = (root / contract["sourcePath"]).resolve()
        if not source.is_file():
            raise ConfigError(f"token provider for {binding['bindingName']} is missing locally: {contract['sourcePath']}")
        current = hashlib.sha256(source.read_text(encoding="utf-8").encode("utf-8")).hexdigest()
        if current != contract.get("scriptSha256"):
            raise ConfigError(f"token provider for {binding['bindingName']} changed after plan render")
        credential_source = contract.get("credentialSource")
        if not credential_source:
            raise ConfigError(f"token provider for {binding['bindingName']} has no VM credential source contract")
        contract["vmEnvironment"] = validate_vm_credential_source_for_live_apply(credential_source, binding["bindingName"])


def github_registration_endpoint(target: dict[str, Any], api_base: str) -> str:
    if target["kind"] == "repository":
        return f"{api_base}/repos/{target['repository']}/actions/runners/registration-token"
    return f"{api_base}/orgs/{target['owner']}/actions/runners/registration-token"


def token_provider_command(provider: dict[str, Any]) -> str:
    ptype = provider["type"]
    if ptype == "command":
        return str(provider["command"])
    if ptype == "env":
        return f"printf '%s' \"${{{provider['env']}}}\""
    return f"az keyvault secret show --vault-name {shlex.quote(str(provider['vault']))} --name {shlex.quote(str(provider['secretName']))} --query value -o tsv"


def token_provider_environment(binding: dict[str, Any]) -> dict[str, str]:
    target = binding.get("target", {})
    env = dict(os.environ)
    env.update({
        "GHA_REGISTRATION_TOKEN_ENDPOINT": str(binding.get("registrationTokenEndpoint", "")),
        "GHA_RUNNER_URL": str(binding.get("runnerUrl", "")),
        "GHA_RUNNER_SCOPE": str(target.get("runnerScope", target.get("kind", ""))),
        "GHA_BINDING_NAME": str(binding.get("bindingName", "")),
        "GHA_TARGET_KIND": str(target.get("kind", "")),
        "GHA_TARGET_OWNER": str(target.get("owner", "")),
        "GHA_TARGET_REPOSITORY": str(target.get("repository", "")),
    })
    return env


def assert_no_azure_mutation_command(cmd: list[str]) -> None:
    if not cmd or cmd[0] != "az":
        return
    mutation_prefixes = (
        ["az", "group", "create"],
        ["az", "network", "nsg"],
        ["az", "network", "vnet"],
        ["az", "vmss", "create"],
        ["az", "group", "delete"],
    )
    if any(cmd[:len(prefix)] == prefix for prefix in mutation_prefixes):
        raise ConfigError(f"internal guard refused Azure mutation before validation: {' '.join(cmd[:4])}")


def validate_token_provider_output(binding: dict[str, Any], root: Path) -> None:
    provider_type = binding.get("tokenProviderType")
    command = str(binding.get("tokenProviderValidationCommand") or binding.get("tokenProviderCommand") or "")
    if not binding.get("runnerUrl") or not command or not binding.get("registrationTokenEndpoint"):
        raise ConfigError(f"runner registration inputs missing for binding {binding['bindingName']}")
    if provider_type == "env":
        provider = binding.get("tokenProvider", {})
        env_name = provider.get("env")
        if not env_name or not os.environ.get(str(env_name), "").strip():
            raise ConfigError(f"env token provider for {binding['bindingName']} is unset or empty")
        return
    if provider_type == "command":
        try:
            first = shlex.split(command)[0]
        except (IndexError, ValueError) as ex:
            raise ConfigError(f"token provider command for {binding['bindingName']} is invalid") from ex
        candidate = (root / first).resolve() if not Path(first).is_absolute() else Path(first)
        if not candidate.exists():
            raise ConfigError(f"token provider command for {binding['bindingName']} does not exist: {first}")
    result = subprocess.run(["bash", "-lc", command], cwd=root, text=True, capture_output=True, env=token_provider_environment(binding))
    if result.returncode != 0:
        raise ConfigError(f"token provider failed for {binding['bindingName']} before live Azure mutation")
    if not result.stdout.strip():
        raise ConfigError(f"token provider returned no token for {binding['bindingName']}")


def build_azure_plan(cfg: dict[str, Any], config_path: str | Path) -> dict[str, Any]:
    root = Path(config_path).resolve().parent.parent
    azure = cfg["defaults"]["azure"]
    github = cfg["defaults"]["github"]
    network = azure["network"]
    region = azure["region"]
    rg = azure["resourceGroup"]
    tags = dict(azure.get("tags", {}))
    tags.setdefault("project", "github-actions-runners")
    tags.setdefault("managed-by", "azure-cli")
    common_tags = [f"{k}={v}" for k, v in sorted(tags.items())]
    commands = [
        ["az", "group", "create", "--name", rg, "--location", region, "--tags", *common_tags],
        ["az", "network", "nsg", "create", "--resource-group", rg, "--name", network["nsgName"], "--location", region, "--tags", *common_tags],
        ["az", "network", "vnet", "create", "--resource-group", rg, "--name", network["vnetName"], "--location", region, "--address-prefix", network["addressPrefix"], "--subnet-name", network["subnetName"], "--subnet-prefix", network["subnetPrefix"], "--network-security-group", network["nsgName"], "--tags", *common_tags],
    ]
    pool_by_name = {p["name"]: p for p in cfg["runnerPools"]}
    bindings = []
    for target in cfg["targets"]:
        pool = pool_by_name[target["pool"]]
        binding_tags = dict(tags)
        binding_tags.update({"pool": pool["name"], "runner-binding": target["bindingName"], "scope": target["kind"]})
        tag_args = [f"{k}={v}" for k, v in sorted(binding_tags.items())]
        vmss_name = sanitize_name(f"gha-{tags.get('environment', 'dev')}-{target['bindingName']}", 60)
        cloud_init_path = f".plan/cloud-init-{target['bindingName']}.yaml"
        provider = target["registration"]["tokenProvider"]
        provider_contract = provisioned_token_provider(provider, target["bindingName"], root)
        validation_token_command = token_provider_command(provider)
        token_command = provider_contract.get("vmCommand") or validation_token_command
        runner_asset = runner_asset_metadata(pool, github)
        binding = {
            "bindingName": target["bindingName"],
            "pool": pool["name"],
            "target": target,
            "vmssName": vmss_name,
            "region": region,
            "resourceGroup": rg,
            "capacity": target["capacity"],
            "vmSize": pool["azure"]["vmSize"],
            "image": pool["azure"].get("image", DEFAULT_IMAGE),
            "orchestrationMode": pool["azure"].get("orchestrationMode", DEFAULT_ORCHESTRATION),
            "upgradePolicyMode": pool["azure"].get("upgradePolicyMode", DEFAULT_UPGRADE_POLICY),
            "publicIp": bool(pool["azure"].get("publicIp", False)),
            "labels": pool["labels"],
            "ephemeral": pool.get("ephemeral", True),
            **runner_asset,
            "vmArchitecture": pool["arch"],
            "vmArchitectureContract": VM_ARCH_DOCS[pool["arch"]],
            "runnerUrl": target["registration"]["runnerUrl"],
            "registrationTokenEndpoint": github_registration_endpoint(target, github.get("apiBaseUrl", "https://api.github.com")),
            "tokenProvider": target["registration"]["tokenProvider"],
            "tokenProviderType": target["registration"]["tokenProvider"]["type"],
            "tokenProviderCommand": token_command,
            "tokenProviderValidationCommand": validation_token_command,
            "tokenProviderContract": provider_contract,
            "sharedPackageCache": deepcopy(cfg["defaults"]["sharedPackageCache"]),
            "runnerGroup": target.get("runnerGroup"),
            "repositoryAllowList": target.get("repositories", [target.get("repository")]),
            "cloudInitTemplate": "templates/cloud-init-runner.yaml.tmpl",
            "renderedCloudInit": cloud_init_path,
        }
        bindings.append(binding)
        commands.append(["az", "vmss", "create", "--resource-group", rg, "--name", vmss_name, "--location", region, "--image", binding["image"], "--vm-sku", binding["vmSize"], "--instance-count", str(binding["capacity"]), "--orchestration-mode", binding["orchestrationMode"], "--upgrade-policy-mode", binding["upgradePolicyMode"], "--vnet-name", network["vnetName"], "--subnet", network["subnetName"], "--public-ip-address", "" if not binding["publicIp"] else f"{vmss_name}-pip", "--custom-data", cloud_init_path, "--admin-username", "azureuser", "--generate-ssh-keys", "--assign-identity", "--tags", *tag_args])
    return {
        "project": cfg["project"],
        "configPath": str(config_path),
        "totalRunnerCap": cfg["defaults"]["totalRunnerCap"],
        "plannedCapacity": cfg["totalPlannedCapacity"],
        "region": region,
        "resourceGroup": rg,
        "tenantId": azure.get("tenantId"),
        "subscriptionId": azure.get("subscriptionId"),
        "deploymentIdentity": azure.get("deploymentIdentity"),
        "network": network,
        "tags": tags,
        "sharedPackageCache": deepcopy(cfg["defaults"]["sharedPackageCache"]),
        "runnerBindings": bindings,
        "azureCliCommands": commands,
        "applyRequiresExplicitSpendConfirmation": SPEND_CONFIRMATION,
        "destroyRequiresResourceGroupConfirmation": True,
        "topology": "one VMSS and cloud-init bootstrap per repo/org registration binding",
    }


def render_cloud_init(binding: dict[str, Any], template_path: str | Path) -> str:
    contract = binding.get("tokenProviderContract") or {}
    if not contract.get("vmExecutable"):
        reason = contract.get("reason", "provider is not executable in the VM environment")
        raise ConfigError(f"token provider for {binding['bindingName']} is not VM-executable for cloud-init render: {reason}")
    text = Path(template_path).read_text(encoding="utf-8")
    replacements = {
        "{{POOL_NAME}}": binding["pool"],
        "{{BINDING_NAME}}": binding["bindingName"],
        "{{RUNNER_URL}}": binding["runnerUrl"],
        "{{RUNNER_LABELS}}": ",".join(binding["labels"]),
        "{{RUNNER_EPHEMERAL}}": "true" if binding.get("ephemeral", True) else "false",
        "{{RUNNER_OS}}": binding["runnerOs"],
        "{{RUNNER_ARCH}}": binding["runnerArch"],
        "{{RUNNER_ASSET_NAME}}": binding["runnerAssetName"],
        "{{RUNNER_DOWNLOAD_URL}}": binding["runnerDownloadUrl"],
        "{{RUNNER_SHA256}}": binding["runnerSha256"],
        "{{TOKEN_PROVIDER_WRITE_FILE}}": token_provider_write_file(binding),
        "{{TOKEN_PROVIDER_ENVIRONMENT}}": token_provider_environment_exports(binding),
        "{{TOKEN_PROVIDER_COMMAND}}": binding["tokenProviderCommand"].replace("'", "'\"'\"'"),
        **shared_package_cache_replacements(binding),
        "{{REGISTRATION_TOKEN_ENDPOINT}}": binding["registrationTokenEndpoint"],
        "{{RUNNER_SCOPE}}": binding["target"].get("runnerScope", binding["target"].get("kind", "")),
        "{{TARGET_KIND}}": binding["target"].get("kind", ""),
        "{{TARGET_OWNER}}": binding["target"].get("owner", ""),
        "{{TARGET_REPOSITORY}}": binding["target"].get("repository", ""),
        "{{RUNNER_GROUP}}": binding.get("runnerGroup") or "",
    }
    for old, new in replacements.items():
        text = text.replace(old, str(new))
    return text


def validate_account_for_live_apply(plan: dict[str, Any]) -> None:
    configured_tenant = require_resolved(plan.get("tenantId"), "defaults.azure.tenantId")
    configured_subscription = require_resolved(plan.get("subscriptionId"), "defaults.azure.subscriptionId")
    account_raw = subprocess.run(["az", "account", "show", "--output", "json"], text=True, capture_output=True, check=True).stdout
    account = json.loads(account_raw)
    active_tenant = account.get("tenantId")
    active_subscription = account.get("id")
    if active_tenant != configured_tenant:
        raise ConfigError(f"active Azure tenant {active_tenant} does not match configured tenant {configured_tenant}")
    if active_subscription != configured_subscription:
        raise ConfigError(f"active Azure subscription {active_subscription} does not match configured subscription {configured_subscription}")


def validate_registration_for_live_apply(plan: dict[str, Any], root: Path) -> None:
    for binding in plan["runnerBindings"]:
        contract = binding.get("tokenProviderContract") or {}
        if contract.get("credentialSource", {}).get("type") == "managedIdentityGitHubApp":
            continue
        validate_token_provider_output(binding, root)


def apply_azure(plan: dict[str, Any], root: Path, allow_scale_down: bool, confirm_spend: str | None) -> None:
    if confirm_spend != SPEND_CONFIRMATION:
        raise ConfigError(f"live apply requires --confirm-spend {SPEND_CONFIRMATION}")
    validate_token_provider_contract_for_live_apply(plan, root)
    validate_account_for_live_apply(plan)
    validate_registration_for_live_apply(plan, root)
    (root / ".plan").mkdir(exist_ok=True)
    for binding in plan["runnerBindings"]:
        (root / binding["renderedCloudInit"]).write_text(render_cloud_init(binding, root / binding["cloudInitTemplate"]), encoding="utf-8")
    for cmd in plan["azureCliCommands"]:
        if cmd[:3] == ["az", "vmss", "create"]:
            name = cmd[cmd.index("--name") + 1]
            existing = subprocess.run(["az", "vmss", "show", "--resource-group", plan["resourceGroup"], "--name", name, "--query", "sku.capacity", "--output", "tsv"], text=True, capture_output=True)
            if existing.returncode == 0 and existing.stdout.strip().isdigit():
                existing_capacity = int(existing.stdout.strip())
                requested = int(cmd[cmd.index("--instance-count") + 1])
                if requested < existing_capacity and not allow_scale_down:
                    raise ConfigError(f"{name} existing capacity {existing_capacity} is above requested {requested}; rerun with --allow-scale-down")
        subprocess.run(cmd, check=True)


def destroy_azure(plan: dict[str, Any], confirm_resource_group: str, confirm_spend: str | None) -> None:
    rg = plan["resourceGroup"]
    if confirm_resource_group != rg:
        raise ConfigError(f"destructive confirmation mismatch: expected --confirm-resource-group {rg}")
    if confirm_spend != SPEND_CONFIRMATION:
        raise ConfigError(f"live destroy requires --confirm-spend {SPEND_CONFIRMATION}")
    validate_account_for_live_apply(plan)
    subprocess.run(["az", "group", "delete", "--name", rg, "--yes", "--no-wait"], check=True)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("validate", "azure-plan", "apply-azure", "destroy-azure"):
        p = sub.add_parser(name)
        p.add_argument("--config", default="config/runners.yaml")
    r = sub.add_parser("render-cloud-init")
    r.add_argument("--config", default="config/runners.yaml")
    r.add_argument("--binding", required=True)
    r.add_argument("--output")
    sub.choices["apply-azure"].add_argument("--allow-scale-down", action="store_true")
    sub.choices["apply-azure"].add_argument("--confirm-spend")
    sub.choices["destroy-azure"].add_argument("--confirm-resource-group", required=True)
    sub.choices["destroy-azure"].add_argument("--confirm-spend")
    args = parser.parse_args(argv)
    try:
        raw = load_config(args.config)
        cfg, warnings = normalize_config(raw)
        root = Path(args.config).resolve().parent.parent
        if args.command == "validate":
            print("config valid")
            print(f"totalRunnerCap={cfg['defaults']['totalRunnerCap']}")
            print(f"azure.region={cfg['defaults']['azure']['region']}")
            print(f"runnerPools={len(cfg['runnerPools'])}")
            print(f"runnerBindings={len(cfg['targets'])}")
            print(f"totalPlannedCapacity={cfg['totalPlannedCapacity']}")
            for w in warnings:
                print(f"warning: {w}")
        elif args.command == "azure-plan":
            print(json.dumps(build_azure_plan(cfg, args.config), indent=2))
        elif args.command == "render-cloud-init":
            plan = build_azure_plan(cfg, args.config)
            binding = next((p for p in plan["runnerBindings"] if p["bindingName"] == args.binding), None)
            if binding is None:
                raise ConfigError(f"unknown binding: {args.binding}")
            rendered = render_cloud_init(binding, root / binding["cloudInitTemplate"])
            if args.output:
                out = Path(args.output)
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_text(rendered, encoding="utf-8")
                print(str(out))
            else:
                print(rendered)
        elif args.command == "apply-azure":
            apply_azure(build_azure_plan(cfg, args.config), root, args.allow_scale_down, args.confirm_spend)
        elif args.command == "destroy-azure":
            destroy_azure(build_azure_plan(cfg, args.config), args.confirm_resource_group, args.confirm_spend)
    except (ConfigError, FileNotFoundError, subprocess.CalledProcessError, json.JSONDecodeError) as ex:
        print(f"error: {ex}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
