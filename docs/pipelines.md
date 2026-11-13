# CI/CD

Azure DevOps organisation `bilalmushtaq514`, project **`hybrid-platform`**.
GitHub is connected with the **Azure Pipelines GitHub App** (installation-token
connection; GitHub sends webhooks, nothing polls). All pipelines are YAML in
their own repo.

| Pipeline | Repo / file | Trigger | Environments |
|---|---|---|---|
| **A - eShopOnWeb to AKS** | `eShopOnWeb/azure-pipelines.yml` | push `main` → build+deploy · PR → build+test only | `aks-dev` |
| **B - eShopLegacyMVC to private IIS** | `eShopModernizing/azure-pipelines.yml` | push `main` → build+deploy · PR → build+test only | `iis-dev` (approval) |
| **platform-infra** | `platform-infra/azure-pipelines.yml` | push `main` → plan+apply · PR → validate+plan | `infra-dev` (approval) |

Shared plumbing (created by `scripts/`, not by hand):

| Object | Purpose | Secret? |
|---|---|---|
| `sc-azure-apps` | ARM service connection, **workload identity federation**. SP has AcrPush + AKS user + AKS RBAC admin only | none |
| `sc-azure-infra` | ARM service connection, WIF. SP has Contributor + RBAC Administrator on the subscription; **not** authorised for app pipelines | none |
| `platform-dev` | variable group: `ACR_NAME`, `AKS_NAME`, `AKS_RESOURCE_GROUP`, `IIS_LB_IP`, `IIS_VM_IPS` (Terraform outputs) | none |
| `platform-infra-dev` | variable group: subscription id, state account, KV name, deployer ids | none |
| `aks-dev` | Environment for the AKS deployment history | — |
| `iis-dev` | Environment with **3 VM resources** (the IIS servers) + **Approval** check | — |
| `infra-dev` | Environment with **Approval** check (review the plan, then apply) | — |

There is not a single secret in any YAML file or variable group (P-1).

---

## Pipeline A – modern app → AKS

```
Build_Test_Package (ubuntu-24.04)                       Deploy_AKS_dev (main only, env aks-dev)
┌──────────────────────────────────────────────────┐    ┌──────────────────────────────────────────────┐
│ tag = <BuildId>-<sha7>                           │    │ download manifests artifact                  │
│ dotnet restore / build (Web + 3 test projects)   │    │ az aks get-credentials + kubelogin (OIDC)    │
│ dotnet test  Unit, Integration, Functional       │    │ kustomize edit set image eshop-web=<acr>:tag │
│   → PublishTestResults + Cobertura coverage      │──▶ │ kubectl apply -k overlays/dev                │
│ dotnet list package --vulnerable                 │    │ kubectl rollout status (240s)  ──fail──┐     │
│ docker build (multi-stage, non-root)             │    │ curl http://<public-ip>/health/ready   │     │
│ Trivy: fail on fixable CRITICAL                  │    │ home page must show "build <tag>" ─────┤     │
│ az acr login (OIDC) + docker push   [main only]  │    │                     kubectl rollout undo     │
│ publish deploy/k8s as artifact "manifests"       │    │                     + fail the run  ◀───┘    │
└──────────────────────────────────────────────────┘    └──────────────────────────────────────────────┘
```

* **A-1** tests + `PublishTestResults@2` + `PublishCodeCoverageResults@2`.
* **A-2** `src/Web/Dockerfile`: SDK build stage, ASP.NET runtime stage, `USER $APP_UID` (1654), `.dockerignore`.
* **A-3** image tag `<BuildId>-<sha7>`, e.g. `acrhybriddevkdk6.azurecr.io/eshop-web:120-02cb194`. `latest` is never used.
* **A-4** `deploy/k8s` (kustomize): Deployment ×2 with startup/liveness/readiness probes, requests/limits,
  `readOnlyRootFilesystem`, PDB, NetworkPolicy, `Service type=LoadBalancer` with DNS label.
* **A-5** `rollout status` + external smoke test; on failure `kubectl rollout undo` and the run fails.
  `maxUnavailable: 0` means users keep hitting the old pods while new ones fail readiness.
* **A-6** `deployment` job bound to Environment `aks-dev` → deployment history per commit.
* **P-2** the image is built once in stage 1; stage 2 only references it by tag. PRs never push.

## Pipeline B – legacy app → private IIS

```
Build_Test_Package (windows-2022)          Deploy_IIS_dev (env iis-dev, APPROVAL, rolling maxParallel=1)       Verify_Through_ILB
┌─────────────────────────────────────┐    ┌────────────────────────────────────────────────────────────┐   ┌──────────────────────────┐
│ NuGet restore (sln)                 │    │ for each VM (iisdev01 → 02 → 03), on the VM's own agent:   │   │ pod in AKS (inside VNet):│
│ stamp BuildVersion in Web.config    │    │   download artifact                                        │   │  curl each node /health  │
│ MSBuild publish  (Release transform)│──▶ │   FileTransform: EnvironmentName, UseMockData (per env)    │──▶│  curl ILB 12× /health    │
│   /p:TargetFrameworkVersion=v4.7.2  │    │   Deploy-IisSite.ps1:                                      │   │  → distinct server names │
│ MSBuild + VSTest (MSTest, coverage) │    │     unzip → releases\<BuildId>                             │   │  any non-200 → fail      │
│ verify transformed Web.config       │    │     stop site + pool → repoint physicalPath → start        │   └──────────────────────────┘
│ zip → artifact "legacy-site"        │    │     GET http://localhost/health == 200 && build == new?    │
└─────────────────────────────────────┘    │       no → restore previous release on THIS server, exit 1 │
                                           │            → run stops, remaining servers untouched        │
                                           └────────────────────────────────────────────────────────────┘
```

### How the pipeline reaches servers that have no inbound access (B-3)

The IIS VMs are **resources of the `iis-dev` Environment**. During
provisioning, `iis-bootstrap.ps1` installs the Azure Pipelines agent on each VM
and registers it with `--environment --environmentname iis-dev` (tag `iis`).

* The agent service opens an **outbound** HTTPS (443) long-poll to
  `dev.azure.com`, leaving through the **NAT Gateway**. When a deployment job
  targets `iis-dev`, Azure DevOps hands the job to the agent over that existing
  connection. **No inbound port, public IP, WinRM, SMB or VPN is needed**, and
  the NSG still denies everything from the Internet.
* The registration PAT is read **once**, at bootstrap, from Key Vault using the
  VM's managed identity. After registration the agent authenticates with its
  own OAuth token, so the PAT can expire or be revoked without breaking deploys.
* Alternative considered: one self-hosted agent VM inside the VNet pushing via
  WinRM to the 3 servers. Rejected: it needs inbound 5985/5986 on the IIS
  subnet, credential handling for WinRM, and a fourth Windows VM.

### Requirements map

* **B-1** NuGet restore + MSBuild (`VSBuild@1`) + VSTest + zipped published folder.
* **B-2** `Web.Release.config` (build-time, same everywhere) + `FileTransform@1`
  XML variable substitution of `EnvironmentName`/`UseMockData` (deploy-time,
  per environment). The build stamp is baked in at build time so the artifact is immutable.
* **B-4** `strategy: rolling, maxParallel: 1`; the script stops site and pool,
  switches the release, starts the pool and site, per server.
* **B-5** per-server `localhost/health` must return 200 **and** report the new
  build; then a pod in AKS checks every node and the **internal LB** (12 requests,
  showing several server names). Any non-200 fails the run.
* **B-6** Approval check on `iis-dev`: nothing touches a server until a human approves.
* **B-7** Rollback, see [operations.md](operations.md#rollback).

## platform-infra pipeline (bonus)

`Validate` (fmt, validate, Checkov) → `Plan` (plan file + readable plan
artifacts) → `Apply` (main only, `infra-dev` approval, applies **the exact plan
file that was reviewed**). Auth: `sc-azure-infra` OIDC token exported as
`ARM_OIDC_TOKEN` for both provider and backend.

## End-to-end flows

### Modern app: developer commit → user sees new version

1. Developer pushes to `main` on `bilalmushtaq514/eShopOnWeb`.
2. The GitHub App webhook triggers pipeline A (PRs run stage 1 only).
3. Tests, coverage, vulnerability report and image scan run. The image is tagged `<BuildId>-<sha>` and pushed to ACR using the OIDC identity.
4. The `aks-dev` deployment job sets that tag in the kustomize overlay and runs `kubectl apply`.
5. AKS starts a 3rd pod (`maxSurge 1`). The kubelet pulls from ACR with its managed identity.
6. The new pod becomes Ready (`/health/ready`), an old pod is removed, and this repeats for the second replica.
7. The pipeline checks rollout status, then `curl`s the public IP. The home page banner must show the new tag.
8. A user refreshes `http://eshop-hybrid-dev.eastus2.cloudapp.azure.com` and sees `build <BuildId>-<sha> · pod eshop-web-…`.

### Legacy app: developer commit → user sees new version

1. Developer pushes to `main` on `bilalmushtaq514/eShopModernizing`.
2. The webhook triggers pipeline B, and a windows-2022 agent builds, tests and zips the site. The build version is stamped into Web.config.
3. Stage 2 pauses on the **`iis-dev` approval**. The approver sees the commit, build and test results.
4. After approval, the `iisdev01` agent (already connected outbound) picks up the job and deploys. Its own `/health` must report the new build.
5. While `iisdev01`'s pool is stopped, the ILB probe marks it down within about 10 s, so users are served by 02 and 03.
6. The same happens on `iisdev02`, then `iisdev03`.
7. A pod in AKS curls every node and the ILB. Every response is 200 with the new build, and requests rotate across servers.
8. A user inside the network (Bastion session, VPN, or an AKS workload) browses to `http://10.20.10.10` and sees `build <BuildId>-<sha> · env dev · server iisdev0N`.

## Problems hit while building this (and the fixes)

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| B #112 | `MSB3644` .NETFramework v4.6.1 reference assemblies not found | `eShopLegacy.Utilities` targets net461; the current `windows-2022` image ships an incomplete 4.6.1 targeting pack | Global `/p:TargetFrameworkVersion=v4.7.2` (same TFM as the web app; servers run 4.8). No project edits |
| B #116 | `NU1605` package downgrade, test build fails | Upstream web project pins `DiagnosticSource 4.5.1` while `Autofac 6.1.0` needs ≥ 4.7.1. `nuget.exe` treats it as a warning, but `msbuild /restore` on an SDK test project makes it an error | Restore the test project with the same `nuget.exe` step; keep NU1605 a warning in the test project only |
| B #119 | Publish "succeeded" but `site\` was empty | `DeployOnBuild` on a classic web project defaults to the *Package* target and ignores `publishUrl` | `/p:DeployDefaultTarget=WebPublish` |
| B (early) | Deploy script missing from the artifact | Upstream `.gitignore` ignores `/deploy` | Script moved to `iis-deploy/` |
| A #114 | Healthy deploy reported as failed | `curl … \| grep -q` under `set -o pipefail`: grep exits on the first match, and curl gets SIGPIPE | Capture the page into a variable, then grep; with retries |
| A (local) | Container exits at start | Aspire Seq integration refuses to start without a Seq URL | `Aspire__Seq__DisableHealthChecks=true` in the ConfigMap (config, not code) |
| Infra | Run Command rejected empty parameters | Azure Run Command API refuses `""` parameter values (agent disabled on the first apply) | `dynamic "parameter"` sends only non-empty values |
| Infra | Pipeline apply would remove the human's AKS access | `deployer_object_ids` included "current caller" | Explicit list in tfvars / variable group |
| ADO | Runs queue one at a time | Free tier = 1 Microsoft-hosted parallel job | Accepted (cost); noted under improvements |
| ADO | `**/*.md` didn't exclude root `README.md` | Azure DevOps path filters: `**/` needs a directory segment | Added `*.md` as well |
| Design | ILB check can't run on an IIS VM | A Standard internal LB doesn't hairpin a backend's own traffic back to itself | Verification runs from a pod in AKS (also proves AKS → legacy connectivity) |
| Infra #128 | `terraform init` on the Linux agent: provider checksum doesn't match the lock file | Lock file was generated on macOS arm64 only | `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64` |
