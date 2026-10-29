/*
Connectivity platform: owns the connectivity subscription. Deploy once, after platform/management and before any landing zone.
  az deployment sub create -n hub-shared -l swedencentral -f platform/connectivity/main.bicep -p platform/connectivity/main.bicepparam
Creates its own resource groups; add further platform resource groups and modules here the same way.
Names that landing zones also use (resource groups, VNET, address space, firewall IP, DNS zones) come from config/platform.bicep.
DNS: the Private DNS zones live in rg-dns-shared. Every VNET is linked to every zone and uses Azure-provided DNS;
this template links the hub, and each landing zone links its own VNET. No resolver (no on-premises or VPN).
*/

targetScope = 'subscription'

import { hub } from '../../config/platform.bicep'

@description('Location for all hub resources')
param location string = deployment().location

@description('Instance number used in resource names (CAF <###> component)')
param instance string = '001'

@description('Supernet containing the hub and all spokes. The firewall allows all traffic within it (spoke-to-spoke) and from it to the internet.')
param spokesAddressSpace string = '10.0.0.0/16'

@description('Resource ID of the central Log Analytics workspace for firewall diagnostics (from config/platform.bicep). Empty: no diagnostic settings.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Deploy Azure Bastion. It can\'t be stopped; set false and delete it and its public IP to save cost (see README, Turn off Bastion only). The subnet and NSG stay.')
param deployBastion bool = true

@description('Object ID of the Entra ID group that gets Reader on the Bastion (e.g. sg-hub-shared-bastion-users). Landing zones\' VM admin login groups become members of it. Empty: no role assignment, and Contributor is enough to deploy.')
param bastionUsersGroupObjectId string = ''

@description('Tags applied to all hub resources')
param tags object = {}

// Shared with the landing zones, so defined once in config/platform.bicep
var resourceGroupName = hub.resourceGroupName
var vnetName = hub.vnetName
var addressPrefix = hub.addressPrefix
// AzureFirewallSubnet: first /26 of the hub; AzureFirewallManagementSubnet (Basic SKU): second /26
var firewallSubnetPrefix = hub.firewallSubnetPrefix
var firewallManagementSubnetPrefix = hub.firewallManagementSubnetPrefix
// Azure assigns the firewall the first usable address of AzureFirewallSubnet; this only names it for the outputs
var firewallPrivateIpAddress = hub.firewallPrivateIpAddress
var dnsResourceGroupName = hub.dnsResourceGroupName
// Internal zone for VM names; hub and spoke VNETs auto-register their VMs in it
var internalDnsZoneName = hub.internalDnsZoneName
// AzureBastionSubnet (/26 minimum): 10.0.1.0/26, after the two firewall subnets
var bastionSubnetPrefix = cidrSubnet(addressPrefix, 26, 4)

// CAF naming: <type>-<workload>-<environment>-<region>-<###>
// Fixed environment: the hub is shared platform infrastructure for prod and non-prod spokes
var environment = 'shared'
var firewallName = 'afw-hub-${environment}-${location}-${instance}'
var firewallPolicyName = 'afwp-hub-${environment}-${location}-${instance}'
var bastionName = 'bas-hub-${environment}-${location}-${instance}'
var bastionNsgName = 'nsg-bastion-${environment}-${location}-${instance}'
// Private Link zones for private endpoints. The list lives in config/platform.bicep because landing zones link to the same zones.
var privateLinkDnsZones = hub.privateLinkDnsZones
// CAF has no VNET link format; link-<VNET name without vnet->
var hubLinkName = 'link-hub-${environment}-${location}-${instance}'

// -------------------- HUB RESOURCE GROUP (AVM) --------------------
module rg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'rg-hub-${environment}'
  params: {
    name: resourceGroupName
    location: location
    tags: union(tags, { environment: environment })
    enableTelemetry: false
  }
}

// -------------------- DNS RESOURCE GROUP (AVM) --------------------
// Separate from the hub so DNS zones get their own RBAC and policy scope
module dnsRg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'rg-dns-${environment}'
  params: {
    name: dnsResourceGroupName
    location: location
    tags: union(tags, { environment: environment })
    enableTelemetry: false
  }
}

// -------------------- BASTION SUBNET NSG (AVM) --------------------
// Unlike the other NSGs, this one needs rules: an NSG on AzureBastionSubnet must contain all rules from
// https://learn.microsoft.com/azure/bastion/bastion-nsg, or Bastion loses connectivity and platform updates.
module bastionNsg 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: bastionNsgName
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: bastionNsgName
    location: location
    tags: union(tags, { environment: environment })
    securityRules: [
      {
        name: 'AllowHttpsInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 140
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionHostCommunication'
        properties: {
          priority: 150
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowSshRdpOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '22'
            '3389'
          ]
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'AllowBastionCommunication'
        properties: {
          priority: 120
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
        }
      }
      {
        name: 'AllowHttpOutbound'
        properties: {
          priority: 130
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
        }
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- HUB VNET (AVM) --------------------
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet-hub-${environment}-${location}-${instance}'
  // Scoped by name, so the dependency on the resource group has to be explicit
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: vnetName
    location: location
    tags: union(tags, { environment: environment })
    addressPrefixes: [
      addressPrefix
    ]
    subnets: [
      // Firewall subnets: names required by Azure Firewall (not CAF). NSGs aren't supported on them;
      // the firewall policy filters the traffic instead.
      {
        name: 'AzureFirewallSubnet'
        addressPrefix: firewallSubnetPrefix
      }
      {
        // Basic SKU only: Azure uses it for the firewall's management traffic
        name: 'AzureFirewallManagementSubnet'
        addressPrefix: firewallManagementSubnetPrefix
      }
      {
        // Name required by Azure Bastion (not CAF)
        name: 'AzureBastionSubnet'
        addressPrefix: bastionSubnetPrefix
        networkSecurityGroupResourceId: bastionNsg.outputs.resourceId
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- BASTION (AVM) --------------------
// One Bastion for the hub and every peered spoke. Basic is the cheapest SKU that reaches peered VNETs
// and supports Microsoft Entra ID SSH in the portal; the native client (az network bastion ssh) needs Standard.
// Must be in the VNET's resource group. AVM creates the Standard/Static public IP.
// Optional (deployBastion): false doesn't delete an existing Bastion (incremental deployment); delete it with az network bastion delete.
module bastion 'br/public:avm/res/network/bastion-host:0.8.2' = if (deployBastion) {
  name: bastionName
  scope: resourceGroup(resourceGroupName)
  params: {
    name: bastionName
    location: location
    tags: union(tags, { environment: environment })
    virtualNetworkResourceId: vnet.outputs.resourceId
    skuName: 'Basic'
    publicIPAddressObject: {
      name: 'pip-${bastionName}'
    }
    // Reader on the Bastion, needed for Entra ID sign-in. One spoke-agnostic group: landing zones add their
    // VM admin login groups as members (nested groups), so adding a spoke never touches this template, and the
    // assignment comes back whenever the Bastion is recreated. Needs RBAC Administrator (or Owner) on rg-hub-shared.
    roleAssignments: empty(bastionUsersGroupObjectId)
      ? []
      : [
          {
            roleDefinitionIdOrName: 'Reader'
            principalId: bastionUsersGroupObjectId
            principalType: 'Group'
            description: 'Use the hub Bastion for Entra ID sign-in (members: landing zone VM admin login groups)'
          }
        ]
    enableTelemetry: false
  }
}

// -------------------- PRIVATE DNS ZONES (AVM) --------------------
// Resolution needs a link on each VNET: Azure DNS (168.63.129.16) only answers from zones linked to the
// VM's own VNET, and peering doesn't share links. This links the hub; landing zones link themselves.
// Private Link zones: private endpoints in any spoke register their records here (DNS zone group)
module privateLinkZones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [
  for zone in privateLinkDnsZones: {
    name: take('pdnsz-${zone}', 64)
    scope: resourceGroup(dnsResourceGroupName)
    dependsOn: [
      dnsRg
    ]
    params: {
      name: zone
      tags: union(tags, { environment: environment })
      virtualNetworkLinks: [
        {
          name: hubLinkName
          virtualNetworkResourceId: vnet.outputs.resourceId
          registrationEnabled: false
        }
      ]
      enableTelemetry: false
    }
  }
]

// Internal zone for VM names. Each landing zone links its VNET with auto-registration.
module internalZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: take('pdnsz-${internalDnsZoneName}', 64)
  scope: resourceGroup(dnsResourceGroupName)
  dependsOn: [
    dnsRg
  ]
  params: {
    name: internalDnsZoneName
    tags: union(tags, { environment: environment })
    virtualNetworkLinks: [
      {
        name: hubLinkName
        virtualNetworkResourceId: vnet.outputs.resourceId
        // Registers hub VMs, if any are added later
        registrationEnabled: true
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- FIREWALL POLICY (AVM) --------------------
// Rules for the hub firewall. The firewall denies everything that no rule allows.
// Basic tier: threat intelligence can only alert, not deny.
// Add rules here; AVM replaces the rule collection groups on every deployment, so rules added in the portal are lost.
module firewallPolicy 'br/public:avm/res/network/firewall-policy:0.3.6' = {
  name: firewallPolicyName
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: firewallPolicyName
    location: location
    tags: union(tags, { environment: environment })
    tier: 'Basic'
    threatIntelMode: 'Alert'
    ruleCollectionGroups: [
      {
        name: 'rcg-hub-${environment}'
        priority: 200
        ruleCollections: [
          {
            ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
            name: 'rc-allow-spoke-to-spoke'
            priority: 100
            action: {
              type: 'Allow'
            }
            rules: [
              {
                // Spoke route tables send 0.0.0.0/0 here; the hub and a spoke's own VNET stay on more specific routes
                ruleType: 'NetworkRule'
                name: 'allow-spoke-to-spoke'
                ipProtocols: [
                  'Any'
                ]
                sourceAddresses: [
                  spokesAddressSpace
                ]
                destinationAddresses: [
                  spokesAddressSpace
                ]
                destinationPorts: [
                  '*'
                ]
              }
            ]
          }
          {
            // All spoke internet egress is allowed, SNATed to the firewall's public IP and logged (AZFWNetworkRule).
            // Spoke-to-spoke traffic matches the collection above first. To restrict egress later, replace this
            // collection with application rules (FQDNs) or narrower network rules; it's the only place to change.
            ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
            name: 'rc-allow-spoke-internet'
            priority: 200
            action: {
              type: 'Allow'
            }
            rules: [
              {
                ruleType: 'NetworkRule'
                name: 'allow-spoke-internet'
                ipProtocols: [
                  'Any'
                ]
                sourceAddresses: [
                  spokesAddressSpace
                ]
                destinationAddresses: [
                  '*'
                ]
                destinationPorts: [
                  '*'
                ]
              }
            ]
          }
        ]
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- FIREWALL (AVM) --------------------
// Forwards and filters all traffic leaving a spoke (other spokes and the internet); spoke route tables send 0.0.0.0/0 to its private IP.
// Private (RFC 1918) destinations aren't SNATed, so the target spoke sees the real source and replies through its own
// route back to the firewall. Internet-bound traffic is SNATed to the firewall's public IP (spoke subnets are private).
// Basic SKU: needs AzureFirewallManagementSubnet and a second public IP for management traffic. AVM creates both public IPs.
module firewall 'br/public:avm/res/network/azure-firewall:0.11.1' = {
  name: firewallName
  scope: resourceGroup(resourceGroupName)
  // Not in parallel with the Bastion, which also updates the hub VNET
  dependsOn: [
    bastion
  ]
  params: {
    name: firewallName
    location: location
    tags: union(tags, { environment: environment })
    azureSkuTier: 'Basic'
    virtualNetworkResourceId: vnet.outputs.resourceId
    firewallPolicyId: firewallPolicy.outputs.resourceId
    threatIntelMode: 'Alert'
    publicIPAddressObject: {
      name: 'pip-${firewallName}'
    }
    managementIPAddressObject: {
      name: 'pip-afw-mgmt-hub-${environment}-${location}-${instance}'
    }
    // Non-zonal: enough for a PoC
    availabilityZones: []
    // Central workspace in the management subscription (ALZ). All logs and metrics, into resource-specific tables (AZFW*).
    diagnosticSettings: empty(logAnalyticsWorkspaceResourceId)
      ? []
      : [
          {
            workspaceResourceId: logAnalyticsWorkspaceResourceId
            logAnalyticsDestinationType: 'Dedicated'
          }
        ]
    enableTelemetry: false
  }
}

// Values needed by landing zones
output resourceGroupName string = rg.outputs.name
output vnetId string = vnet.outputs.resourceId
output vnetName string = vnet.outputs.name
output firewallName string = firewall.outputs.name
output firewallPolicyName string = firewallPolicy.outputs.name
// Assigned by Azure; landing zones use firewallPrivateIpAddress from config/platform.bicep, so check that the two match
output firewallPrivateIpAddress string = firewall.outputs.privateIp
output expectedFirewallPrivateIpAddress string = firewallPrivateIpAddress
output bastionName string = deployBastion ? bastion!.outputs.name : ''
output dnsResourceGroupName string = dnsRg.outputs.name
output internalDnsZoneResourceId string = internalZone.outputs.resourceId
