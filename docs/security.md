# Configuration, secrets & security

## Configuration and secrets by component

| Component | Configuration | Secrets | Where they live |
|---|---|---|---|
| Terraform | `terraform.tfvars` (git-ignored; only ids/names), `backend.hcl` (git-ignored) | none it needs to know about. The VM admin password is **generated** (`random_password`) and written to Key Vault | State: Entra-auth-only storage, versioned |
| Pipelines → Azure | service connections `sc-azure-apps` / `sc-azure-infra` | **none**: workload identity federation; Azure DevOps mints a short-lived OIDC token per job | Federated credential on each app registration |
| Pipelines (non-secret values) | variable groups `platform-dev`, `platform-infra-dev` | none | Azure DevOps library |
| AKS → ACR | — | none: kubelet managed identity has `AcrPull`; ACR admin user disabled | Entra |
| Modern app | ConfigMap `eshop-web-config` (`ASPNETCORE_ENVIRONMENT=Docker`, `UseOnlyInMemoryDatabase=true`) | none needed (in-memory DB). Real-world: Key Vault via workload identity (OIDC issuer + WI already enabled on the cluster) | Git (manifests) |
| Legacy app | `Web.config` + `Web.Release.config` (build) + per-env substitution (`EnvironmentName`, `UseMockData`) at deploy | none needed (mock data). Real-world: connection string from Key Vault via the VM identity, or `aspnet_regiis` protected config | Git + pipeline stage variables |
| IIS agent registration | org/project/env passed by Terraform | ADO PAT (one-time) | **Key Vault only**, entered by a human with a hidden prompt; each VM's identity can read **only that secret** |
| VM local admin | username `iisadmin` | generated password | Key Vault secret `hybrid-dev-eus2-iis-admin-password` (break-glass via Bastion) |

What is in Git: Terraform code, manifests, YAML, scripts, `*.example` files.
What is never in Git (`.gitignore`): `*.tfstate*`, `*.tfvars`, `backend.hcl`, `tfplan*`.

## Security decisions

* **No inbound path from the Internet to the legacy tier**: no public IP, internal LB, NSG denies the Internet tag and everything not explicitly allowed, and default outbound access is disabled on the subnet.
* **Deployments are pulled, not pushed**: the VM agents dial out. WinRM/SMB/RDP are never opened for CI.
* **Admin access only via Bastion** (TLS to Bastion; RDP 3389 allowed only from `AzureBastionSubnet`).
* **No long-lived cloud credentials**: OIDC for pipelines, managed identities for workloads, Entra auth for state.
* **Least privilege split**: the app pipelines' identity can't change infrastructure. The infra identity is only usable from the infra pipeline, behind approval. It holds *RBAC Administrator*, not *Owner*.
* **AKS**: Entra ID + Azure RBAC, local accounts disabled, Cilium network policy, restricted Pod Security Admission on the app namespace, non-root read-only containers with all capabilities dropped, automatic patch and node-image upgrades, Container Insights to Log Analytics.
* **VMs**: Trusted Launch (Secure Boot + vTPM), platform-orchestrated patching (`AutomaticByPlatform`), boot diagnostics, spread across 3 zones.
* **Supply chain**: images tagged immutably by build and commit; Trivy blocks fixable CRITICAL CVEs; `dotnet list package --vulnerable` report; Checkov scans the Terraform.

## Known trade-offs and risks

| Risk / trade-off | Why accepted here | What I'd do in production |
|---|---|---|
| Modern app uses **EF in-memory DB per pod** → each replica has its own catalog/basket; data-protection keys are per pod | Brief asks for no external dependency; cheap | Azure SQL / Postgres Flexible + shared data-protection key ring (Blob + Key Vault). Until then, `sessionAffinity: ClientIP` keeps a browser on one pod |
| Modern app served over **HTTP**; its auth cookies are `Secure`, so **login needs HTTPS** (catalog/basket browsing works) | Time and cost | Ingress (App Routing add-on / NGINX) + cert-manager + Let's Encrypt on the cloudapp FQDN, or App Gateway for Containers + WAF |
| AKS **API server is public** (Entra auth only) | Microsoft-hosted agents have dynamic IPs | Private cluster or API server VNet integration + a self-hosted agent pool in the VNet, or authorised IP ranges |
| **ACR / Key Vault public endpoints** (RBAC-only) | Private endpoints need ACR Premium and private DNS zones | Private Endpoints + private DNS, `public_network_access_enabled=false` |
| The **Terraform plan artifact** contains sensitive values (e.g. the generated VM password) | Needed so the approved plan is what gets applied | Restrict artifact access, short retention, or regenerate the plan in the apply job and compare |
| **Agent runs as LocalSystem** on the IIS VMs | It must stop/start app pools and write under `C:\inetpub` | Dedicated low-privilege local account with IIS management rights only |
| **Single hosted parallel job** (free tier) | Free | Paid parallel jobs or self-hosted scale-set agents |
| **Legacy stack**: .NET Framework 4.7.2 / MVC 5 / EF6 with outdated packages (Newtonsoft.Json 12.0.1, bootstrap 4.3.1, jQuery 3.5.0, log4net 2.0.10, App Insights 2.9) with known CVEs; upstream repo archived | The brief says not to rewrite app logic; the app is only reachable inside the VNet, which limits exposure | Track as tech debt: package upgrades in a separate change with regression tests, enable Defender for Servers, then migrate to .NET 10 (the modern app shows the target) |
| `UseMockData=true`: catalog edits are in memory and **differ per IIS node** | No SQL needed, nodes stay identical and stateless for LB tests | Small Azure SQL with Private Endpoint; connection string from Key Vault |
| Bastion subnet has no custom NSG | Bastion's required rules are easy to get wrong | Add the documented Bastion NSG rule set |
| Windows Firewall rule for HTTP enabled on the hosts | Defence in depth; the NSG is the perimeter | Restrict the host firewall to `10.20.0.0/16` too |
