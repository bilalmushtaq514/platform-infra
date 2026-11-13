# Azure DevOps screenshots

Captured 2026-11-13 from `dev.azure.com/bilalmushtaq514/hybrid-platform` (the project is private, so these stand in for read access).
The matching terminal output is in [../verification.md](../verification.md).

| Screenshot | Shows | Requirement |
|---|---|---|
| [01-pipelines-overview](01-pipelines-overview.png) | The three pipelines, all green | P-3 |
| [02-all-runs](02-all-runs.png) | Full run history, including the failed runs (legacy build issues, deliberate breaks) | §3.3, B-1 |
| **Pipeline A – modern app → AKS** | | |
| [10-A-run125-success-v2](10-A-run125-success-v2.png) | Build/test/package → deploy to AKS, v2 change | A-1…A-6, §3.3 #4 |
| [11-A-run125-tests](11-A-run125-tests.png) | Published test results (unit, integration, functional) | A-1 |
| [12-A-run125-coverage](12-A-run125-coverage.png) | Published code coverage | A-1 |
| [13-A-run123-broken-deploy-caught](13-A-run123-broken-deploy-caught.png) | Bad readiness probe → "Rollout did not become ready - rolling back", run failed | A-5, §3.3 #5 |
| **Pipeline B – legacy app → private IIS** | | |
| [20-B-run113-build-proof](20-B-run113-build-proof.png) | First successful MSBuild on a hosted `windows-2022` agent (after the MSB3644 fix) | §2.2 build proof |
| [21-B-run121-first-rolling-deploy](21-B-run121-first-rolling-deploy.png) | Build → approval → rolling deploy (3 servers) → ILB verification | B-1…B-6 |
| [22-B-run124-broken-deploy-caught](22-B-run124-broken-deploy-caught.png) | `UseMockData=false` → iisdev01 fails health, rolled back on that server; "Remaining servers were NOT touched" | B-5, §3.3 #5 |
| [23-B-run126-v2-and-stage-rerun](23-B-run126-v2-and-stage-rerun.png) | v2 deploy; later "Rerun stage" used as rollback path 2 | §3.3 #4, B-7 |
| [24-B-run126-tests](24-B-run126-tests.png) | MSTest results from the .NET Framework test project | B-1 |
| [25-B-run127-rollback](25-B-run127-rollback.png) | `action=rollback` run: every server switched back to its previous release | B-7 |
| **Infra pipeline (bonus)** | | |
| [30-infra-run129-plan-approval-apply](30-infra-run129-plan-approval-apply.png) | Validate → Plan → approval → Apply. "56.5% tests passed" is the **Checkov** report (43 pass / 33 report-only findings, triaged in [security.md](../../security.md#checkov-findings-infra-pipeline-report-only)), not app tests | Bonus: plan + approved apply |
| **Environments** | | |
| [40-environments](40-environments.png) | `aks-dev`, `iis-dev`, `infra-dev` | A-6, B-3 |
| [41-iis-dev-vm-resources](41-iis-dev-vm-resources.png) | **iisdev01/02/03 registered as VM resources** (outbound-only agents) | B-3 |
| [42-iis-dev-deployment-history](42-iis-dev-deployment-history.png) | Deployment history incl. the failed (deliberately broken) one | B-3, B-7 |
| [43-iis-dev-approvals-checks](43-iis-dev-approvals-checks.png) | Manual **Approval** check on `iis-dev` | B-6 |
| [44-aks-dev-deployment-history](44-aks-dev-deployment-history.png) | AKS deployment history per commit | A-6 |
| [45-infra-dev-deployment-history](45-infra-dev-deployment-history.png) | Approved Terraform apply | Bonus |
| **Plumbing** | | |
| [50-service-connections-oidc](50-service-connections-oidc.png) | GitHub App connection + two ARM connections using **Workload Identity federation** (no secrets) | P-1, I-9 |
| [51-variable-groups](51-variable-groups.png) | `platform-dev` / `platform-infra-dev` (non-secret Terraform outputs) | P-1 |
