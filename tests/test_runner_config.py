import unittest
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch

from tools.runner_config import (
    ConfigError,
    SPEND_CONFIRMATION,
    apply_azure,
    build_azure_plan,
    load_config,
    normalize_config,
    render_cloud_init,
    token_provider_environment,
)

ROOT = Path(__file__).resolve().parents[1]


class RunnerConfigTests(unittest.TestCase):
    def load(self, name):
        return load_config(ROOT / "tests" / "fixtures" / name)

    def example(self):
        return load_config(ROOT / "config" / "runners.example.yaml")

    def test_defaults_are_applied(self):
        cfg, warnings = normalize_config(self.load("defaults.yaml"))
        self.assertEqual(cfg["defaults"]["totalRunnerCap"], 20)
        self.assertEqual(cfg["defaults"]["azure"]["region"], "eastus")
        self.assertEqual(cfg["runnerPools"][0]["maxRunners"], 20)
        self.assertEqual(cfg["totalPlannedCapacity"], 20)
        self.assertTrue(any("totalRunnerCap" in w for w in warnings))

    def test_over_cap_fails(self):
        with self.assertRaisesRegex(ConfigError, "exceeds"):
            normalize_config(self.load("over-cap.yaml"))

    def test_missing_pool_reference_fails(self):
        with self.assertRaisesRegex(ConfigError, "does-not-exist"):
            normalize_config(self.load("missing-pool.yaml"))

    def test_public_user_visibility_rejected_without_reviewed_opt_in(self):
        raw = self.example()
        raw["accounts"][0]["visibility"] = "public"
        with self.assertRaisesRegex(ConfigError, "public is not allowed"):
            normalize_config(raw)

    def test_public_org_visibility_rejected_without_reviewed_opt_in(self):
        raw = self.example()
        raw["accounts"][1]["visibility"] = "public"
        with self.assertRaisesRegex(ConfigError, "public is not allowed"):
            normalize_config(raw)

    def test_unknown_user_visibility_fails_closed(self):
        raw = self.example()
        raw["accounts"][0]["visibility"] = "publik"
        with self.assertRaisesRegex(ConfigError, "visibility must be one of"):
            normalize_config(raw)

    def test_unknown_org_visibility_fails_closed(self):
        raw = self.example()
        raw["accounts"][1]["visibility"] = "publik"
        with self.assertRaisesRegex(ConfigError, "visibility must be one of"):
            normalize_config(raw)

    def test_reviewed_public_visibility_does_not_accept_shared_package_cache_risk(self):
        raw = self.example()
        raw["accounts"][0]["visibility"] = "public"
        raw["publicVisibilityOptIn"] = {
            "allowPublicVisibility": True,
            "reviewedBy": "qa-probe",
            "reviewedAt": "2026-06-23",
        }
        with self.assertRaisesRegex(ConfigError, "sharedPackageCache"):
            normalize_config(raw)

    def test_public_visibility_allows_shared_package_cache_only_with_specific_review(self):
        raw = self.example()
        raw["accounts"][0]["visibility"] = "public"
        raw["publicVisibilityOptIn"] = {
            "allowPublicVisibility": True,
            "reviewedBy": "product-owner",
            "reviewedAt": "2026-06-23",
            "sharedPackageCacheRisk": {
                "allowSharedPackageCache": True,
                "reviewedBy": "securityreview",
                "reviewedAt": "2026-06-23",
                "reason": "public runners are pinned to an isolated VMSS cache trust domain for this reviewed V1 exception",
            },
        }
        cfg, _ = normalize_config(raw)
        self.assertTrue(cfg["defaults"]["sharedPackageCache"]["enabled"])
        self.assertTrue(cfg["defaults"]["sharedPackageCache"]["publicUntrustedRiskAccepted"])

    def test_public_visibility_allows_shared_package_cache_disabled(self):
        raw = self.example()
        raw["accounts"][0]["visibility"] = "public"
        raw["defaults"]["sharedPackageCache"]["enabled"] = False
        raw["publicVisibilityOptIn"] = {
            "allowPublicVisibility": True,
            "reviewedBy": "product-owner",
            "reviewedAt": "2026-06-23",
        }
        cfg, _ = normalize_config(raw)
        self.assertFalse(cfg["defaults"]["sharedPackageCache"]["enabled"])

    def test_missing_runner_url_fails_closed(self):
        raw = self.example()
        del raw["accounts"][0]["repositories"][0]["registration"]["runnerUrl"]
        with self.assertRaisesRegex(ConfigError, "registration.runnerUrl is required"):
            normalize_config(raw)

    def test_missing_token_provider_fails_closed(self):
        raw = self.example()
        del raw["defaults"]["github"]["tokenProvider"]
        with self.assertRaisesRegex(ConfigError, "tokenProvider is required"):
            normalize_config(raw)

    def test_example_plan_contains_target_binding_topology(self):
        cfg, _ = normalize_config(self.example())
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        self.assertEqual(plan["region"], "eastus")
        self.assertEqual(plan["totalRunnerCap"], 20)
        self.assertEqual(plan["plannedCapacity"], 20)
        self.assertEqual(len(plan["runnerBindings"]), 3)
        self.assertEqual(plan["topology"], "one VMSS and cloud-init bootstrap per repo/org registration binding")
        self.assertTrue(all("registrationTokenEndpoint" in b for b in plan["runnerBindings"]))
        self.assertTrue(all(b["runnerUrl"].startswith("https://github.com/") for b in plan["runnerBindings"]))

    def test_example_plan_uses_v1_linux_image_and_labels(self):
        cfg, _ = normalize_config(self.example())
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        self.assertTrue(all(b["image"] == "Ubuntu2404" for b in plan["runnerBindings"]))
        self.assertIn("sh-linux", plan["runnerBindings"][0]["labels"])
        self.assertIn("sh-linux-lg", plan["runnerBindings"][1]["labels"])
        self.assertEqual(plan["runnerBindings"][0]["pool"], "sh-linux")
        self.assertEqual(plan["runnerBindings"][1]["pool"], "sh-linux-lg")

    def test_cloud_init_has_no_token_literal_and_fails_closed(self):
        cfg, _ = normalize_config(self.example())
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        rendered = render_cloud_init(plan["runnerBindings"][0], ROOT / "templates" / "cloud-init-runner.yaml.tmpl")
        self.assertIn("repo-example-user-repo-one", rendered)
        self.assertIn("runner bootstrap failed closed", rendered)
        self.assertIn("TOKEN_PROVIDER_COMMAND", rendered)
        self.assertIn("GHA_REGISTRATION_TOKEN_ENDPOINT", rendered)
        self.assertIn("GHA_RUNNER_URL", rendered)
        self.assertNotIn("ghp_", rendered)

    def test_cloud_init_assigns_runtime_token_provider_context(self):
        cfg, _ = normalize_config(self.example())
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        binding = plan["runnerBindings"][0]
        rendered = render_cloud_init(binding, ROOT / "templates" / "cloud-init-runner.yaml.tmpl")
        exported_context = [
            "GHA_REGISTRATION_TOKEN_ENDPOINT",
            "GHA_RUNNER_URL",
            "GHA_RUNNER_SCOPE",
            "GHA_BINDING_NAME",
            "GHA_TARGET_KIND",
            "GHA_TARGET_OWNER",
            "GHA_TARGET_REPOSITORY",
        ]
        self.assertIn(f"RUNNER_URL='{binding['runnerUrl']}'", rendered)
        self.assertIn('GHA_RUNNER_URL="$RUNNER_URL"', rendered)
        self.assertIn('GHA_BINDING_NAME="$RUNNER_BINDING"', rendered)
        self.assertIn("export " + " ".join(exported_context), rendered)
        self.assertLess(rendered.index('GHA_RUNNER_URL="$RUNNER_URL"'), rendered.index('TOKEN="$(bash -lc "$TOKEN_PROVIDER_COMMAND")"'))

    def test_cloud_init_runtime_provider_context_matches_python_validation_context(self):
        cfg, _ = normalize_config(self.example())
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        binding = plan["runnerBindings"][0]
        env = token_provider_environment(binding)
        rendered = render_cloud_init(binding, ROOT / "templates" / "cloud-init-runner.yaml.tmpl")
        expected_assignments = {
            "GHA_REGISTRATION_TOKEN_ENDPOINT": binding["registrationTokenEndpoint"],
            "GHA_RUNNER_URL": "$RUNNER_URL",
            "GHA_RUNNER_SCOPE": env["GHA_RUNNER_SCOPE"],
            "GHA_BINDING_NAME": "$RUNNER_BINDING",
            "GHA_TARGET_KIND": env["GHA_TARGET_KIND"],
            "GHA_TARGET_OWNER": env["GHA_TARGET_OWNER"],
            "GHA_TARGET_REPOSITORY": env["GHA_TARGET_REPOSITORY"],
        }
        for name, value in expected_assignments.items():
            self.assertIn(f'{name}=\'{value}\'' if value.startswith("https://") else f'{name}="{value}"' if value.startswith("$") else f'{name}=\'{value}\'', rendered)

    def test_cloud_init_uses_pinned_runner_download_with_sha256(self):
        cfg, _ = normalize_config(self.example())
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        binding = plan["runnerBindings"][0]
        rendered = render_cloud_init(binding, ROOT / "templates" / "cloud-init-runner.yaml.tmpl")
        self.assertEqual(binding["runnerAssetName"], "actions-runner-linux-x64-2.335.1.tar.gz")
        self.assertEqual(binding["runnerSha256"], "4ef2f25285f0ae4477f1fe1e346db76d2f3ebf03824e2ddd1973a2819bf6c8cf")
        self.assertIn("https://github.com/actions/runner/releases/download/v2.335.1/actions-runner-linux-x64-2.335.1.tar.gz", rendered)
        self.assertIn("sha256sum -c -", rendered)
        self.assertIn("4ef2f25285f0ae4477f1fe1e346db76d2f3ebf03824e2ddd1973a2819bf6c8cf", rendered)
        self.assertNotIn("https://api.github.com/repos/actions/runner/releases/latest", rendered)


    def test_example_plan_contains_shared_package_cache_contract(self):
        cfg, _ = normalize_config(self.example())
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        self.assertEqual(plan["sharedPackageCache"]["root"], "/mnt/actions-cache/packages")
        self.assertEqual(plan["sharedPackageCache"]["maxSizeGb"], 20)
        self.assertEqual(plan["sharedPackageCache"]["pruneAfterDays"], 14)
        self.assertTrue(all(b["sharedPackageCache"]["enabled"] for b in plan["runnerBindings"]))
        self.assertIn("npm", plan["sharedPackageCache"]["packageManagers"])
        self.assertIn("nuget", plan["sharedPackageCache"]["packageManagers"])

    def test_cloud_init_configures_shared_package_cache(self):
        cfg, _ = normalize_config(self.example())
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        rendered = render_cloud_init(plan["runnerBindings"][0], ROOT / "templates" / "cloud-init-runner.yaml.tmpl")
        self.assertIn("SHARED_PACKAGE_CACHE_ROOT='/mnt/actions-cache/packages'", rendered)
        self.assertIn("NPM_CONFIG_CACHE='/mnt/actions-cache/packages/npm'", rendered)
        self.assertIn("NUGET_PACKAGES='/mnt/actions-cache/packages/nuget/packages'", rendered)
        self.assertIn("PIP_CACHE_DIR='/mnt/actions-cache/packages/pip'", rendered)
        self.assertIn('find "$SHARED_PACKAGE_CACHE_ROOT" -type f -mtime +"$SHARED_PACKAGE_CACHE_PRUNE_AFTER_DAYS" -delete', rendered)
        self.assertIn("Dir::Cache::archives", rendered)

    def test_shared_package_cache_requires_absolute_dedicated_path(self):
        raw = self.example()
        raw["defaults"]["sharedPackageCache"]["root"] = "relative-cache"
        with self.assertRaisesRegex(ConfigError, "absolute Linux path"):
            normalize_config(raw)

    def test_arm64_pool_rejects_x64_vm_size(self):
        raw = self.example()
        raw["runnerPools"][0]["arch"] = "arm64"
        raw["runnerPools"][0]["labels"] = ["self-hosted", "linux", "arm64", "azure", "sh-linux"]
        raw["runnerPools"][0]["azure"]["vmSize"] = "Standard_D2s_v5"
        with self.assertRaisesRegex(ConfigError, "arch arm64 requires"):
            normalize_config(raw)

    def test_arm64_pool_uses_arm64_runner_asset_checksum_and_arm_vm_size(self):
        raw = self.example()
        raw["runnerPools"][0]["arch"] = "arm64"
        raw["runnerPools"][0]["labels"] = ["self-hosted", "linux", "arm64", "azure", "sh-linux"]
        raw["runnerPools"][0]["azure"]["vmSize"] = "Standard_D2ps_v5"
        cfg, _ = normalize_config(raw)
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        binding = plan["runnerBindings"][0]
        rendered = render_cloud_init(binding, ROOT / "templates" / "cloud-init-runner.yaml.tmpl")
        self.assertEqual(binding["vmSize"], "Standard_D2ps_v5")
        self.assertEqual(binding["vmArchitecture"], "arm64")
        self.assertEqual(binding["runnerAssetName"], "actions-runner-linux-arm64-2.335.1.tar.gz")
        self.assertEqual(binding["runnerSha256"], "6d1e85bfd1a506a8b17c1f1b9b57dba458ffed90898799aaa9f599520b0d9207")
        self.assertIn("actions-runner-linux-arm64-2.335.1.tar.gz", rendered)
        self.assertIn("6d1e85bfd1a506a8b17c1f1b9b57dba458ffed90898799aaa9f599520b0d9207", rendered)

    def test_token_provider_environment_contains_per_binding_context(self):
        cfg, _ = normalize_config(self.example())
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        binding = plan["runnerBindings"][0]
        env = token_provider_environment(binding)
        self.assertEqual(env["GHA_REGISTRATION_TOKEN_ENDPOINT"], binding["registrationTokenEndpoint"])
        self.assertEqual(env["GHA_RUNNER_URL"], binding["runnerUrl"])
        self.assertEqual(env["GHA_RUNNER_SCOPE"], binding["target"]["runnerScope"])
        self.assertEqual(env["GHA_BINDING_NAME"], binding["bindingName"])

    def test_apply_fails_before_az_when_vm_credential_source_unresolved(self):
        cfg, _ = normalize_config(self.example())
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        with patch.dict("os.environ", {}, clear=True), patch("tools.runner_config.subprocess.run") as run:
            with self.assertRaisesRegex(ConfigError, "vmCredentialSource"):
                apply_azure(plan, ROOT, allow_scale_down=False, confirm_spend=SPEND_CONFIRMATION)
        run.assert_not_called()

    def test_live_apply_resolves_vm_credential_env_refs_before_rendering_cloud_init(self):
        def fake_run(cmd, *args, **kwargs):
            if cmd[:3] == ["az", "account", "show"]:
                return type("Result", (), {"stdout": '{"tenantId":"tenant-test","id":"sub-test"}', "returncode": 0})()
            if cmd[:3] == ["az", "vmss", "show"]:
                return type("Result", (), {"stdout": "", "returncode": 1})()
            raise RuntimeError("mutation refused")

        env = {
            "AZURE_TENANT_ID": "tenant-test",
            "AZURE_SUBSCRIPTION_ID": "sub-test",
            "GITHUB_APP_KEY_VAULT_NAME": "kv-test",
        }
        with patch.dict("os.environ", env, clear=True), patch("tools.runner_config.subprocess.run", side_effect=fake_run):
            cfg, _ = normalize_config(self.example())
            plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
            for binding in plan["runnerBindings"]:
                self.assertEqual(binding["tokenProviderContract"]["vmEnvironment"]["AZURE_KEY_VAULT_NAME"], "kv-test")
            with self.assertRaisesRegex(RuntimeError, "mutation refused"):
                apply_azure(plan, ROOT, allow_scale_down=False, confirm_spend=SPEND_CONFIRMATION)

        for binding in plan["runnerBindings"]:
            self.assertEqual(binding["tokenProviderContract"]["vmEnvironment"]["AZURE_KEY_VAULT_NAME"], "kv-test")
            rendered = (ROOT / binding["renderedCloudInit"]).read_text(encoding="utf-8")
            self.assertIn("AZURE_KEY_VAULT_NAME='kv-test'", rendered)
            self.assertNotIn("${GITHUB_APP_KEY_VAULT_NAME}", rendered)

    def test_apply_rejects_github_token_only_command_provider_before_az(self):
        raw = self.example()
        del raw["defaults"]["github"]["tokenProvider"]["vmCredentialSource"]
        cfg, _ = normalize_config(raw)
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        with patch("tools.runner_config.subprocess.run") as run:
            with self.assertRaisesRegex(ConfigError, "not VM-executable"):
                apply_azure(plan, ROOT, allow_scale_down=False, confirm_spend=SPEND_CONFIRMATION)
        run.assert_not_called()

    def test_apply_fails_before_az_when_env_provider_unset(self):
        raw = self.example()
        raw["defaults"]["github"]["tokenProvider"] = {"type": "env", "env": "MISSING_RUNNER_TOKEN"}
        cfg, _ = normalize_config(raw)
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        with patch.dict("os.environ", {}, clear=True), patch("tools.runner_config.subprocess.run") as run:
            with self.assertRaisesRegex(ConfigError, "not VM-executable"):
                apply_azure(plan, ROOT, allow_scale_down=False, confirm_spend=SPEND_CONFIRMATION)
        run.assert_not_called()

    def test_apply_fails_before_mutation_when_keyvault_provider_cannot_resolve(self):
        raw = self.example()
        raw["defaults"]["github"]["tokenProvider"] = {"type": "keyVault", "vault": "missing-vault", "secretName": "runner-token"}
        cfg, _ = normalize_config(raw)
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        with patch("tools.runner_config.subprocess.run") as run:
            with self.assertRaisesRegex(ConfigError, "not VM-executable"):
                apply_azure(plan, ROOT, allow_scale_down=False, confirm_spend=SPEND_CONFIRMATION)
        run.assert_not_called()

    def test_apply_requires_spend_confirmation_before_az_calls(self):
        cfg, _ = normalize_config(self.example())
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        with patch("tools.runner_config.subprocess.run") as run:
            with self.assertRaisesRegex(ConfigError, "confirm-spend"):
                apply_azure(plan, ROOT, allow_scale_down=False, confirm_spend=None)
        run.assert_not_called()

    def test_apply_fails_before_az_when_token_provider_command_missing(self):
        raw = self.example()
        raw["defaults"]["github"]["tokenProvider"]["command"] = "scripts/not-real.sh"
        cfg, _ = normalize_config(raw)
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        with patch("tools.runner_config.subprocess.run") as run:
            with self.assertRaisesRegex(ConfigError, "not VM-executable"):
                apply_azure(plan, ROOT, allow_scale_down=False, confirm_spend=SPEND_CONFIRMATION)
        run.assert_not_called()

    def test_render_cloud_init_rejects_github_token_only_command_provider(self):
        raw = self.example()
        del raw["defaults"]["github"]["tokenProvider"]["vmCredentialSource"]
        cfg, _ = normalize_config(raw)
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        with self.assertRaisesRegex(ConfigError, "not VM-executable for cloud-init render"):
            render_cloud_init(plan["runnerBindings"][0], ROOT / "templates" / "cloud-init-runner.yaml.tmpl")

    def test_render_cloud_init_rejects_env_provider(self):
        raw = self.example()
        raw["defaults"]["github"]["tokenProvider"] = {"type": "env", "env": "MISSING_RUNNER_TOKEN"}
        cfg, _ = normalize_config(raw)
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        with self.assertRaisesRegex(ConfigError, "not VM-executable for cloud-init render"):
            render_cloud_init(plan["runnerBindings"][0], ROOT / "templates" / "cloud-init-runner.yaml.tmpl")

    def test_render_cloud_init_rejects_keyvault_provider(self):
        raw = self.example()
        raw["defaults"]["github"]["tokenProvider"] = {"type": "keyVault", "vault": "missing-vault", "secretName": "runner-token"}
        cfg, _ = normalize_config(raw)
        plan = build_azure_plan(cfg, ROOT / "config" / "runners.example.yaml")
        with self.assertRaisesRegex(ConfigError, "not VM-executable for cloud-init render"):
            render_cloud_init(plan["runnerBindings"][0], ROOT / "templates" / "cloud-init-runner.yaml.tmpl")


if __name__ == "__main__":
    unittest.main()
