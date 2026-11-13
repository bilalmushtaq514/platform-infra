#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-off: Azure DevOps Environments + checks (A-6, B-3, B-6).
#
#   aks-dev    modern app target. No approval (dev, continuous deployment).
#   iis-dev    legacy app target. The 3 IIS VMs self-register here as VM
#              resources (tag "iis"). Manual APPROVAL check before deploy.
#   infra-dev  Terraform apply target. Manual APPROVAL check before apply.
#
# Usage: ORG=https://dev.azure.com/<org> PROJECT=<project> APPROVER=<email> ./setup-azdo-environments.sh
# -----------------------------------------------------------------------------
set -euo pipefail
ORG="${ORG:?}"; PROJECT="${PROJECT:?}"; APPROVER="${APPROVER:?}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
APPROVER_ID="$(az devops user show --org "$ORG" --user "$APPROVER" --query id -o tsv)"

invoke() { az devops invoke --org "$ORG" --route-parameters project="$PROJECT" "$@"; }

ensure_env() { # $1 name $2 description -> echoes id
  local id
  id="$(invoke --area distributedtask --resource environments --api-version 7.1 \
        --query "value[?name=='$1'].id | [0]" -o tsv)"
  if [[ -z "$id" ]]; then
    printf '{"name":"%s","description":"%s"}' "$1" "$2" >"$WORK/env.json"
    id="$(invoke --area distributedtask --resource environments --http-method POST \
          --in-file "$WORK/env.json" --api-version 7.1 --query id -o tsv)"
  fi
  echo "$id"
}

ensure_approval() { # $1 env id $2 instructions
  local existing
  existing="$(az devops invoke --org "$ORG" --area PipelinesChecks --resource configurations \
    --route-parameters project="$PROJECT" --query-parameters resourceType=environment resourceId="$1" \
    --api-version 7.1-preview --query "value[?type.name=='Approval'].id | [0]" -o tsv 2>/dev/null || true)"
  [[ -n "$existing" ]] && return 0
  cat >"$WORK/check.json" <<EOF
{
  "type": { "id": "8C6F20A7-A545-4486-9777-F762FAFE0D4D", "name": "Approval" },
  "settings": {
    "approvers": [ { "id": "$APPROVER_ID" } ],
    "executionOrder": 1,
    "minRequiredApprovers": 1,
    "instructions": "$2",
    "blockedApprovers": [],
    "requesterCannotBeApprover": false
  },
  "resource": { "type": "environment", "id": "$1" },
  "timeout": 1440
}
EOF
  az devops invoke --org "$ORG" --area PipelinesChecks --resource configurations \
    --route-parameters project="$PROJECT" --http-method POST --in-file "$WORK/check.json" \
    --api-version 7.1-preview -o none
}

authorize_all_pipelines() { # $1 resource type (environment|endpoint) $2 id
  printf '{"allPipelines":{"authorized":true}}' >"$WORK/perm.json"
  az devops invoke --org "$ORG" --area pipelinePermissions --resource pipelinePermissions \
    --route-parameters project="$PROJECT" resourceType="$1" resourceId="$2" \
    --http-method PATCH --in-file "$WORK/perm.json" --api-version 7.1-preview -o none
}

aks="$(ensure_env aks-dev 'AKS cluster - modern .NET 10 app (eShopOnWeb)')"
iis="$(ensure_env iis-dev 'Private IIS VMs - legacy .NET Framework app (eShopLegacyMVC). VMs self-register via outbound agent.')"
infra="$(ensure_env infra-dev 'Terraform apply of platform-infra/envs/dev')"

ensure_approval "$iis" "Approve rolling deployment of the legacy app to the private IIS servers (one server at a time)."
ensure_approval "$infra" "Review the Terraform plan artifact before approving apply."

# Pipelines may use these without a first-run "Permit" click. The infra
# service connection is deliberately NOT opened to all pipelines.
for id in "$aks" "$iis" "$infra"; do authorize_all_pipelines environment "$id"; done
apps_sc="$(az devops service-endpoint list --org "$ORG" --project "$PROJECT" --query "[?name=='sc-azure-apps'].id | [0]" -o tsv)"
authorize_all_pipelines endpoint "$apps_sc"

echo "aks-dev=$aks iis-dev=$iis infra-dev=$infra"
