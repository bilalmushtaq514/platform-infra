# Network design

## Address plan

| Range | Purpose | Notes |
|---|---|---|
| `10.20.0.0/16` | VNet `vnet-hybrid-dev-eus2` | Room for future subnets (private endpoints, agents, App Gateway) |
| `10.20.0.0/22` | `snet-aks` – AKS nodes | 1 019 usable IPs. With **Azure CNI overlay** pods do *not* consume VNet IPs, so /22 is plenty for node scale-out |
| `10.20.10.0/24` | `snet-iis` – IIS VMs + ILB frontend | ILB frontend is static `10.20.10.10` (`cidrhost(subnet, 10)`), VMs get dynamic IPs |
| `10.20.20.0/26` | `AzureBastionSubnet` | Name and minimum /26 are mandated by Azure Bastion |
| `192.168.0.0/16` | AKS pod CIDR (overlay) | Not routable in the VNet; pods SNAT to the node IP when leaving the node |
| `172.16.0.0/16` | Kubernetes service CIDR | DNS service IP `172.16.0.10` |

None of the ranges overlap, so the VNet could later be peered with a hub or
on-premises network (`10.20/16` is the only routable block).

## NSG `nsg-hybrid-dev-eus2-iis` (snet-iis)

| Prio | Name | Dir | Source | Dest port | Action | Why |
|---:|---|---|---|---|---|---|
| 100 | Allow-HTTP-HTTPS-From-VNet | In | `10.20.0.0/16` | 80, 443 | Allow | App traffic from inside the VNet: AKS nodes/pods (SNAT to node IP), other IIS nodes |
| 110 | Allow-RDP-From-Bastion | In | `10.20.20.0/26` | 3389 | Allow | Admin access only via Bastion |
| 120 | Allow-AzureLoadBalancer-Probe | In | `AzureLoadBalancer` | 80 | Allow | ILB health probe (168.63.129.16) |
| 4000 | Deny-Internet-Inbound | In | `Internet` | * | **Deny** | Explicit, auditable "never from the Internet" (I-4) |
| 4096 | Deny-All-Other-Inbound | In | * | * | **Deny** | Overrides Azure's default `AllowVnetInBound` (65000), so even VNet sources only reach 80/443/3389 |
| — | (defaults) | Out | VNet | * | Allow | Egress to the Internet leaves via the NAT Gateway only |

Defence in depth for "not reachable from the Internet":

1. VMs have **no public IP** (NICs have no `public_ip_address_id`).
2. The LB is **internal** (frontend is a private IP in `snet-iis`).
3. The NSG **denies the Internet service tag** explicitly, then denies everything else.
4. The subnet has **`default_outbound_access_enabled = false`**; egress exists only
   through the **NAT Gateway**, which by design never accepts unsolicited inbound flows.

## NSG `nsg-hybrid-dev-eus2-aks` (snet-aks)

| Prio | Name | Source | Port | Action |
|---:|---|---|---|---|
| 100 | Allow-HTTP-HTTPS-From-Internet | Internet | 80, 443 | Allow |

Everything else uses Azure defaults (VNet + LB allowed, other Internet inbound denied).
Inside the cluster a Kubernetes `NetworkPolicy` (enforced by Cilium) only admits
port 8080 to the app pods.

## AzureBastionSubnet

No custom NSG: Azure Bastion requires a specific rule set (GatewayManager,
AzureLoadBalancer, BastionHostCommunication, outbound to VirtualNetwork 3389/22,
AzureCloud 443) and the platform-managed defaults are correct. Adding a
hand-written NSG here is a common way to break Bastion, so it's listed under
improvements instead.

## Egress

| Tier | Egress path | Why |
|---|---|---|
| IIS VMs | NAT Gateway `ng-hybrid-dev-eus2` (static IP) | Windows Update, agent download, agent long-poll to `dev.azure.com:443`, Key Vault |
| AKS nodes | AKS-managed Standard LB outbound rules | Default for AKS; image pulls from MCR/ACR |

## Traffic flows

| Flow | Path | Allowed by |
|---|---|---|
| Internet → modern app | Internet → AKS public LB `:80` → node → pod `:8080` | NSG-aks 100, NetworkPolicy |
| Internet → legacy app | **No path** – no public IP, no public LB, NSG denies | — |
| AKS pod → legacy app | pod → (SNAT node `10.20.0.x`) → ILB `10.20.10.10:80` → VM | NSG-iis 100 |
| Admin → IIS VM | Browser → Bastion public IP `:443` → VM `:3389` | NSG-iis 110 |
| ADO → IIS VM (deploy) | **VM → NAT → dev.azure.com:443** (agent pulls the job) | outbound only |
| LB probe → IIS VM | 168.63.129.16 → VM `:80 /health` | NSG-iis 120 |
