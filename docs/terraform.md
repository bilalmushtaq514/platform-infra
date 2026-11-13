# Terraform

## Layout

```
platform-infra/
├── bootstrap/                 # run ONCE, local state: tfstate storage + platform Key Vault
├── envs/
│   └── dev/                   # the environment root: composes modules, remote state
│       ├── main.tf            # RG, Log Analytics, module calls
│       ├── variables.tf       # every knob, with defaults (CIDRs, sizes, counts)
│       ├── outputs.tf
│       ├── versions.tf        # provider pins + `backend "azurerm" {}` (partial config)
│       ├── backend.hcl.example
│       └── terraform.tfvars.example
├── modules/
│   ├── network/               # VNet, 3 subnets, NSGs, NAT Gateway
│   ├── aks/                   # ACR + AKS (+ identities, role assignments)
│   ├── iis-tier/              # N Windows VMs, internal LB, probe, Run Command bootstrap
│   │   └── scripts/iis-bootstrap.ps1
│   └── bastion/               # Azure Bastion (toggle: enable_bastion)
├── pipelines/terraform-steps.yml
├── scripts/                   # one-off Azure DevOps wiring (service connections, environments)
└── azure-pipelines.yml        # validate -> plan -> (approval) -> apply
```

Conventions:

* **Naming**: `<type-abbrev>-<project>-<env>-<region>` (CAF style) –
  `rg-hybrid-dev-eus2`, `vnet-…`, `nsg-…-iis`, `lbi-…-iis`, `vm-…-iis-01`.
  Globally-unique names (ACR, storage, Key Vault) get a short random suffix.
* **Tags** on everything: `project`, `environment`, `managed_by=terraform`, `repo`.
* **Modules** take `name`, `location`, `resource_group_name`, `tags` + their own
  inputs, and expose only what callers need. Environments differ only by
  variables, so a `prod` root would be another ~100-line `main.tf`.
* `terraform fmt -recursive` and `terraform validate` pass (also enforced in CI).
* Providers pinned: `azurerm ~> 4.81`, `random ~> 3.7`; `.terraform.lock.hcl` committed.

## Remote state (I-7)

| Item | Value |
|---|---|
| Storage account | `sthybridtf<suffix>` in `rg-hybrid-tfstate-eus2`, ZRS |
| Container | `tfstate`, key `dev/platform.tfstate` |
| Auth | Entra ID only (`shared_access_key_enabled = false`, `use_azuread_auth = true`) |
| Locking | Native: the azurerm backend takes a **blob lease** on the state blob for every write; a second `apply` waits/fails with "state blob is already locked" |
| Recovery | Blob **versioning** + 14-day soft delete for blobs and containers |

Why a separate bootstrap stack: the storage account that holds state can't be
created by a configuration whose state lives in it. Bootstrap state is tiny,
contains no secrets and is kept locally (git-ignored).

## How to run

Prerequisites: Terraform ≥ 1.9, Azure CLI logged in (`az login`), Owner (or
Contributor + RBAC Administrator) on the subscription.

```bash
# 1. Once: state storage + platform Key Vault
cd bootstrap
echo 'subscription_id = "<sub-id>"' > terraform.tfvars
terraform init && terraform apply
terraform output -raw backend_hcl > ../envs/dev/backend.hcl

# 2. Azure DevOps wiring (OIDC service connections, environments, approvals)
ORG=https://dev.azure.com/<org> PROJECT=hybrid-platform ../scripts/setup-azdo-service-connections.sh
ORG=... PROJECT=... APPROVER=<email> ../scripts/setup-azdo-environments.sh

# 3. Store the one-time agent registration PAT (never in Git, never in TF state)
read -rs PAT && az keyvault secret set --vault-name <kv> --name azdo-agent-pat --value "$PAT"; unset PAT

# 4. The platform
cd ../envs/dev
cp terraform.tfvars.example terraform.tfvars   # fill in ids (no secrets in this file)
terraform init -backend-config=backend.hcl
terraform plan -out tfplan
terraform apply tfplan
```

After the first manual apply, changes go through the `platform-infra` pipeline
(plan on PR, apply on `main` after approval).

## What gets created (dev)

`terraform state list` output is in [`evidence/terraform-state-list.txt`](evidence/terraform-state-list.txt);
the plan is in [`evidence/terraform-plan-initial.txt`](evidence/terraform-plan-initial.txt).

## Design notes worth defending

* **IIS bootstrap via Run Command (v2)** instead of a Custom Script Extension
  that downloads a script from a URL: the script body travels inside the
  resource definition (no storage account/SAS, no GitHub raw dependency),
  parameters are explicit, and changing the script re-runs it. The script is
  idempotent, so re-runs are safe.
* **User-assigned identity for the AKS control plane** so `Network Contributor`
  on the BYO subnet exists *before* the cluster is created (system-assigned
  would race).
* **`deployer_object_ids` is an explicit list**, not "whoever runs Terraform" –
  otherwise a pipeline apply would remove the human's access and vice versa.
* **`lifecycle.ignore_changes`** on AKS `node_count` (autoscaler owns it) and
  `kubernetes_version` (auto-upgrade channel owns it) to avoid perpetual diffs.
* **Bastion is toggleable** (`enable_bastion=false`) because it is the most
  expensive always-on item after the VMs.
