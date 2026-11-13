#!/usr/bin/env bash
# Publishes NON-SECRET Terraform outputs/inputs as Azure DevOps variable groups.
# Re-run after `terraform apply` if outputs change. Usage: run from envs/dev.
set -euo pipefail
ORG="${ORG:?}"; PROJECT="${PROJECT:?}"
out() { terraform output -raw "$1"; }

upsert() { # $1 group name, rest: k=v
  local name="$1"; shift
  local id; id="$(az pipelines variable-group list --org "$ORG" -p "$PROJECT" --group-name "$name" --query '[0].id' -o tsv)"
  if [[ -z "$id" ]]; then
    az pipelines variable-group create --org "$ORG" -p "$PROJECT" --name "$name" --authorize true \
      --description "Non-secret values from platform-infra (managed by scripts/setup-azdo-variable-groups.sh)" \
      --variables "$@" -o none
  else
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      az pipelines variable-group variable update --org "$ORG" -p "$PROJECT" --group-id "$id" --name "$k" --value "$v" -o none 2>/dev/null \
        || az pipelines variable-group variable create --org "$ORG" -p "$PROJECT" --group-id "$id" --name "$k" --value "$v" -o none
    done
  fi
}

vm_ips="$(terraform output -json iis_vm_private_ips | python3 -c 'import json,sys;print(" ".join(sorted(json.load(sys.stdin).values())))')"
upsert platform-dev \
  "ACR_NAME=$(out acr_name)" \
  "AKS_NAME=$(out aks_cluster_name)" \
  "AKS_RESOURCE_GROUP=$(out resource_group_name)" \
  "IIS_LB_IP=$(out iis_lb_private_ip)" \
  "IIS_VM_IPS=$vm_ips"

sa="$(sed -n 's/^storage_account_name *= *"\(.*\)"/\1/p' backend.hcl)"
rg="$(sed -n 's/^resource_group_name *= *"\(.*\)"/\1/p' backend.hcl)"
kv="$(sed -n 's/^platform_key_vault_name *= *"\(.*\)"/\1/p' terraform.tfvars)"
deployers="$(python3 - <<'PY'
import re,json
s=open('terraform.tfvars').read()
m=re.search(r'deployer_object_ids\s*=\s*\[(.*?)\]',s,re.S)
print(json.dumps(re.findall(r'"([0-9a-f-]{36})"',m.group(1)) if m else []))
PY
)"
upsert platform-infra-dev \
  "TF_SUBSCRIPTION_ID=$(az account show --query id -o tsv)" \
  "TF_STATE_RG=$rg" "TF_STATE_SA=$sa" "TF_PLATFORM_KV_NAME=$kv" \
  "TF_DEPLOYER_OBJECT_IDS=$deployers" \
  "TF_AZDO={\"org_url\":\"$ORG\",\"project\":\"$PROJECT\",\"environment\":\"iis-dev\"}"
echo "variable groups updated"
