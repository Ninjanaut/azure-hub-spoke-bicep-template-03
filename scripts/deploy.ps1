# All deployments in order: management -> hub -> landing zones (one at a time). Safe to rerun.
# Before the first run: scripts/setup-entra.ps1 and scripts/setup-management-groups.ps1.
# Dry run: replace "create" with "what-if" in a line.
# Run from the repo root after: az login --tenant <tenantId from config/platform.json>
$config = Get-Content config/platform.json -Raw | ConvertFrom-Json
$location = $config.location

# SSH public key for the spokes' test VMs (the param files read it)
$env:ADMIN_SSH_PUBLIC_KEY = Get-Content ($config.sshPublicKeyPath -replace '^~', $HOME)

# Management: central Log Analytics workspace
az deployment sub create --subscription $config.management.subscriptionId -n management-shared -l $location -f platform/management/main.bicep -p platform/management/main.bicepparam

# The hub firewall's diagnostic setting needs this provider in the workspace's subscription
az provider register -n Microsoft.Insights --subscription $config.management.subscriptionId --wait

# Hub: firewall, Bastion, Private DNS (about 10 minutes)
az deployment sub create --subscription $config.connectivity.subscriptionId -n hub-shared -l $location -f platform/connectivity/main.bicep -p platform/connectivity/main.bicepparam

# Expect 10.0.0.4, the IP the spokes route to (hub.firewallPrivateIpAddress in config/platform.bicep)
# az deployment sub show --subscription $config.connectivity.subscriptionId -n hub-shared --query properties.outputs.firewallPrivateIpAddress.value -o tsv

# Landing zones
az deployment sub create --subscription $config.landingZones.'app1-dev'.subscriptionId -n spoke-app1-dev -l $location -f landing-zones/main.bicep -p landing-zones/app1-dev.bicepparam
az deployment sub create --subscription $config.landingZones.'app2-dev'.subscriptionId -n spoke-app2-dev -l $location -f landing-zones/main.bicep -p landing-zones/app2-dev.bicepparam
