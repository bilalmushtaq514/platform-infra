# Architecture

## Diagram

```mermaid
flowchart LR
  dev([Developer]) -- git push --> ghA[(GitHub<br/>eShopOnWeb fork)]
  dev -- git push --> ghB[(GitHub<br/>eShopModernizing fork)]
  dev -- git push / PR --> ghI[(GitHub<br/>platform-infra)]

  subgraph ADO[Azure DevOps · hybrid-platform]
    pA[Pipeline A<br/>eShopOnWeb]
    pB[Pipeline B<br/>eShopLegacyMVC]
    pI[Pipeline I<br/>platform-infra]
    envA{{env aks-dev}}
    envB{{env iis-dev<br/>approval}}
    envI{{env infra-dev<br/>approval}}
  end
  ghA -- GitHub App webhook --> pA
  ghB -- GitHub App webhook --> pB
  ghI -- GitHub App webhook --> pI

  subgraph Azure[Azure · eastus2 · rg-hybrid-dev-eus2]
    acr[(ACR<br/>admin user OFF)]
    subgraph VNet[VNet 10.20.0.0/16]
      subgraph snetAks[snet-aks 10.20.0.0/22]
        aks[AKS · Azure CNI overlay + Cilium<br/>eshop-web x2 pods]
      end
      subgraph snetIis[snet-iis 10.20.10.0/24 · NO public IPs]
        ilb[Internal LB<br/>10.20.10.10 · probe /health]
        vm1[IIS VM 1<br/>+ ADO agent]
        vm2[IIS VM 2<br/>+ ADO agent]
        vm3[IIS VM 3<br/>+ ADO agent]
      end
      subgraph snetBas[AzureBastionSubnet 10.20.20.0/26]
        bas[Azure Bastion]
      end
    end
    nat[NAT Gateway<br/>egress only]
    plb[AKS public LB<br/>eshop-hybrid-dev.eastus2.cloudapp.azure.com]
    kv[(Key Vault<br/>agent PAT · VM password)]
    st[(Storage<br/>Terraform state)]
  end

  user([Internet user]) -- HTTP 80 --> plb --> aks
  aks -- AcrPull via kubelet MI --> acr
  pA -- OIDC: push image + kubectl --> acr
  pA -- OIDC: kubectl apply --> aks
  pI -- OIDC: terraform --> st
  ilb --> vm1 & vm2 & vm3
  aks -. pod curl (verification) .-> ilb
  vm1 & vm2 & vm3 -- outbound 443 only --> nat -- long-poll --> envB
  vm1 -. MI: read PAT once .-> kv
  admin([Admin]) -- HTTPS 443 --> bas -- RDP 3389 --> vm1
  user -. ✗ no route .-> ilb
```

## The two apps

| | Modern (A) | Legacy (B) |
|---|---|---|
| App | `eShopOnWeb` Web (ASP.NET Core MVC + Razor + Blazor admin) | `eShopLegacyMVC` (ASP.NET MVC 5) |
| Runtime | .NET 10 (LTS) in a Linux container | .NET Framework 4.7.2 on Windows Server 2022 / IIS 10 (CLR v4.0 pool) |
| Data | EF Core in-memory provider (`UseOnlyInMemoryDatabase=true`) | `UseMockData=true` (in-memory `CatalogServiceMock`) |
| Hosting | AKS Deployment, 2 replicas, `Service type=LoadBalancer` | 3 VMs across zones 1/2/3 behind a Standard **internal** LB |
| Exposure | Public: `http://eshop-hybrid-dev.eastus2.cloudapp.azure.com` | Private only: `http://10.20.10.10` (VNet) |
| Deploy mechanism | Hosted agent → ACR push → `kubectl apply -k` | Agent **on each VM** pulls the job (outbound) → rolling switch |

## Why this shape

* **One VNet, three purpose-built subnets.** AKS, IIS and Bastion have different
  trust levels, so each has its own subnet and NSG. A single VNet keeps the
  "AKS pod calls legacy app over the private network" path trivial (no peering).
* **Private legacy tier.** No public IPs on the VMs, an *internal* LB, an NSG
  that explicitly denies the Internet tag, and a subnet with *default outbound
  access disabled* so the only way out is the NAT Gateway.
* **Pull-based deployment to private servers.** Instead of opening WinRM/SMB/RDP
  to a build agent, each IIS VM runs the Azure Pipelines agent registered in an
  *Environment*. The agent only makes outbound HTTPS calls to `dev.azure.com`.
  This is what makes "deploy to servers with zero inbound exposure" possible.
* **Identity everywhere, secrets nowhere.**
  * Pipelines → Azure: workload identity federation (OIDC), no client secret.
  * AKS → ACR: kubelet managed identity with `AcrPull`, ACR admin user disabled.
  * Humans/pipelines → AKS: Entra ID + Azure RBAC, Kubernetes local accounts disabled.
  * IIS VMs → Key Vault: system-assigned identity with `Key Vault Secrets User` on
    **one secret** (the agent PAT), not the whole vault.
  * Terraform → state: Entra ID (`use_azuread_auth`), storage keys disabled.
