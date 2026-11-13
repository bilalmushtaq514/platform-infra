<#
.SYNOPSIS
  Idempotent bootstrap for a private IIS node (I-3, I-6, B-3).

  Executed by Terraform through the VM "Run Command" extension (runs as SYSTEM).
  Safe to re-run: every step checks current state first.

  1. Installs IIS + ASP.NET 4.x features.
  2. Creates the app pool (.NET CLR v4.0, Integrated) and the site on :80.
  3. Seeds a placeholder release so the load-balancer probe (/health) is green
     before the first pipeline deployment.
  4. (Optional) Installs the Azure Pipelines agent and registers this VM as a
     resource in an Azure DevOps *Environment*. The agent only makes OUTBOUND
     HTTPS calls to dev.azure.com (via the NAT Gateway) – no inbound port is
     ever opened. The one-time registration PAT is read from Key Vault with
     the VM's managed identity, so it never appears in Terraform state or Git.
#>
param(
  [string]$SiteName = 'eShopLegacy',
  [string]$AppPoolName = 'eShopLegacy',
  [string]$SiteRoot = 'C:\inetpub\eshop',
  [string]$AzdoOrgUrl = '',
  [string]$AzdoProject = '',
  [string]$AzdoEnvironment = '',
  [string]$AzdoAgentVersion = '5.281.1',
  [string]$AzdoVmTags = 'iis',
  [string]$KeyVaultName = '',
  [string]$PatSecretName = 'azdo-agent-pat'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force -Path 'C:\bootstrap' | Out-Null
Start-Transcript -Path 'C:\bootstrap\bootstrap.log' -Append | Out-Null

function Write-Step($msg) { Write-Output ("[{0:u}] {1}" -f (Get-Date), $msg) }

# --- 1. Windows features --------------------------------------------------------
$features = @(
  'Web-Server', 'Web-WebServer', 'Web-Common-Http', 'Web-Default-Doc', 'Web-Static-Content',
  'Web-Http-Errors', 'Web-Http-Logging', 'Web-Request-Monitor', 'Web-Stat-Compression',
  'Web-Filtering', 'Web-Net-Ext45', 'Web-Asp-Net45', 'Web-ISAPI-Ext', 'Web-ISAPI-Filter',
  'Web-Mgmt-Console', 'Web-Scripting-Tools', 'NET-Framework-45-ASPNET'
)
$missing = Get-WindowsFeature -Name $features | Where-Object { -not $_.Installed }
if ($missing) {
  Write-Step "Installing features: $($missing.Name -join ', ')"
  $r = Install-WindowsFeature -Name $missing.Name
  if (-not $r.Success) { throw "Feature install failed: $($r.ExitCode)" }
} else {
  Write-Step 'IIS / ASP.NET 4.x features already installed'
}

Import-Module WebAdministration

# --- 2. Placeholder release + app pool + site ------------------------------------
# Layout:  C:\inetpub\eshop\releases\<build-id>\   (one folder per deployment)
# The site's physicalPath points at one release; deploy = switch the pointer.
$releases = Join-Path $SiteRoot 'releases'
$placeholder = Join-Path $releases '0-bootstrap'
if (-not (Test-Path $placeholder)) {
  Write-Step "Creating placeholder release $placeholder"
  New-Item -ItemType Directory -Force -Path $placeholder | Out-Null
  $html = "<html><body><h1>$env:COMPUTERNAME</h1><p>IIS bootstrapped - awaiting first pipeline deployment.</p></body></html>"
  Set-Content -Path (Join-Path $placeholder 'index.html') -Value $html -Encoding UTF8
  # Extension-less 'health' file so GET /health returns 200 before the app exists.
  Set-Content -Path (Join-Path $placeholder 'health') -Value "Healthy (bootstrap) $env:COMPUTERNAME" -Encoding ASCII
  @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <staticContent>
      <mimeMap fileExtension="." mimeType="text/plain" />
    </staticContent>
    <defaultDocument><files><clear /><add value="index.html" /></files></defaultDocument>
  </system.webServer>
</configuration>
'@ | Set-Content -Path (Join-Path $placeholder 'web.config') -Encoding UTF8
}

if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
  Write-Step "Creating app pool $AppPoolName"
  New-WebAppPool -Name $AppPoolName | Out-Null
}
$poolPath = "IIS:\AppPools\$AppPoolName"
Set-ItemProperty $poolPath -Name managedRuntimeVersion -Value 'v4.0'
Set-ItemProperty $poolPath -Name managedPipelineMode -Value 'Integrated'
Set-ItemProperty $poolPath -Name startMode -Value 'AlwaysRunning'
Set-ItemProperty $poolPath -Name processModel.identityType -Value 'ApplicationPoolIdentity'
Set-ItemProperty $poolPath -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)

if (Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue) {
  Write-Step 'Removing Default Web Site (frees :80)'
  Remove-Website -Name 'Default Web Site'
}

if (-not (Get-Website -Name $SiteName -ErrorAction SilentlyContinue)) {
  Write-Step "Creating site $SiteName on :80 -> $placeholder"
  New-Website -Name $SiteName -Port 80 -PhysicalPath $placeholder -ApplicationPool $AppPoolName | Out-Null
}
Start-Website -Name $SiteName -ErrorAction SilentlyContinue

# Inbound HTTP on the host firewall (the NSG is still the real perimeter).
Enable-NetFirewallRule -DisplayGroup 'World Wide Web Services (HTTP)' -ErrorAction SilentlyContinue

# --- 3. Azure Pipelines agent (Environment VM resource) ---------------------------
if ([string]::IsNullOrWhiteSpace($AzdoOrgUrl)) {
  Write-Step 'AzdoOrgUrl not set - skipping agent registration'
  Stop-Transcript | Out-Null
  exit 0
}

$agentDir = 'C:\azagent'
if (Test-Path (Join-Path $agentDir '.agent')) {
  Write-Step 'Azure Pipelines agent already configured'
  Stop-Transcript | Out-Null
  exit 0
}

# PAT from Key Vault using the VM's system-assigned managed identity (IMDS).
# RBAC assignments can take a few minutes to propagate -> retry.
$pat = $null
for ($i = 1; $i -le 30 -and -not $pat; $i++) {
  try {
    $tok = (Invoke-RestMethod -Headers @{ Metadata = 'true' } -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net').access_token
    $pat = (Invoke-RestMethod -Headers @{ Authorization = "Bearer $tok" } -Uri "https://$KeyVaultName.vault.azure.net/secrets/$($PatSecretName)?api-version=7.4").value
  } catch {
    Write-Step "Key Vault not readable yet (attempt $i/30): $($_.Exception.Message)"
    Start-Sleep -Seconds 20
  }
}
if (-not $pat) { throw "Could not read secret '$PatSecretName' from Key Vault '$KeyVaultName'" }

New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
$zip = Join-Path $env:TEMP "agent-$AzdoAgentVersion.zip"
$url = "https://download.agent.dev.azure.com/agent/$AzdoAgentVersion/vsts-agent-win-x64-$AzdoAgentVersion.zip"
Write-Step "Downloading agent $url"
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $agentDir -Force

Push-Location $agentDir
try {
  Write-Step "Registering in environment '$AzdoEnvironment' of $AzdoOrgUrl/$AzdoProject"
  # Runs as LocalSystem because deployments must stop/start IIS app pools and
  # write under C:\inetpub. Trade-off documented in docs/security.md.
  & .\config.cmd --unattended `
    --environment --environmentname $AzdoEnvironment `
    --agent $env:COMPUTERNAME --replace `
    --runasservice --windowsLogonAccount 'NT AUTHORITY\SYSTEM' `
    --work '_work' `
    --url $AzdoOrgUrl --projectname $AzdoProject `
    --auth PAT --token $pat `
    --addvirtualmachineresourcetags --virtualmachineresourcetags $AzdoVmTags
  if ($LASTEXITCODE -ne 0) { throw "config.cmd failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
  $pat = $null
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
}

Write-Step 'Bootstrap complete'
Stop-Transcript | Out-Null
