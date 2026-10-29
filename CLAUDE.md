# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A minimal Azure hub-and-spoke network written in Bicep. It's meant as material for a blog article and as base infrastructure for later proofs of concept, so keep it simple. It intentionally has no VPN gateway. The goals are routing and filtering between spokes through Azure Firewall (Basic) in the hub, central Private DNS and central logging. Every workload subnet has its own NSG with only the default rules, ready for rules later. One Azure Bastion (Basic) in the hub lets people sign in to every VM in all spokes with their Microsoft Entra ID account instead of SSH keys.

The layout follows the enterprise platform / landing-zone split of the Azure landing zone (ALZ) reference architecture, scaled down to one repo: a management platform (central Log Analytics workspace), a connectivity platform (hub) and landing zones (spokes). Resources come from Azure Verified Modules (AVM).

Spoke-to-spoke traffic goes through Azure Firewall `afw-hub-shared-…` in the hub's `AzureFirewallSubnet` (`10.0.0.0/26`; Azure gives the firewall the first usable address, `10.0.0.4`). VNet peering isn't transitive, so each spoke's workload subnet has a route table with one route, `0.0.0.0/0` → `VirtualAppliance` → `10.0.0.4` (forced egress, the ALZ hub-and-spoke pattern). Longest prefix wins: the spoke's own VNet and the hub (`10.0.0.0/22`, peering) keep their more specific system and peering routes, so traffic to other spokes and to the internet goes to the firewall, while traffic inside the spoke and to the hub (Bastion) doesn't. The firewall reaches every spoke directly through the hub's peering routes, so return traffic needs no extra routes. It doesn't SNAT private (RFC 1918) destinations, so the target spoke sees the real source IP and its reply takes its own route back through the firewall (symmetric). Internet traffic is SNATed to the firewall's public IP `pip-afw-hub-shared-…`. Every peering sets `allowForwardedTraffic: true`. The firewall denies everything by default; the firewall policy `afwp-hub-shared-…` has two network rules: any protocol and port from `10.0.0.0/16` to `10.0.0.0/16` (spoke-to-spoke), and from `10.0.0.0/16` to anything (internet egress, deliberately unrestricted because future spokes' needs are unknown, but logged and in one place to narrow later). Spoke subnets are **private** (`defaultOutboundAccess: false`): no implicit default outbound access, so if the route is removed, VMs lose the internet instead of going out directly. Platform addresses `168.63.129.16` (DNS, VM agent, extensions) and `169.254.169.254` (instance metadata) aren't affected by routes. Firewall logs go to the central workspace `log-management-shared-…` in `rg-management-shared`, in resource-specific tables (`AZFWNetworkRule`, `AZFWApplicationRule`, …).

DNS uses central Private DNS zones with **no resolver**: there's no on-premises network or VPN, so nothing outside the VNets needs to resolve them. One shared set of zones lives in `rg-dns-shared` in the connectivity subscription, and **every VNet is linked to every zone**. All VNets use Azure-provided DNS (`168.63.129.16`), which only answers from zones linked to the VM's own VNet; peering doesn't share links. The hub template links the hub. Each landing zone links its own VNet in the DNS resource group, the same way it creates the hub → spoke peering. Adding a spoke adds only that spoke's links; the hub and other spokes aren't touched. There are two kinds of zones:
- **Private Link zones** (`privatelink.blob…`, `.file…`, `vaultcore`, `database…`) are listed once, in `privateLinkDnsZones` in `config/platform.bicep`. The hub template creates them, and landing zones link to them with `registrationEnabled: false`. A private endpoint in any spoke registers its record in the central zone through its DNS zone group. To add a zone type, edit the list before you deploy a private endpoint of that type, then redeploy the hub and every landing zone (the only change that touches every spoke).
- **The internal zone `hubspoke.internal`** has auto-registration. The hub link has it on too (the hub has no VMs today, so it registers nothing), and each landing zone links its own VNet with `registrationEnabled: true`, so VMs resolve each other as `<vm-name>.hubspoke.internal` across spokes.

Limits: 1,000 VNet links per zone, of which at most 100 can have auto-registration. With P2S VPN or on-premises later, add a DNS Private Resolver with an inbound endpoint in the hub (clients can't reach `168.63.129.16`); the zone links stay as they are.

## Layout

```
config/
  platform.json                       # the only place for IDs: tenant, subscriptions, MG prefix, Entra ID group names + object IDs, SSH key path
  platform.bicep                      # the only place for shared names and computed IDs (hub, management), exported (not deployed)
scripts/                              # plain az commands in run order, values from config/platform.json
  setup-entra.ps1                     # once: test user, Entra ID groups, memberships; writes object IDs to the config (guard)
  setup-management-groups.ps1         # once: ALZ-style management groups, subscription placement (guard)
  deploy-governance.ps1               # Corp policy on the Corp management group; rerun after a policy change
  deploy.ps1                          # management -> hub -> landing zones
  cleanup.ps1                         # resource groups; commented-out sections for governance and Entra ID
platform/
  management/main.bicep               # management resource group + central Log Analytics workspace (subscription scope)
  management/main.bicepparam
  connectivity/main.bicep             # hub + DNS resource groups, hub VNet, Bastion + its NSG, firewall policy, Azure Firewall, Private DNS zones linked to the hub (subscription scope)
  connectivity/main.bicepparam
  governance/mgmt-groups/corp/main.bicep          # Corp MG policy: Deny-Public-IP, Deny-Public-IP-On-NIC, Deny-Subnet-Without-Udr (management group scope)
  governance/mgmt-groups/corp/main.bicepparam
  governance/mgmt-groups/corp/policy-definitions/ # ALZ custom policy definitions, copied unchanged from the ALZ library
landing-zones/
  main.bicep                          # one spoke resource group + route table + NSG + VNet + both peering directions + Private DNS zone links + optional test VM (subscription scope)
  <spokeName>-<environment>.bicepparam  # one per spoke environment, named like its key in config/platform.json (app1-dev)
```

## Commands

All commands run in PowerShell 7 (`pwsh`) with the Azure CLI. Building and linting need no login.

```powershell
# Install Azure CLI and Bicep. The -e flag is short for --exact. It tells winget to match the package query exactly.
winget install -e --id Microsoft.AzureCLI 
az bicep upgrade

# Linting is static analysis of your code. The linter reads your .bicep file without deploying anything and flags things that are valid syntax but are likely mistakes, bad practice, or security risks.       
az bicep lint --file landing-zones/main.bicep  

# Compiles a Bicep file into a standard ARM JSON file.
az bicep build --file landing-zones/main.bicep 
# Landing-zone param files that deploy a test VM need $env:ADMIN_SSH_PUBLIC_KEY set (see "SSH key" below)
az bicep build-params --file landing-zones/app1-dev.bicepparam
az bicep build-params --file platform/connectivity/main.bicepparam
az bicep build-params --file platform/management/main.bicepparam
```

### Sign in

```powershell
az login --tenant '<tenant-id>'                         # opens a browser; add --use-device-code on a machine without one
az account list -o table                                # subscriptions you can see
az account set --subscription '<hub-subscription-id>'   # select before each step below
az account show -o table                                # check the active subscription
```

`az deployment sub create` targets the active subscription, so switch with `az account set` between the management, hub and spoke steps. The hub → spoke peering uses the hub subscription from `hubVnetResourceId` regardless of the active one.

### SSH key (test VMs)

A Linux VM needs a password or an SSH key, and these templates only accept a key. You create the key pair yourself, once, as a dedicated key used only for this PoC. Azure doesn't generate it.

```powershell
# Once: create the key pair (OpenSSH is built into Windows 11). Run it in PowerShell, not cmd, WSL or Git Bash,
# and answer both passphrase prompts (empty is fine) or no files are written.
ssh-keygen -t ed25519 -f "$HOME\.ssh\azure-hub-spoke-template-03" -C "azure-hub-spoke-template-03"
#   C:\Users\<you>\.ssh\azure-hub-spoke-template-03      private key: stays on your machine, never share or commit it
#   C:\Users\<you>\.ssh\azure-hub-spoke-template-03.pub  public key: the one that goes to Azure

# Before each deployment, in the same PowerShell window
$env:ADMIN_SSH_PUBLIC_KEY = Get-Content "$HOME\.ssh\azure-hub-spoke-template-03.pub"
$env:ADMIN_SSH_PUBLIC_KEY                               # check: prints one line, ssh-ed25519 AAAA... azure-hub-spoke-template-03

# Optional: set it permanently for your user (applies to newly opened windows)
[Environment]::SetEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY', (Get-Content "$HOME\.ssh\azure-hub-spoke-template-03.pub"), 'User')
```

- The variable holds the key's **text**, not the path to the file. A variable set with `$env:` only lasts until you close that PowerShell window.
- Every landing-zone param file with `deployTestVm = true` reads the variable with `readEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY')`. If it isn't set, `az deployment` and `az bicep build-params` fail with `BCP427` (VS Code shows the same error until it's restarted from a window where the variable is set). The hub and management templates and a landing zone without a test VM don't need it.
- Azure writes the key into `/home/azureuser/.ssh/authorized_keys` **inside the VM**. That's what `publicKeys.path` in the templates means: a Linux path, not a Windows one. No key file is stored in the repo.
- Azure requires a key (or password) on every Linux VM at creation, so it stays, but only as a **break-glass** credential. Day-to-day login is with Microsoft Entra ID through Bastion (see below), and `az vm run-command invoke` doesn't use SSH either.
- One key for all VMs is fine for this PoC. In production, keep it in a Key Vault and never hand it out.

### Config and scripts

`config/platform.json` is the single source of every ID: tenant, subscriptions (`management`, `connectivity`, one entry per landing zone keyed `<spokeName>-<environment>`), the management group prefix, the test user, Entra ID group names and object IDs, and `sshPublicKeyPath`. It's committed. Only `config/platform.bicep` reads it (`loadJsonContent()`); it builds the shared names and resource IDs from it and exports them together with the config itself, so templates and param files import from that one file. Each spoke's address space stays in its param file.

The scripts are deliberately plain: the first line loads the config (`$config = Get-Content config/platform.json -Raw | ConvertFrom-Json`), and the rest are `az` commands in run order with `--subscription` from the config, so `az account set` isn't needed. No parameters or functions. The two setup scripts only create things, so each starts with a guard that stops if anything already exists; every line can be copied into a terminal at the repo root after the first one. Run them from the repo root.

```powershell
az login --tenant '<tenant-id>'
./scripts/setup-entra.ps1               # once (Groups Administrator + User Administrator in Entra ID)
./scripts/setup-management-groups.ps1   # once (Management Group Contributor at the tenant root, Owner on the subscriptions)
./scripts/deploy-governance.ps1         # Corp policy (Resource Policy Contributor on the Corp MG); safe to rerun
./scripts/deploy.ps1                    # every deployment; safe to rerun. Dry run: replace create with what-if in a line
./scripts/cleanup.ps1                   # resource groups; uncomment its last sections to remove governance and Entra ID too
```

- `setup-entra.ps1` creates the test user and the three groups, adds the user to all three, and saves the object IDs to the config; redeploy the hub and landing zones to apply new ones. Its guard stops it if the user or any group already exists, because `az ad group create` would make a second group with the same name (a new object ID).
- Entra ID and the management groups have separate scripts: different permissions (Entra directory roles vs Azure RBAC at the tenant root) and a different pace (groups change with every spoke, the hierarchy is created once).
- `setup-management-groups.ps1` creates `<prefix>` → `-platform` (`-connectivity`, `-management`), `-landingzones` (`-corp`), `-decommissioned` and moves the subscriptions (connectivity under `-connectivity`, never Corp, because the firewall and Bastion need public IPs). Its guard stops it if any of the groups exists: `az` wouldn't duplicate a management group (the name is the ID), but it would reset its display name and parent.
- `deploy-governance.ps1` deploys the Corp policy (`platform/governance/mgmt-groups/corp`). It's separate from the setup because it's rerunnable and changes on its own schedule (rerun after a policy change), with its own scope and permission (management group deployment, Resource Policy Contributor), as ALZ keeps governance apart from platform resources.
- Adding a landing zone: add its entry to the config and `landing-zones/<spokeName>-<environment>.bicepparam` (copy `app1-dev.bicepparam`, change the names and address space), then add its lines to each script (a group in `setup-entra.ps1`, a `subscription add` in `setup-management-groups.ps1`, a `Microsoft.PolicyInsights` registration in `deploy-governance.ps1`, a deployment in `deploy.ps1`, a resource group in `cleanup.ps1`), and run only the new lines.

### Deploy

Order: **(0) Entra ID groups → (1) management groups and Corp policy → (2) management → (3) hub → (4) landing zones** (`setup-entra.ps1`, `setup-management-groups.ps1`, `deploy-governance.ps1`, then `deploy.ps1` for 2–4). The templates assign roles to group object IDs (`bastionUsersGroupObjectId`, `vmAdminLoginGroupObjectId`), so create the groups first (`setup-entra.ps1` writes their IDs to the config; see "Sign in to a VM" below). A missing group fails the deployment with `PrincipalNotFound`. An empty ID skips that assignment; set it and redeploy later. Group membership (people, and nesting into `sg-hub-shared-bastion-users`) can change at any time and doesn't affect the deployment.

**Start deallocated VMs before redeploying.** Azure can't add or change VM extensions (`AADSSHLoginForLinux`) on a stopped VM, so a redeploy fails with `OperationNotAllowed: Cannot modify extensions in the VM when the VM is not running`. Run `az vm start -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001` first, then deploy again.

```powershell
$env:ADMIN_SSH_PUBLIC_KEY = Get-Content "$HOME\.ssh\azure-hub-spoke-template-03.pub"   # every new PowerShell window; see "SSH key" above
# 1) Management, once (active subscription: management; may be the hub subscription in a PoC); creates rg-management-shared
az account set --subscription '<management-subscription-id>'
az deployment sub create -n management-shared -l swedencentral -f platform/management/main.bicep -p platform/management/main.bicepparam
# Once per management subscription: the hub firewall's diagnostic setting needs Microsoft.Insights registered here, and
# nothing registers it automatically. Wait until the second command prints Registered.
az provider register -n Microsoft.Insights
az provider show -n Microsoft.Insights --query registrationState -o tsv
# 2) Hub, once (active subscription: hub); the template creates rg-hub-shared itself. The firewall takes about 10 minutes.
az account set --subscription '<hub-subscription-id>'
az deployment sub create -n hub-shared -l swedencentral -f platform/connectivity/main.bicep -p platform/connectivity/main.bicepparam
# Check: the firewallPrivateIpAddress output must equal hub.firewallPrivateIpAddress in config/platform.bicep (10.0.0.4)
az deployment sub show -n hub-shared --query properties.outputs.firewallPrivateIpAddress.value -o tsv
# 3) Landing zone, one at a time (active subscription: spoke); the template creates rg-spoke-<spokeName>-<environment>, the route table,
#    the spoke VNet, peering both ways and, with deployTestVm = true, the test VM
az account set --subscription '<spoke-subscription-id>'
az deployment sub create -n spoke-app1-dev -l swedencentral -f landing-zones/main.bicep -p landing-zones/app1-dev.bicepparam
# Dry run: `az deployment sub what-if` with the same arguments

# Corp MG policy (the management group must exist, with only the spoke subscriptions under it: setup-management-groups.ps1).
# deploy-governance.ps1 runs it. Doesn't depend on the active subscription. Start with enforcementMode = 'DoNotEnforce' to see what it would deny.
az deployment mg create -n governance-corp -m '<prefix>-corp' -l swedencentral -f platform/governance/mgmt-groups/corp/main.bicep -p platform/governance/mgmt-groups/corp/main.bicepparam
```

### Sign in to a VM (Bastion + Microsoft Entra ID)

Every VM has a system-assigned managed identity and the `AADSSHLoginForLinux` extension, so the Bastion in the hub can sign you in with your Entra ID account (MFA and Conditional Access apply). The hub has no VMs, so this is about the spoke VMs. Contributor and Owner **don't** include VM login. Sign-in needs these roles (Microsoft Learn, "Configure Microsoft Entra ID authentication – Azure Bastion"), and the templates assign them to Entra ID groups:

| Resource | Role | Why |
|---|---|---|
| Each VM you sign in to | Virtual Machine Administrator Login (`sudo`) or Virtual Machine User Login | The VM's `AADSSHLoginForLinux` extension checks this role at sign-in |
| The same VM | Reader | Bastion and the portal read the VM |
| The VM's NIC | Reader | Bastion reads the VM's private IP |
| The VM's VNet | Reader | Required because Bastion is in a peered VNet (the hub) |
| The Bastion (`bas-hub-shared-…`) | Reader | Once, to use the Bastion |

- **Spoke resource group (landing zone template):** the `rg` module's `roleAssignments` give **Virtual Machine Administrator Login** and **Reader** to `vmAdminLoginGroupObjectId`, e.g. `sg-app1-dev-vm-admin-login`. The spoke resource group holds only the test VM, NIC and VNet, so this covers the first four rows and survives VM recreation.
- **Bastion (hub template):** the `bastion` module's `roleAssignments` give **Reader on the Bastion resource only** to `bastionUsersGroupObjectId` (`sg-hub-shared-bastion-users`). Landing zone groups are **members** of it (nested groups), so the hub stays spoke-agnostic and the assignment is recreated with the Bastion (`deployBastion`). Reader on all of `rg-hub-shared` would expose the hub VNet, the firewall and its policy. A separate resource group for Bastion isn't possible, because Azure requires the Bastion to be in its VNet's resource group.
- An empty object ID skips the assignments, so Contributor can still deploy. With IDs set, the deployment identity needs **Role Based Access Control Administrator** (or Owner) on `rg-hub-shared` and on the spoke subscription; ideally constrained by a condition to Reader and the Virtual Machine Login roles.
- Groups and their membership stay outside Bicep. Azure roles can't be assigned to Entra directory roles, only to users, groups, service principals and managed identities. Create the groups once and put their object IDs in the param files **before deploying** (a missing group fails with `PrincipalNotFound`):

```powershell
az ad group create --display-name 'sg-hub-shared-bastion-users' --mail-nickname 'sg-hub-shared-bastion-users'
az ad group create --display-name 'sg-app1-dev-vm-admin-login' --mail-nickname 'sg-app1-dev-vm-admin-login'
$bastionUsersId = az ad group show --group 'sg-hub-shared-bastion-users' --query id -o tsv    # -> connectivity.bastionUsersGroup.objectId (config/platform.json)
$app1LoginId    = az ad group show --group 'sg-app1-dev-vm-admin-login' --query id -o tsv     # -> landingZones.app1-dev.vmAdminLoginGroup.objectId (config/platform.json)
az ad group member add --group 'sg-hub-shared-bastion-users' --member-id $app1LoginId         # nested: app1 members can use the Bastion
az ad group member add --group 'sg-app1-dev-vm-admin-login' --member-id (az ad signed-in-user show --query id -o tsv)   # people go here
# After deploying: check what the templates assigned
az role assignment list --scope "/subscriptions/<app1-subscription-id>/resourceGroups/rg-spoke-app1-dev" -o table
```

- One group per landing zone and environment, named after what it grants (`sg-<spoke>-<env>-vm-admin-login`). A new spoke: create its group, add it to `sg-hub-shared-bastion-users`, and set `vmAdminLoginGroupObjectId` in its param file.
- New group members get access after signing in again, because membership is read from the token. Remove access with `az ad group member remove`.
- Group names say which login role they grant: `…-vm-admin-login` → Virtual Machine Administrator Login (`sudo`). A no-`sudo` group would be `…-vm-user-login` with Virtual Machine User Login; the templates only assign the admin role today.
- Connect: in the portal, open the VM, then **Connect** → **Bastion** → Authentication type **Microsoft Entra ID** → **Connect**. The session opens in the browser, and `whoami` shows your UPN.
- If the Entra ID option is missing, the extension isn't installed (or is the old `AADLogin` one, see the VMs bullet under Architecture) or a role is missing. Role assignments can take a few minutes to apply.
- Basic SKU means portal sessions only. `az network bastion ssh --auth-type AAD` from your own terminal needs the Standard SKU.
- Bastion → spoke VM traffic goes over the hub peering directly, not through the firewall: the hub's subnets have no route table, and the spoke's route to the hub (`10.0.0.0/22`, peering) is more specific than `0.0.0.0/0`.

### Test spoke-to-spoke routing

```powershell
# The test VMs come from the landing-zone deployments above (deployTestVm = true in the param file), in the spoke resource group.
# The testVmPrivateIpAddress output gives each VM's IP (the first VM in a subnet gets .4: app1 10.0.4.4, app2 10.0.8.4)

# Routes the platform programmed: expect 0.0.0.0/0 -> VirtualAppliance 10.0.0.4 (the firewall), plus the VNet (10.0.4.0/22)
# and hub peering (10.0.0.0/22) routes
az network nic show-effective-route-table -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001-nic-01 -o table
# Private subnet: expect false
az network vnet subnet show -g rg-spoke-app1-dev --vnet-name vnet-app1-dev-swedencentral-001 -n snet-app1-dev-swedencentral-001 --query defaultOutboundAccess
# Internet egress through the firewall: the VM's public address is the firewall's public IP
az vm run-command invoke -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001 --command-id RunShellScript --scripts "curl -s -m 10 https://api.ipify.org"
az network public-ip show -g rg-hub-shared -n pip-afw-hub-shared-swedencentral-001 --query ipAddress -o tsv --subscription '<hub-subscription-id>'
# Safety net (spoke subscription): delete the default route and the curl above times out, because the private subnet has no
# default outbound access. Redeploy the landing zone to restore the route.
az network route-table route delete -g rg-spoke-app1-dev --route-table-name rt-app1-dev-swedencentral-001 -n default-to-firewall
# Real traffic. tracepath doesn't reliably show the firewall as a hop; the firewall logs below are the proof.
az vm run-command invoke -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001 --command-id RunShellScript --scripts "ping -c 4 10.0.8.4"
# Proof in the firewall logs (management subscription; logs arrive after a few minutes).
# Expect Allow rows 10.0.4.4 -> 10.0.8.4 (rule allow-spoke-to-spoke) and 10.0.4.4 -> public IPs (rule allow-spoke-internet).
$workspaceId = az monitor log-analytics workspace show -g rg-management-shared -n log-management-shared-swedencentral-001 --subscription '<management-subscription-id>' --query customerId -o tsv
az monitor log-analytics query -w $workspaceId --analytics-query "AZFWNetworkRule | where TimeGenerated > ago(30m) | project TimeGenerated, Protocol, SourceIp, DestinationIp, Action, RuleCollection, Rule | order by TimeGenerated desc" -o table
# Negative test (hub subscription; needs `az extension add -n azure-firewall`): remove the rule collection group and the ping
# and all internet access fail (default deny; the log shows Action Deny). Redeploy the hub to bring it back.
az network firewall policy rule-collection-group delete -g rg-hub-shared --policy-name afwp-hub-shared-swedencentral-001 -n rcg-hub-shared

# Entra ID login extension on a VM: expect AADSSHLoginForLinux, Succeeded
az vm extension list -g rg-spoke-app1-dev --vm-name vm-conntest-app1-dev-swedencentral-001 -o table

# NSG on the subnet: expect the default rules of nsg-app1-dev-swedencentral-001 (and none on the NIC)
az network nic list-effective-nsg -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001-nic-01 -o json

# DNS. Cross-spoke name resolution through app1's zone link and app2's auto-registered record: expect 10.0.8.4
az vm run-command invoke -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001 --command-id RunShellScript --scripts "getent hosts vm-conntest-app2-dev-swedencentral-001.hubspoke.internal"
# Private Link zone answered from the linked central zone: SOA from azureprivatedns.net
az vm run-command invoke -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001 --command-id RunShellScript --scripts "dig +short SOA privatelink.blob.core.windows.net"
# Auto-registered records (hub subscription): the test VMs
az network private-dns record-set a list -g rg-dns-shared -z hubspoke.internal -o table

# Corp MG policy (spoke subscription under the Corp MG, enforcementMode = 'Default'); each expects RequestDisallowedByPolicy
az network public-ip create -g rg-spoke-app1-dev -n pip-policy-test --sku Standard                                        # Deny-Public-IP
az network vnet subnet create -g rg-spoke-app1-dev --vnet-name vnet-app1-dev-swedencentral-001 -n snet-policy-test --address-prefixes 10.0.5.0/24   # Deny-Subnet-Without-Udr
# Compliance of existing resources (new assignments take up to about 30 minutes; trigger-scan forces a scan)
az policy state trigger-scan --subscription '<app1-subscription-id>'
az policy state summarize --management-group '<prefix>-corp' -o table
```

### Cleanup and cost

```powershell
# Delete the test VMs (NIC and disk are deleted with them).
# Also set deployTestVm = false in the param files, or the next landing-zone deployment recreates them.
az vm delete -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001 --yes
az vm delete -g rg-spoke-app2-dev -n vm-conntest-app2-dev-swedencentral-001 --yes

# Azure Firewall Basic (about $290/month plus $0.065/GB processed, and two public IPs at about $3.6/month each) is billed
# per hour while allocated. Stop it when idle with Azure PowerShell (Install-Module Az.Network); the CLI has no deallocate.
# Spoke-to-spoke traffic and the spokes' internet access (apt, the Entra login extension install) stop while it's
# deallocated; run-command and Bastion sign-in to existing VMs keep working. The policy, public IPs and subnets stay.
$fw = Get-AzFirewall -ResourceGroupName rg-hub-shared -Name afw-hub-shared-swedencentral-001
$fw.Deallocate()
Set-AzFirewall -AzureFirewall $fw
# Start it again (or redeploy the hub, which allocates it from the template). It gets 10.0.0.4 again.
$fw     = Get-AzFirewall -ResourceGroupName rg-hub-shared -Name afw-hub-shared-swedencentral-001
$vnet   = Get-AzVirtualNetwork -ResourceGroupName rg-hub-shared -Name vnet-hub-shared-swedencentral-001
$pip    = Get-AzPublicIpAddress -ResourceGroupName rg-hub-shared -Name pip-afw-hub-shared-swedencentral-001
$mgmtIp = Get-AzPublicIpAddress -ResourceGroupName rg-hub-shared -Name pip-afw-mgmt-hub-shared-swedencentral-001
$fw.Allocate($vnet, $pip, $mgmtIp)
Set-AzFirewall -AzureFirewall $fw

# Bastion (Basic, about $140/month) can't be deallocated or stopped; it's billed until deleted.
# Turn it off: set deployBastion = false in platform/connectivity/main.bicepparam (so the next hub
# deployment doesn't recreate it), then delete the Bastion and its public IP (about $3.6/month even unattached),
# in this order: an attached public IP can't be deleted (hub subscription):
az network bastion delete -g rg-hub-shared -n bas-hub-shared-swedencentral-001 --subscription '<hub-subscription-id>'
az network public-ip delete -g rg-hub-shared -n pip-bas-hub-shared-swedencentral-001 --subscription '<hub-subscription-id>'
# Kept: AzureBastionSubnet and its NSG (free), and the role assignments on the resource groups.
# The Reader assignment on the Bastion itself is deleted with it.
# Turn it back on: set deployBastion = true and redeploy the hub (about 10 minutes); that recreates the Bastion,
# its public IP (new address; nothing depends on it, you connect through the portal) and the Reader assignment.

# Log Analytics: pay per GB ingested; the first 31 days of retention are free (dataRetention = 30).
```

### Migrating from the Linux router VM

Earlier versions routed spoke-to-spoke traffic through a Linux VM (`vm-router-shared-…`, `10.0.0.4`) in `snet-router-shared-…` (`10.0.0.0/24`). The firewall takes the same IP, so the spoke routes don't change, but its subnets overlap the router subnet, which has to go first. Spoke-to-spoke traffic stops from step 2 until the firewall is up.

```powershell
# 1) Management (see Deploy)
# 2) Remove the router, its subnet and NSG (hub subscription). Incremental deployments never delete them.
az vm delete -g rg-hub-shared -n vm-router-shared-swedencentral-001 --yes      # NIC and disk go with it
az network vnet subnet delete -g rg-hub-shared --vnet-name vnet-hub-shared-swedencentral-001 -n snet-router-shared-swedencentral-001
az network nsg delete -g rg-hub-shared -n nsg-router-shared-swedencentral-001
# Optional: the hub VM login assignments (Virtual Machine Administrator Login + Reader on rg-hub-shared) and their group are no longer used
az role assignment delete --assignee '<sg-hub-shared-vm-admin-login-object-id>' --scope "/subscriptions/<hub-subscription-id>/resourceGroups/rg-hub-shared"
az ad group delete --group 'sg-hub-shared-vm-admin-login'
# 3) Hub (see Deploy): creates the firewall subnets, policy, firewall and its public IPs
# 4) Every landing zone, one at a time (the route is unchanged; this keeps Azure in sync with the templates)
```

### Migrating to forced egress and private spoke subnets

Spokes deployed before forced egress have the `to-other-spokes` route (`10.0.0.0/16`) and default outbound access. Redeploying the hub adds the internet rule; redeploying a landing zone replaces the route with `default-to-firewall` (`0.0.0.0/0`) and sets `defaultOutboundAccess: false`. The redeploy changes `defaultOutboundAccess` on the existing subnet (verified; AVM's parameter description says creation only, but Azure accepts the update). Running VMs keep their old default outbound access until they're deallocated and started again, or recreated:

```powershell
# 1) Hub first, so the internet rule exists before any spoke sends 0.0.0.0/0 to the firewall
# 2) Per spoke (spoke subscription): redeploy, then check the subnet (expect false)
az deployment sub create -n spoke-app1-dev -l swedencentral -f landing-zones/main.bicep -p landing-zones/app1-dev.bicepparam
az network vnet subnet show -g rg-spoke-app1-dev --vnet-name vnet-app1-dev-swedencentral-001 -n snet-app1-dev-swedencentral-001 --query defaultOutboundAccess
# 3) Existing VMs pick it up after a deallocate and start (or delete them; deployTestVm = true recreates them on the next deployment)
az vm deallocate -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001
az vm start -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001
```

### Required permissions (Azure RBAC)

| Step | Scope | Minimum built-in role |
|---|---|---|
| Management | management subscription (the template creates `rg-management-shared`) | Contributor |
| Hub | hub subscription (the template creates `rg-hub-shared` and `rg-dns-shared`) | Contributor |
| Hub, with `logAnalyticsWorkspaceResourceId` set | the workspace in `rg-management-shared` (the firewall's diagnostic setting sends to it) | Log Analytics Contributor |
| Landing zone | spoke subscription (the template creates `rg-spoke-…`) | Contributor |
| Landing zone | `rg-hub-shared` (hub → spoke peering, `peer/action` on the hub VNet, nested deployment) | Network Contributor |
| Landing zone | `rg-dns-shared` (spoke VNet links on every zone, nested deployments) | Private DNS Zone Contributor |
| Hub, with `bastionUsersGroupObjectId` set | `rg-hub-shared` (Reader on the Bastion for the Bastion users group) | Role Based Access Control Administrator, ideally limited by a condition to Reader |
| Landing zone, with `vmAdminLoginGroupObjectId` set | spoke subscription (login role + Reader on the spoke resource group) | Role Based Access Control Administrator, ideally limited to Reader and the Virtual Machine Login roles |
| VM sign-in (people, through Entra ID groups) | assigned by the templates; see "Sign in to a VM" | Virtual Machine Administrator Login (or User Login) + Reader |
| Reading firewall logs | the workspace | Log Analytics Reader |
| Corp governance | the Corp management group (policy definition + three assignments) | Resource Policy Contributor |
| `setup-entra.ps1` | Entra ID (test user, groups, memberships) | Groups Administrator + User Administrator |
| `setup-management-groups.ps1` | tenant root group (create management groups), each subscription (move it) | Management Group Contributor at the tenant root + Owner on the subscriptions |
| `deploy-governance.ps1` | the Corp management group (policy definition + assignments) | Resource Policy Contributor |

- The management, hub and landing-zone templates need the subscription scope because they create resource groups; the governance template runs at management group scope.
- `what-if` needs the same roles as the deployment it previews.
- The `Microsoft.Network` resource provider must be registered in each subscription, and `Microsoft.OperationalInsights` in the management subscription. Contributor at subscription scope registers them automatically on first deployment; otherwise run `az provider register -n <namespace>`.
- **`Microsoft.Insights` must be registered by hand in the management subscription** before the hub deployment (see Deploy). The firewall's diagnostic setting needs it in the workspace's subscription too, and nothing deployed there registers it. Without it, the hub fails with `Conflict: The subscription '<management-subscription-id>' is not registered to use microsoft.insights`.
- **`Microsoft.PolicyInsights` must be registered in every subscription under Corp**, or Policy → Compliance shows the policies as compliant with 0 resources: without it Azure produces no compliance data. `deploy-governance.ps1` registers it; nothing else does. Deny still applies without it, because Resource Manager enforces it on every request.
- Management, hub and spoke subscriptions must be in the same Microsoft Entra tenant for a single-identity deployment; cross-tenant peering isn't supported by these templates.

## Architecture

- **Three templates, all subscription-scoped.** The platform team owns the management and connectivity subscriptions and the landing-zone networking. `platform/management/main.bicep` creates `rg-management-shared` and the central Log Analytics workspace; future management resources go there too. `platform/connectivity/main.bicep` creates `rg-hub-shared` with the hub VNet, firewall and Bastion, and `rg-dns-shared`; future connectivity resources go there too. `landing-zones/main.bicep` creates one spoke resource group, the route table and the spoke VNet in it, and peers it with the hub. With `deployTestVm = true` it also adds a throwaway test VM (`vm-conntest-…`) to the workload subnet. There is one template and one param file per spoke environment, with no separate test template. In all of them, `location` defaults to the deployment location (`-l`), and modules are scoped to the resource group by name with an explicit `dependsOn` on the resource group module. Adding a spoke never touches the platform templates. In a PoC the management and connectivity subscriptions may be the same one.
- **Governance per management group.** `platform/governance/mgmt-groups/<mg>/main.bicep` (`targetScope = 'managementGroup'`), one folder per management group under `mgmt-groups/`, so the path says it's a management group and not a subscription, as in the ALZ Bicep accelerator's `governance/mgmt-groups/<mg>` layout. Today only `corp/` exists. The hierarchy itself and the subscription placement come from plain `az` commands in `scripts/setup-management-groups.ps1`, not Bicep; `scripts/deploy-governance.ps1` then deploys this template, once the Corp MG exists with only spoke subscriptions under it. The connectivity subscription must not be under Corp: the firewall and Bastion need public IPs. `corp/` assigns, with the ALZ names (max 24 characters at MG scope), `identity: 'None'` (Deny needs no managed identity) and a non-compliance message each:
  - `Deny-Public-IP`: built-in *Not allowed resource types* (`6c112d4e-…`) with `microsoft.network/publicipaddresses`. No public IP resources at all, so also no public load balancer, NAT gateway or VPN gateway in a spoke.
  - `Deny-Public-IP-On-NIC`: built-in *Network interfaces should not have public IPs* (`83a86a26-…`). The second layer: no NIC may reference a public IP, even one created before the assignment, in another subscription or exempted from `Deny-Public-IP`.
  - `Deny-Subnet-Without-Udr`: the ALZ **custom** definition *Subnets should have a User Defined Route*. The template creates the definition on the Corp MG from `policy-definitions/Deny-Subnet-Without-Udr.alz_policy_definition.json`, copied unchanged from the ALZ library (`Azure/Azure-Landing-Zones-Library`, `platform/alz/policy_definitions`) and read with `loadJsonContent()`; update it by replacing the file. ALZ defines it on the intermediate root, so move it there once the hierarchy exists. It excludes `AzureBastionSubnet` and `RouteServerSubnet`, and checks only that a route table is attached, not its routes. It works with `landing-zones/main.bicep` because AVM creates the VNet without subnets and then each subnet with its route table as a child resource.
  - `enforcementMode` (`Default` or `DoNotEnforce`) applies to all three; start with `DoNotEnforce` to see in Policy compliance what would be denied. Deny doesn't change existing resources; they only show as non-compliant. Use policy exemptions (scoped and with an expiry date) for exceptions, not disabled assignments.
- **AVM.** The templates use `br/public:avm/res/network/virtual-network`, `…/resources/resource-group`, `…/network/route-table`, `…/network/network-security-group`, `…/network/bastion-host`, `…/network/azure-firewall`, `…/network/firewall-policy`, `…/operational-insights/workspace`, `br/public:avm/ptn/authorization/policy-assignment` (a pattern module; policy definitions have no AVM module and are plain resources), `…/compute/virtual-machine` and its child module `…/compute/virtual-machine/extension` (the Entra ID login extension), `…/network/private-dns-zone` and its child module `…/network/private-dns-zone/virtual-network-link` (the landing zone adds its links without redeploying the zones), each pinned to an exact version. Bump a module's version in every file that uses it.
- **Azure Firewall (Basic).** `afw-hub-shared-…` with policy `afwp-hub-shared-…`. Basic is the cheapest SKU: up to 250 Mbps, network and application rules, DNAT, threat intelligence in alert mode only (`threatIntelMode: 'Alert'`), no DNS proxy and no web categories. It needs two subnets with names Azure requires (not CAF): `AzureFirewallSubnet` (`10.0.0.0/26`) for traffic and `AzureFirewallManagementSubnet` (`10.0.0.64/26`) for Azure's management traffic, and two Standard/Static public IPs that AVM creates: `pip-afw-hub-shared-…` (SNAT to the internet, DNAT) and `pip-afw-mgmt-hub-shared-…`. It's non-zonal (`availabilityZones: []`). Azure gives it the first usable address of `AzureFirewallSubnet`, `10.0.0.4`. `config/platform.bicep` computes that IP once (`cidrHost(firewallSubnetPrefix, 3)`) for both the hub template (the `expectedFirewallPrivateIpAddress` output) and the spoke routes. Azure assigns the real one, so compare the hub's `firewallPrivateIpAddress` output with it after deploying. Rules live in the policy's one rule collection group `rcg-hub-shared`: network rule collection `rc-allow-spoke-to-spoke` (priority 100) with rule `allow-spoke-to-spoke` (`spokesAddressSpace` to `spokesAddressSpace`, any protocol and port), then `rc-allow-spoke-internet` (priority 200) with rule `allow-spoke-internet` (`spokesAddressSpace` to `*`, any protocol and port). To restrict egress later, replace `rc-allow-spoke-internet` with application rules (FQDNs over HTTP/HTTPS work on Basic without DNS proxy) or narrower network rules. Basic's 250 Mbps and $0.065/GB now cover the spokes' internet traffic too. Add rules there; AVM replaces the rule collection groups on every deployment, so rules added in the portal are lost.
- **Central logging (ALZ).** One Log Analytics workspace `log-management-shared-…` (`PerGB2018`, 30 days retention) in the management subscription, as in the ALZ reference architecture. The firewall's diagnostic setting sends all logs and metrics there, into resource-specific tables (`logAnalyticsDestinationType: 'Dedicated'`), which Microsoft recommends over the legacy `AzureDiagnostics` table. The workspace's resource group, name and resource ID are in the `management` object in `config/platform.bicep`: `platform/management/main.bicep` creates the workspace with those names, and the hub param file passes the ID (`import { management }`). An empty `logAnalyticsWorkspaceResourceId` skips the diagnostic setting.
- **VMs are as cheap as possible.** Only the spokes have VMs, and only for testing.
  - **Spoke test VMs:** Ubuntu 24.04, `Standard_D2pls_v6` (Dplsv6 family, 2 vCPU, 4 GiB, Arm64 Azure Cobalt 100, about $48/month) with accelerated networking on. Because it's Arm64, the image SKU is `server-arm64` (`testVmImageSku`); change both params together for an x64 size. The spoke subscriptions aren't offered the older sizes (B1s, B2s, A1_v2, F1s) in Sweden Central and have no Basv2/Bsv2 quota, but they have default Dplsv6 quota (10 vCPU). Check with `az vm list-skus -l swedencentral --size <size> --subscription <sub>` and `az vm list-usage`.
  - The VMs have a 30 GB `Standard_LRS` disk and no public IP. You sign in through Bastion with Entra ID, or manage them with `az vm run-command invoke`. Every VM sets `managedIdentities: { systemAssigned: true }` and gets the Entra ID login extension from a separate `…/compute/virtual-machine/extension` module (`testVmAadLogin`), named and typed exactly `AADSSHLoginForLinux`. AVM's built-in `extensionAadJoinConfig` isn't used: it hardcodes the type `AADSSHLoginforLinux` (lowercase f) and the name `AADLogin`, which work on the VM, but the portal's Bastion page then says the extension isn't installed and offers no Entra ID sign-in. A VM can't have two extensions from the same handler, so a VM that still has `AADLogin` needs `az vm extension delete -n AADLogin` once before the next deployment.
- **Every value in one place.** IDs (tenant, subscriptions, group object IDs) and the region exist only in `config/platform.json`. Names and values that more than one file uses exist only in `config/platform.bicep`: the hub's and management's resource group names, the hub VNet name and address space, the firewall subnets and IP, the DNS resource group, the internal zone name and the Private Link zone list. The templates and param files import them (`import { config, hub, management } from …/config/platform.bicep`), so nothing has to be kept in sync by hand. Names only one template uses (Bastion, firewall, NSGs) stay in that template. `enableTelemetry` is set to `false` everywhere.
- **One NSG per workload subnet, default rules only.** Each NSG is attached at subnet level (CAF/ALZ practice; ALZ enforces it with the `Deny-Subnet-Without-Nsg` policy, which exempts the firewall and gateway subnets). NICs have no NSG. The defaults allow all current traffic, because the `VirtualNetwork` service tag covers the VNet, peered VNets and UDR prefixes:
  - **Spoke subnet:** other spokes aren't peered with it, but UDR prefixes are part of the tag, and the firewall keeps the original source IP (no SNAT for private ranges), so traffic from them is allowed. Because the UDR is `0.0.0.0/0`, the tag effectively matches **any** address, so `AllowVnetInBound` / `AllowVnetOutBound` allow everything. That's harmless today (no public IPs, the firewall filters what crosses spokes), but write future NSG rules with explicit prefixes, not the `VirtualNetwork` tag (check with `az network nic list-effective-nsg`). Filtering between spokes and to the internet is the firewall policy's job; NSG rules are for finer filtering inside a spoke.
  - **Not filtered or still allowed:** Azure DNS (`168.63.129.16`) is never filtered. Internet traffic (apt, the Entra login extension) passes the NSG and goes to the firewall through the default route. SSH from Bastion comes from the peered hub, so `AllowVnetInBound` allows it.
  - **Private subnet:** `defaultOutboundAccess: false` on the spoke subnet. It isn't an NSG setting, but it's the backstop: without the firewall route, there's no internet at all.
  - **Exception: no NSG on `AzureFirewallSubnet` and `AzureFirewallManagementSubnet`.** Azure doesn't support NSGs there; the firewall policy filters instead.
  - **Exception: `nsg-bastion-…`** on `AzureBastionSubnet` has rules, because an NSG there must contain all the rules Microsoft lists (inbound 443 from Internet, GatewayManager and AzureLoadBalancer; outbound 22/3389 to VirtualNetwork, 443 to AzureCloud, 80 to Internet; 8080/5701 VirtualNetwork both ways). Without them, Bastion loses connectivity and platform updates.
  - **Adding rules:** add them as `securityRules` on the NSG module in the owning template. AVM replaces all custom rules on every deployment, so rules added in the portal are lost.
- **One Bastion for everything.** `bas-hub-shared-…` (Basic SKU) sits in the hub's `AzureBastionSubnet` (a name Azure requires, so not CAF; /26 minimum, `10.0.1.0/26`). It reaches every spoke VM over the hub peering, so spokes need no Bastion of their own. Basic is the cheapest SKU that supports peered VNets and Entra ID SSH in the portal; Developer only reaches its own VNet, and the native client needs Standard. AVM creates the Standard/Static public IP `pip-bas-…`. The hub template deploys the firewall after the Bastion (`dependsOn`), so the two don't update the hub VNet at the same time.
- **Peering lives in the landing zone.** The spoke's AVM call has one `peerings` entry with `remotePeeringEnabled: true`. AVM creates spoke → hub in the spoke resource group, and hub → spoke in a nested deployment scoped to the hub's subscription and resource group (both parsed from `hubVnetResourceId`, so the hub can be in another subscription). The identity running a landing-zone deployment needs network write access to the hub resource group as well. Attaching a VNet that wasn't created by `landing-zones/main.bicep` would need its own peering deployment.
- **Hub details come from one place.** `config/platform.bicep` exports a `hub` object (subscription ID, resource group, VNet name, resource ID and address space, firewall subnets and private IP, DNS resource group, internal zone ID, and the Private Link zone names and IDs). `platform/connectivity/main.bicep` builds the hub with those names, and the landing-zone param files `import { hub }` and pass `hub.vnetResourceId`, `hub.firewallPrivateIpAddress` and the zone IDs. The `management` object does the same for the workspace, and `config` is `config/platform.json` itself (group object IDs).
- **Each VNet template owns its VNet's subnets.** Add subnets only in the owning template, never through the portal or a PoC template. AVM deploys subnets as separate child resources, not inline in the VNet, so check with `what-if` before redeploying over a VNet that has subnets added elsewhere.
- **Naming follows the Cloud Adoption Framework (CAF)**: `<type>-<workload>-<environment>-<region>-<###>`.
  - Spokes have a required `environment` (`prod`, `dev`, `test`, `qa` or `stage`), e.g. `vnet-app1-dev-swedencentral-001`, `snet-app1-dev-swedencentral-001` and `nsg-app1-dev-swedencentral-001`. The environment is also added as a tag.
  - The hub's environment is fixed to `shared` (`vnet-hub-shared-swedencentral-001`, resource group `rg-hub-shared`) because both prod and nonprod spokes connect to it, and so is management's (`rg-management-shared`, `log-management-shared-…`). CAF's environment list doesn't include `shared`; this is a deliberate extension so that every resource follows the same pattern. Spokes can't use `shared`.
  - Hub resources: firewall `afw-hub-shared-…` and policy `afwp-hub-shared-…` (CAF abbreviations `afw`, `afwp`), public IPs `pip-afw-hub-shared-…` and `pip-afw-mgmt-hub-shared-…`, Bastion `bas-hub-shared-…` with public IP `pip-bas-hub-shared-…` and NSG `nsg-bastion-shared-…`. Rule collection groups and collections use `rcg-` and `rc-` (CAF has no format for them).
  - The region is the full `location` value, not an abbreviation, and `instance` defaults to `001`.
  - CAF has no format for Private DNS VNet links, so they're `link-<VNet name without vnet->`, e.g. `link-app1-dev-swedencentral-001` (the same name on every zone). Zone names are fixed by Azure (Private Link) or are a param (`hubspoke.internal`).
  - CAF defines no format for peerings, so they mirror its VPN connection format: `peer-<local>-to-<remote>`, with the `vnet-` prefix removed from both names (e.g. `peer-hub-shared-swedencentral-001-to-app1-dev-swedencentral-001`). The landing zone's module deployment name is cut to 64 characters with `take()`.
  - Resource groups have no region in their name. Each template creates its own: `rg-management-shared`, `rg-hub-shared` and `rg-spoke-<spokeName>-<environment>`, all overridable with the `resourceGroupName` param. Top-level deployment names follow the same pattern without `rg-` (`management-shared`, `hub-shared`, `spoke-app1-dev`) and must be unique per subscription. Default spoke subnets are the first /24 of the address space, computed with `cidrSubnet`. Each environment of a landing zone differs only by its `.bicepparam` file.
- Address plan: hub `10.0.0.0/22` (`10.0.0.0/26` AzureFirewallSubnet, `10.0.0.64/26` AzureFirewallManagementSubnet, `10.0.1.0/26` AzureBastionSubnet, the rest free, e.g. for a future DNS resolver or gateway subnet), spokes consecutive /22s after it (`10.0.4.0/22`, `10.0.8.0/22`, …; the third octet is a multiple of 4). Nothing checks for overlap, so the param files have to keep spokes from colliding.
- Run landing-zone deployments one at a time. Parallel runs all modify the hub VNet's peerings and can fail with `AnotherOperationInProgress`.

## Next steps (not implemented)

Restricting spoke internet egress per landing zone (application rules with FQDNs, e.g. Ubuntu updates and `packages.microsoft.com`, `login.microsoftonline.com`, `pas.windows.net` for the Entra login extension; IP groups per spoke), Azure Firewall Standard for DNS proxy, FQDNs in network rules and threat intelligence in deny mode, a zone-redundant firewall, the management group hierarchy and the Entra ID groups as code instead of scripts (`platform/governance/hierarchy/` at tenant scope like the ALZ accelerator, with the custom policy definitions moved to the intermediate root; the Microsoft Graph Bicep extension for groups) and more policy (including the ALZ `Deploy-Private-DNS-Zones` DeployIfNotExists policy that attaches private endpoints to the central zones, `Deny-Subnet-Without-Nsg`, and the ALZ diagnostic settings policies that send every resource's logs to the central workspace), Bastion diagnostics and VNet flow logs with Traffic Analytics into the same workspace (NSG flow logs are retired), NSG rules beyond the defaults, Bastion Standard for native-client SSH from a local terminal, PIM eligible (just-in-time) VM login assignments instead of permanent ones, deployment stacks so manually added role assignments are removed, a DNS Private Resolver (inbound endpoint for P2S VPN clients, outbound endpoint plus forwarding ruleset for on-premises DNS) once there's a VPN or on-premises network, pipelines with workload-identity (OIDC) service connections and `what-if` on pull requests, deployment stacks with deny settings so app teams can't remove the platform's peerings, subscription vending (`avm/ptn/lz/sub-vending`), and the Azure Landing Zones Bicep accelerator as a full reference.
