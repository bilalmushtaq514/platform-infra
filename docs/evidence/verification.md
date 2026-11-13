# Verification evidence (assessment §3.3)

Captured 2026-11-13. Commands are in [operations.md](../operations.md#verification-commands).

## 1. Modern app is reachable from the Internet

```
$ curl -s -o /dev/null -w "%{http_code} (%{remote_ip})" http://eshop-hybrid-dev.eastus2.cloudapp.azure.com/health/ready
200 (57.166.218.139)

$ curl -s http://57.166.218.139/ | grep -o 'build [^<]*'
build 114-02cb194 &middot; pod eshop-web-d9d889c8f-w8j22
```

URL: **http://eshop-hybrid-dev.eastus2.cloudapp.azure.com** (Azure LB public IP `57.166.218.139`).

## 2. Legacy app is NOT reachable from the Internet

Every public IP in the platform resource group, and what it is attached to:

```
Name                         Ip              AttachedTo
pip-hybrid-dev-eus2-bastion  20.94.57.193    bastionHosts/bas-hybrid-dev-eus2          (admin entry, TLS only)
pip-hybrid-dev-eus2-nat      20.114.204.130  natGateways/ng-hybrid-dev-eus2            (egress only)
# AKS-managed node RG: 57.166.218.139 (modern app LB), 4.153.86.139 (AKS outbound SNAT)
```

The IIS VMs have private addresses only:

```
Vm                         Private       Public
vm-hybrid-dev-eus2-iis-01  10.20.10.5    (none)
vm-hybrid-dev-eus2-iis-02  10.20.10.11   (none)
vm-hybrid-dev-eus2-iis-03  10.20.10.4    (none)
```

Requests from the Internet (a laptop) fail:

```
http://10.20.10.10/health      -> HTTP 000  FAILED (curl exit 28: timeout)   ILB private frontend - not routable
http://20.114.204.130/health   -> HTTP 000  FAILED (curl exit 28: timeout)   NAT Gateway never accepts inbound
http://20.94.57.193/health     -> HTTP 000  FAILED (curl exit 28: timeout)   Bastion only speaks to the Azure portal
```

## 3. Legacy tier IS reachable inside the VNet, and load balanced

From a pod in AKS (`curlimages/curl`, launched with `az aks command invoke`). Path: pod →
SNAT to the node IP `10.20.0.x` → ILB `10.20.10.10` → IIS. Allowed by NSG-iis rule 100 (source `10.20.0.0/16`).
Captured right after provisioning, so each server answers with the bootstrap placeholder. The
same check after a pipeline deployment is in section 4.

```
ILB #1 -> Healthy (bootstrap) iisdev02
ILB #2 -> Healthy (bootstrap) iisdev01
ILB #3 -> Healthy (bootstrap) iisdev03
ILB #4 -> Healthy (bootstrap) iisdev03
ILB #5 -> Healthy (bootstrap) iisdev01
ILB #6 -> Healthy (bootstrap) iisdev02
ILB #7 -> Healthy (bootstrap) iisdev01
ILB #8 -> Healthy (bootstrap) iisdev03
ILB #9 -> Healthy (bootstrap) iisdev02
node 10.20.10.4  -> Healthy (bootstrap) iisdev03
node 10.20.10.5  -> Healthy (bootstrap) iisdev01
node 10.20.10.11 -> Healthy (bootstrap) iisdev02
```

9 requests through the ILB reached all 3 servers (3 each).

## 4. Pipeline deployments

### Pipeline A, run `eshop-web-20261113.3` (#120): build → test → scan → ACR → AKS

```
Deployed acrhybriddevkdk6.azurecr.io/eshop-web:120-51f3996 - healthy and serving build 120-51f3996
$ kubectl -n eshop rollout history deploy/eshop-web
REVISION  CHANGE-CAUSE
1         eshop-web-20261113.1 acrhybriddevkdk6.azurecr.io/eshop-web:114-02cb194
2         eshop-web-20261113.3 acrhybriddevkdk6.azurecr.io/eshop-web:120-51f3996
$ az acr repository show-tags -n acrhybriddevkdk6 --repository eshop-web
114-02cb194
120-51f3996            # immutable <BuildId>-<sha> tags, never `latest`
$ curl -s http://eshop-hybrid-dev.eastus2.cloudapp.azure.com/ | grep -o 'build [^<]*'
build 120-51f3996 · pod eshop-web-759859f4f8-24f2b
```

Run #114 (first deploy) actually deployed fine, but the final banner check had a race
(`curl | grep -q` under `pipefail` → SIGPIPE). That was a pipeline bug, fixed in `51f3996`.

### Pipeline B, run `eshop-legacy-20261113.5` (#121): build → MSTest → **approval** → rolling IIS → ILB verify

Rolling, one server at a time (agent on each VM, outbound-only):

```
[12:45:00] [iisdev01] Unpacking ...\eshop-legacy.zip -> C:\inetpub\eshop\releases\121
[12:45:01] [iisdev01] Stopping site + app pool
[12:45:04] [iisdev01] physicalPath -> C:\inetpub\eshop\releases\121
[12:45:04] [iisdev01] Starting app pool + site
[12:45:14] [iisdev01] health attempt 1: HTTP 200 {"Healthy":true,"Server":"iisdev01","Build":"121-0bf8205","Environment":"dev","CatalogItems":12}
[12:45:14] [iisdev01] HEALTHY on C:\inetpub\eshop\releases\121
[12:46:34] [iisdev03] ... HEALTHY on C:\inetpub\eshop\releases\121
[12:48:30] [iisdev02] ... HEALTHY on C:\inetpub\eshop\releases\121
```

Verification stage, from a pod in AKS (inside the VNet):

```
node 10.20.10.11 -> {"Server":"iisdev02","Build":"121-0bf8205",...} HTTP200
node 10.20.10.4  -> {"Server":"iisdev03","Build":"121-0bf8205",...} HTTP200
node 10.20.10.5  -> {"Server":"iisdev01","Build":"121-0bf8205",...} HTTP200
ILB  #1..#12     -> all HTTP200, Build 121-0bf8205
Distinct servers behind the ILB:
      3 "Server":"iisdev01"
      6 "Server":"iisdev02"
      3 "Server":"iisdev03"
```

Legacy build issues found on the way (all fixed in the pipeline, not in app code):
`MSB3644` net461 targeting pack (#112), `NU1605` inherited package downgrade in the test
restore (#116), `DeployDefaultTarget=WebPublish` needed for folder publish (#119).

## 5. A deliberately broken deployment is caught and stopped

### A: readiness probe pointed at a 404 path (commit `55c637d`, run #123)

```
Waiting for deployment "eshop-web" rollout to finish: 1 out of 2 new replicas have been updated...
error: deployment "eshop-web" exceeded its progress deadline
##[error]Rollout did not become ready - rolling back
eshop-web-759859f4f8-24f2b   1/1  Running   38m    <- old build 120 keeps serving (maxUnavailable: 0)
eshop-web-759859f4f8-jcznd   1/1  Running   38m    <- old build 120 keeps serving
eshop-web-9885dcb79-csf5g    0/1  Running   4m2s   <- broken build never Ready
deployment.apps/eshop-web rolled back
##[error]Script failed with exit code: 1           <- run marked FAILED
$ curl -s http://eshop-hybrid-dev.eastus2.cloudapp.azure.com/ | grep -o 'build [^<]*'
build 120-51f3996 · pod eshop-web-759859f4f8-24f2b   <- users never saw the broken build
```

### B: `UseMockData=false` (app points at a database that doesn't exist) (commit `f14556b`, run #124, approved)

```
[13:08:18] [iisdev01] Live release before change: C:\inetpub\eshop\releases\121
[13:08:23] [iisdev01] physicalPath -> C:\inetpub\eshop\releases\124
[13:08:43] [iisdev01] health attempt 1: failed (HTTP ) The operation has timed out.
...
[13:11:03] [iisdev01] health attempt 12: failed (HTTP 503) Server Unavailable.
[13:11:08] [iisdev01] UNHEALTHY - restoring previous release C:\inetpub\eshop\releases\121
[13:11:11] [iisdev01] physicalPath -> C:\inetpub\eshop\releases\121
[13:11:13] [iisdev01] health attempt 1: HTTP 200 {"Server":"iisdev01","Build":"121-0bf8205",...}
[13:11:13] [iisdev01] Previous release restored and healthy
##[error]iisdev01: new release failed health check and was rolled back on this server
```

The rolling job stopped at the first server. The whole tier afterwards (from a pod in AKS):

```
node 10.20.10.5  -> {"Server":"iisdev01","Build":"121-0bf8205"}   restored automatically
node 10.20.10.11 -> {"Server":"iisdev02","Build":"121-0bf8205"}   never touched
node 10.20.10.4  -> {"Server":"iisdev03","Build":"121-0bf8205"}   never touched
ILB #1..#6       -> all Healthy, build 121-0bf8205, servers 01/02/03
```

While `iisdev01` was unhealthy, the ILB probe (`/health`, 2 × 5 s) took it out of rotation,
so users inside the VNet were served by 02 and 03.
