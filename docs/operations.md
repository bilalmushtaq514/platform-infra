# Operations: rollback, failure handling, teardown, cost

## Rollback

### Modern app (AKS)

| Situation | What happens / what to do |
|---|---|
| New pods never become Ready | `maxUnavailable: 0` keeps the old pods serving. `rollout status` times out, the pipeline runs `kubectl rollout undo`, and the run fails. **Automatic.** |
| Smoke test fails after the rollout | The pipeline runs `kubectl rollout undo` and the run fails. **Automatic.** |
| A bad version is found later | Option 1: in Azure DevOps → pipeline A → an earlier green run → **Rerun stage `Deploy_AKS_dev`**. It redeploys that run's image tag (the image is still in ACR). Option 2: `kubectl -n eshop rollout undo deploy/eshop-web [--to-revision=N]`. The `change-cause` annotation shows which build each revision is. Option 3: `git revert` and push (the normal path). |

### Legacy app (IIS)

| Situation | What happens / what to do |
|---|---|
| A server fails its health check after the switch | `Deploy-IisSite.ps1` points **that** server back to its previous release folder, restarts it, re-checks it and exits 1. The rolling job stops, so the remaining servers keep the old version. **Automatic, per server.** |
| A bad version is found after a full rollout | Run pipeline B with **`action = rollback`** (and `rollbackTo = previous` or a specific BuildId). It skips the build and, behind the same approval and one server at a time, switches each server back to its previous release folder. No artifact download, so it takes seconds per server. |
| Need an exact older build | Open that older run → **Rerun stage `Deploy_IIS_dev`**. Its own artifact is redeployed (artifacts are retained with the run). |

Every server keeps the last 5 releases under `C:\inetpub\eshop\releases\<BuildId>`,
plus `release-history.txt`. That's what makes rollback a pointer switch, not a redeploy.

### What if an IIS node dies in the middle of a deployment?

* **The node is down before its turn:** the agent is offline, so the rolling job for that VM fails and the run fails. The other nodes already updated stay on the new version, and nodes not yet reached stay on the old one. The ILB probe has already removed the dead node, so users see no errors. Fix the node and re-run the failed job. The same artifact is deployed (idempotent: the release folder is recreated).
* **The node dies during its own deployment:** same as above. The script never touched the other nodes.
* **Mixed versions during a rollout** are expected and short-lived. That's why the health check validates the build stamp per node. The app is stateless (mock data), so mixed versions are safe here. With a real database, schema changes would need to be backward compatible (expand/contract).

## Verification commands

```bash
# Modern app is public
curl -s http://eshop-hybrid-dev.eastus2.cloudapp.azure.com/health/ready
# Legacy app is NOT reachable from the Internet (no public IP anywhere in the IIS tier)
az network public-ip list -g rg-hybrid-dev-eus2 --query "[].{name:name,ip:ipAddress,attachedTo:ipConfiguration.id}" -o table
az vm list-ip-addresses -g rg-hybrid-dev-eus2 -o table
curl -m 5 http://10.20.10.10/health      # from a laptop: times out (RFC1918, no route)
# Legacy app IS reachable inside the VNet, and load balanced
kubectl run ilb --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  sh -c 'for i in $(seq 1 9); do curl -s http://10.20.10.10/health; echo; done'
```

## Teardown

```bash
# 1. Everything except state + Key Vault (about 10-15 min)
cd envs/dev && terraform destroy
# 2. State storage + platform Key Vault (only when completely done)
cd ../../bootstrap && terraform destroy
# Key Vault is soft-deleted for 7 days; purge it to reuse the name:
az keyvault purge --name <kv-name>
# 3. Azure DevOps side (optional)
az devops service-endpoint delete --id <id> ...      # sc-azure-apps, sc-azure-infra
az ad app delete --id <appId>                       # sp-azdo-hybrid-apps, sp-azdo-hybrid-infra
# Environment VM resources disappear when the VMs are destroyed (agents go offline),
# remove them in Environments → iis-dev → Resources.
```

## Rebuild after teardown

On 2026-11-13, after all evidence was captured, **all Azure resources were destroyed** (dev platform + bootstrap).
The Azure DevOps project (pipelines, run history, environments + approval checks, service connections,
variable groups) and the two Entra app registrations were **kept**, and they cost nothing while idle.

| Step | Time | Command |
|---|---|---|
| 1. Bootstrap (state + Key Vault; new random suffix) | ~5 min | `cd bootstrap && terraform apply` → `terraform output -raw backend_hcl > ../envs/dev/backend.hcl` |
| 2. Give the infra SP state access again | — | already in `bootstrap/terraform.tfvars` (`state_contributor_object_ids`) |
| 3. New agent PAT → Key Vault (the old one expired / was deleted with the vault) | ~5 min, human | `read -rs PAT && az keyvault secret set --vault-name <new-kv> --name azdo-agent-pat --value "$PAT"; unset PAT` |
| 4. Update `envs/dev/terraform.tfvars` with the new KV name, then apply | ~20-25 min | `cd envs/dev && terraform init -reconfigure -backend-config=backend.hcl && terraform apply` |
| 5. Refresh variable groups (new ACR name, VM IPs, state account, KV) | ~1 min | `ORG=… PROJECT=hybrid-platform scripts/setup-azdo-variable-groups.sh` (run from `envs/dev`) |
| 6. Remove the 3 stale offline VM resources from `iis-dev` if duplicates appear | ~2 min | Environments → iis-dev → Resources |
| 7. Run pipeline A, then B (approve) | ~20 min | images and app releases are rebuilt from Git |

Unchanged after a rebuild: the app FQDN `eshop-hybrid-dev.eastus2.cloudapp.azure.com`, the ILB IP `10.20.10.10`,
and all CIDRs. Public IPs, the ACR name and VM private IPs change; the evidence docs keep the original values.

### Cost control between work sessions

```bash
az vm deallocate --ids $(az vm list -g rg-hybrid-dev-eus2 --query "[].id" -o tsv)   # stops Windows compute billing
az aks stop -g rg-hybrid-dev-eus2 -n aks-hybrid-dev-eus2
terraform apply -var enable_bastion=false                                            # Bastion is ~$0.19/h
```

| Item (eastus2, pay-as-you-go) | Approx. per hour |
|---|---|
| 3 × B2ms Windows | ~$0.50 |
| AKS: 1 × B2ms node (Free tier control plane) | ~$0.08 |
| Bastion Basic | ~$0.19 |
| NAT Gateway + 3 public IPs + 2 LBs | ~$0.10 |
| **Total running** | **~$0.90/h** (about $22/day; deallocated: about $2/day for disks/IPs) |

## What I would improve with more time

1. **TLS on the modern app**: App Routing add-on + cert-manager + Let's Encrypt for the cloudapp FQDN (also fixes login, whose cookies are Secure-only).
2. **Real data stores**: Azure SQL (legacy) and Postgres/Azure SQL (modern) with Private Endpoints; shared ASP.NET data-protection keys.
3. **Private everything**: private AKS API, Private Endpoints for ACR (Premium), Key Vault and state storage, and a self-hosted VMSS agent pool in the VNet.
4. **VM Scale Set for IIS**, with the image baked by Packer (IIS + agent pre-installed). That makes scale-out and replacement faster and more consistent than Run Command at boot.
5. **Canary or blue/green on AKS** (Argo Rollouts / Flagger), driven by the readiness and error-rate metrics already flowing to Log Analytics.
6. **Alerting**: Azure Monitor availability tests on the public `/health/ready`, a log alert on ILB probe health, AKS restart alerts, all wired to an action group.
7. **Policy**: Azure Policy for "no public IP on NICs in snet-iis", required tags, allowed SKUs.
8. **Agent hardening**: low-privilege service account instead of LocalSystem; PAT replaced by a short-lived, automation-issued token.
9. **Terraform**: tflint + terratest; a `prod` environment root reusing the same modules; azurerm 5.x upgrade.
10. **Legacy app**: upgrade the vulnerable packages behind a regression suite, then plan the port to .NET 10.
