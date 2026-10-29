using 'main.bicep'

import { config, management } from '../../config/platform.bicep'

param tags = {
  workload: 'hub-spoke'
}
// Azure Bastion can't be stopped (about $140/month). To turn it off: set false, then delete it
// (see "Cleanup and cost" in CLAUDE.md). To turn it back on: set true and redeploy the hub.
param deployBastion = true
// Entra ID group with Reader on the Bastion; landing zone VM admin login groups are its members (see "Sign in to a VM" in CLAUDE.md).
// From config/platform.json, written by scripts/setup-entra.ps1. Empty: no role assignment.
param bastionUsersGroupObjectId = config.connectivity.bastionUsersGroup.objectId
// Firewall diagnostics go to the central workspace in the management subscription (deploy platform/management first)
param logAnalyticsWorkspaceResourceId = management.logAnalyticsWorkspaceResourceId
