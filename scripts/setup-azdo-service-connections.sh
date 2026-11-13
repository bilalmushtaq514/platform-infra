#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-off: create Azure DevOps -> Azure service connections that use
# Workload Identity Federation (OIDC). No client secrets exist anywhere:
# Azure DevOps mints a short-lived OIDC token per job, Entra ID trusts it via a
# federated credential on the app registration.
#
#   sc-azure-apps   -> sp-azdo-hybrid-apps   (AcrPush + AKS deploy; granted by Terraform)
#   sc-azure-infra  -> sp-azdo-hybrid-infra  (Contributor + RBAC Admin on the sub; infra pipeline only)
#
# Idempotent-ish: re-running skips things that already exist.
# Usage: ORG=https://dev.azure.com/<org> PROJECT=<project> ./setup-azdo-service-connections.sh
# -----------------------------------------------------------------------------
set -euo pipefail

ORG="${ORG:?set ORG}"
PROJECT="${PROJECT:?set PROJECT}"
SUB_ID="$(az account show --query id -o tsv)"
SUB_NAME="$(az account show --query name -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
PROJECT_ID="$(az devops project show --org "$ORG" --project "$PROJECT" --query id -o tsv)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ensure_app() { # $1 display name -> echoes appId
  local app_id
  app_id="$(az ad app list --display-name "$1" --query '[0].appId' -o tsv)"
  if [[ -z "$app_id" ]]; then
    app_id="$(az ad app create --display-name "$1" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
  fi
  az ad sp show --id "$app_id" >/dev/null 2>&1 || az ad sp create --id "$app_id" >/dev/null
  echo "$app_id"
}

ensure_endpoint() { # $1 sc name, $2 appId -> echoes endpoint id
  local name="$1" app_id="$2" id
  id="$(az devops service-endpoint list --org "$ORG" --project "$PROJECT" --query "[?name=='$name'].id | [0]" -o tsv)"
  if [[ -z "$id" ]]; then
    cat >"$WORK/$name.json" <<EOF
{
  "name": "$name",
  "type": "azurerm",
  "url": "https://management.azure.com/",
  "description": "OIDC (workload identity federation) - no secret. Managed by platform-infra/scripts.",
  "authorization": {
    "scheme": "WorkloadIdentityFederation",
    "parameters": { "tenantid": "$TENANT_ID", "serviceprincipalid": "$app_id" }
  },
  "data": {
    "environment": "AzureCloud",
    "scopeLevel": "Subscription",
    "subscriptionId": "$SUB_ID",
    "subscriptionName": "$SUB_NAME",
    "creationMode": "Manual"
  },
  "isShared": false,
  "isReady": true,
  "serviceEndpointProjectReferences": [
    { "projectReference": { "id": "$PROJECT_ID", "name": "$PROJECT" }, "name": "$name" }
  ]
}
EOF
    id="$(az devops invoke --org "$ORG" --area serviceendpoint --resource endpoints \
      --http-method POST --in-file "$WORK/$name.json" --api-version 7.1 --query id -o tsv)"
  fi
  echo "$id"
}

ensure_federation() { # $1 sc name, $2 appId, $3 endpoint id
  local name="$1" app_id="$2" ep="$3" issuer subject
  issuer="$(az devops service-endpoint show --org "$ORG" --project "$PROJECT" --id "$ep" --query 'authorization.parameters.workloadIdentityFederationIssuer' -o tsv)"
  subject="$(az devops service-endpoint show --org "$ORG" --project "$PROJECT" --id "$ep" --query 'authorization.parameters.workloadIdentityFederationSubject' -o tsv)"
  if [[ -z "$(az ad app federated-credential list --id "$app_id" --query "[?subject=='$subject'].name | [0]" -o tsv)" ]]; then
    cat >"$WORK/$name-fic.json" <<EOF
{ "name": "azdo-$name", "issuer": "$issuer", "subject": "$subject", "audiences": ["api://AzureADTokenExchange"] }
EOF
    az ad app federated-credential create --id "$app_id" --parameters "$WORK/$name-fic.json" >/dev/null
  fi
}

for pair in "sc-azure-apps:sp-azdo-hybrid-apps" "sc-azure-infra:sp-azdo-hybrid-infra"; do
  sc="${pair%%:*}"; app="${pair##*:}"
  app_id="$(ensure_app "$app")"
  ep="$(ensure_endpoint "$sc" "$app_id")"
  ensure_federation "$sc" "$app_id" "$ep"
  sp_oid="$(az ad sp show --id "$app_id" --query id -o tsv)"
  echo "$sc  endpoint=$ep  appId=$app_id  spObjectId=$sp_oid"
done

# Infra identity: manage resources + create the role assignments Terraform declares.
# "Role Based Access Control Administrator" (not Owner) = can assign roles, cannot
# change anything else about access policy.
infra_oid="$(az ad sp show --id "$(az ad app list --display-name sp-azdo-hybrid-infra --query '[0].appId' -o tsv)" --query id -o tsv)"
for role in "Contributor" "Role Based Access Control Administrator"; do
  az role assignment create --assignee-object-id "$infra_oid" --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "/subscriptions/$SUB_ID" -o none 2>/dev/null || true
done
echo "Done. Add the spObjectIds above to bootstrap (state_contributor_object_ids: infra) and envs/dev (deployer_object_ids: apps)."
