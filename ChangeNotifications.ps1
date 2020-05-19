﻿# Azure Application Change Analysis Change Notifications Onboarding Script.

# The script executes fololowing procedures in order: 
# 1.	Registers Microsoft.ChangeAnalysis resource provider if its not registered.
# 2.	Checks whether private preview feature flag is enlisted in the specified subscription and exits if not.
# 3.	Checks if change notifications configuration profile already exists, and if not creates a new one. It extracts managed identity service principal from identity tag of the profile. This service principal will be accessing workspace to get shared keys.
# 4.	Checks and creates custom role with 2 required actions to access shared keys from workspace.
# 5.	Checks and assigns custom role definition from #4 to managed identity service principal from #3 and scope is “WorkspaceResourceId”. 
# 6.	Updates change configuration profile with details of the workspace.  


# Parameters :
# -SubscriptionId       {subscriptionId}        - The subscription guid to enable change notifications for. If nothing is specified, the default selected subscription selected during azure login will be selected from Get-AzContent
# -WorkspaceId          {WorkspaceId}           - The workspace Id GUID. Can we found in the Azure Monitor Workspace -> Properties blade.
# -WorkspaceResourceId  {WorkspaceResourceId}   - The full ARM Azure Monitor Workspace Id that should look like : "/subscriptions/{SubscriptionID}/resourcegroups/{ResourceGroupName}/providers/microsoft.operationalinsights/workspaces/{AzureMonitorWorkspaceName}"
# -ActivationState      {Enabled / Disabled}    - Set to Disabled to disable notifications, set to Enable to start sending to workspace.
# -IncludeChangeDetails {Exclude / Includee}    - Set to Exclude to exclude old/new change values from event details, set to Include to include old/new change values in the event details. Warning this fields may contain PII.
# -Location             {Location}              - The closest location to your resources. To get list of all locations run Get-AzLocation cmdlet - use location property from response.


param (
  [string] $SubscriptionId = $null,
  [string] $WorkspaceId = $null,
  [string] $WorkspaceResourceId = $null, 
  [string] $ActivationState = "Enabled" ,
  [string] $IncludeChangeDetails = "Exclude",
  [string] $Location = "eastus"
)

# Check all required parameters
if ([string]::IsNullOrEmpty($SubscriptionId)) {
  Write-Host "Please specify valid -SubscriptionId parameter."
  Exit
}
if ([string]::IsNullOrEmpty($WorkspaceId)) {
  Write-Host "Please specify valid -WorkspaceId parameter."
  Exit
}
if ([string]::IsNullOrEmpty($WorkspaceResourceId)) {
  Write-Host "Please specify valid -WorkspaceResourceId parameter."
  Exit
}

if ([string]::IsNullOrEmpty($Location)) {
  Write-Host "Please specify valid -Location parameter."
  Exit
}


if ( !($ActivationState -eq "Enabled" -or $ActivationState -eq "Disabled")) {
  Write-Host "Ensure -ActivationState input parameter is set to 'Enabled' or 'Disabled'"
  Exit
}

if ( !($IncludeChangeDetails -eq "Exclude" -or $IncludeChangeDetails -eq "Include")) {
  Write-Host "Ensure -IncludeChangeDetails input parameter is set to 'Exclude' or 'Include''"
  Exit
}

Write-Host "Executing script to enable/disable notifications for subscription '$SubscriptionId'." 
Write-Host "The events will be sent to:"
Write-Host "Workspace Id = '$WorkspaceId'"
Write-Host "Workspace ResourceId = '$WorkspaceResourceId'"
Write-Host "Sending of notifications changes will be '$ActivationState'"
Write-Host "Include change details property is set to '$IncludeChangeDetails' change details in event payload."


#####################################
# Glogal definitions:
#####################################

# Resource provider name
$ResourceProviderNamespace = "Microsoft.ChangeAnalysis"

# Private feature
$RequiredFeatureName = "NotificationsPrivatePreview"

# Custom role name prefix (it should be appended by subscription id.
$CustomRoleDefinitionName = "Azure Application Change Analysis Workspace Access Role for "

# Initial notifications configuration profile
$EmptyProfile = @{    
  identity = @{
    type = "SystemAssigned"
  }
  location = $Location
}

# Updated notifications configuration profile.
$UpdatedProfile = @{
  Properties = @{
    Notifications = @{
      AzureMonitorWorkspaceProperties = @{
        WorkspaceId          = $WorkspaceId
        WorkspaceResourceId  = $WorkspaceResourceId
        IncludeChangeDetails = $IncludeChangeDetails
      }
      ActivationState = $ActivationState
    }
  }
  identity   = @{
    type = "SystemAssigned"
  }
  location   = $Location
}

#
# Method : check if private preview feature flag is enabled in the subscription and exits if not.
#
function CheckRequiredFeatureFlag() {
  Write-Host "Checking whether requred feature flag '$RequiredFeatureName' is added to subscription."

  $feature = Get-AzProviderFeature -ProviderNamespace $ResourceProviderNamespace -FeatureName $RequiredFeatureName

  # Check whether feature flag is available and requires installation
  if ($? -and $feature.RegistrationState -eq "Registered") {
    Write-Host "Notifications Private Preview Feature flag is registered."
    return $true;
  }
  else {
    Write-Host "Notficiations Private Preview Feature flag NOT registered, please send email to changeanalysishelp@microsoft.com with list of your subscription ids to onboard. The approval is manual at this point since its a private preview."
    return $false;
  }
}


#
# Method: Registers Microsoft.ChangeAnalysis 
# 
function CheckAndRegisterProvider() {
  Write-Host "Checking status of Resource Provider '$ResourceProviderNamespace'"

  $provider = Get-AzResourceProvider -ProviderNamespace $ResourceProviderNamespace

  if (!$?) {
    Write-Host "Couldn't find Resource Provider namespace '$ResourceProviderNamespace' available for selected subscription"
    return
  }
  elseif ($provider.RegistrationState -eq "Registered" -or $provider.RegistrationState -eq "Registering") {
    Write-Host "Resource provider namespace '$ResourceProviderNamespace' is already registered, skipping..."
  }
  elseif ($provider.RegistrationState -ne "Registered") {
       
    Register-AzResourceProvider -ProviderNamespace $ResourceProviderNamespace
       
    if ($?) {
      Write-Host "It would take few minutes for provider to register .." 
      do { 
        Write-Host "Going to wait for 20 seconds until provider gets into Registered state..."
           
        Sleep 20  
          
        $provider = Get-AzResourceProvider -ProviderNamespace $ResourceProviderNamespace

      }while ($provider.RegistrationState -ne "Registered" -or $provider.RegistrationState -ne "Registering" )
      Write-Host "Microsoft.ChangeAnalysis Provider is registered."    
    }

  }
}


function CreateCustomRoleDefinition() {
  $role = [Microsoft.Azure.Commands.Resources.Models.Authorization.PSRoleDefinition]::new()
  $role.Name = $CustomRoleDefinitionName
  $role.Description = 'Microsoft.ChangeAnalysis Provider notifications configuration profile access role to Azure Monitor Workspace to query shared keys'
  $role.IsCustom = $true
    
  $perms = 'Microsoft.OperationalInsights/workspaces/sharedKeys/action', 'Microsoft.OperationalInsights/workspaces/read'
  $role.Actions = $perms
  $subs = "/subscriptions/$subscriptionId"
  $role.AssignableScopes = $subs
    
  Write-Host "Creating custom role to access Azure Monitor Workspace: [" + ($role).Name + "] for scope $subs"

  return $role
}


# Custom role definition is recreated for each subscription, because assignable scope of custom roles is subscription level
# Role definition contains same list of allowed actions

function AddCustomRoleDefinition() {

  Write-Host "Checking whether custom role definition is already registered."

  $customRoleDefinition = Get-AzRoleDefinition -Name $CustomRoleDefinitionName

  if ($customRoleDefinition -eq $null) {
    $role = CreateCustomRoleDefinition
    $definition = New-AzRoleDefinition -Role $role

    if ($? -and $definition -ne $null) {
      Write-Host "New custom role definition is added with id $definition.Id"
      return
    }
        
    Write-Host "Failed to setup custom role definition, exiting..."
        
  }
  else {
    Write-Host "Custom role definition with name '$CustomRoleDefinitionName' is already registered, skipping ..."
  }
}


function AddCustomRoleToServicePrincipal($servicePrincipal) {  
    
  Write-Host "Check whether required custom role is already assigned to managed identity service principal 'servicePrincipal'"

  $assignment = Get-AzRoleAssignment -ObjectId $servicePrincipal -RoleDefinitionName $CustomRoleDefinitionName

  if ($? -and $assignment -ne $null) {
    Write-Host "Custom role definition '$CustomRoleDefinitionName' is already assigned, skipping ..."
    return $true
  }

  $roleDefinition = Get-AzRoleDefinition -Name $CustomRoleDefinitionName

  if (!$? -or $roleDefinition -eq $null) {
    Write-Host "Failed to retrieve custom role definition with name = '$CustomRoleDefinitionName' from subscription $subscriptionId"
    return $false
  }

  New-AzRoleAssignment -ObjectId $servicePrincipal  -RoleDefinitionId $roleDefinition.Id -Scope $WorkspaceResourceId

  return $true
}

#
# Method: Create Or Update configuration profile.
#
function CreateOrUpdateConfigurationProfile($httpMethod, $payload) {   
  $context = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile.DefaultContext
  $token = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.AuthenticationFactory.Authenticate($context.Account, $context.Environment, $context.Tenant.Id.ToString(), $null, [Microsoft.Azure.Commands.Common.Authentication.ShowDialog]::Never, $null, "https://management.azure.com").AccessToken

  # Authorization header
  $headers = @{
    Accept        = "application/json"
    Authorization = "Bearer $token"
  }

  # End Point to execute 
  $ApiEndPoint = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.ChangeAnalysis/profile/default?api-version=2020-04-01-preview"

  try {

    $result = $null
    if ($payload -eq $null -and $httpMethod -eq "GET") {
      $result = Invoke-RestMethod -Method GET -Uri $ApiEndPoint -ContentType "application/json" -Headers $headers
    }
    else {
      $result = Invoke-RestMethod -Method $httpMethod -Uri $ApiEndPoint -Body (ConvertTo-Json $payload -Depth 5) -ContentType "application/json" -Headers $headers
    }
        
    return $result;
         
  }
  catch {

    $statusCode = $_.Exception.Response.StatusCode.value__ 
           
    if ($statusCode -eq "404" -and $httpMethod -eq "GET") {
      return "NotFound" 
    } 

    Write-Error "Failed to execute '$httpMethod' with StatusCode: '$statusCode' on '$ApiEndPoint' with error StatusDescription: $_.Exception.Response.StatusDescription"
    Write-Host    
  }
  return "Error"
}


#
# Method: main
#

function Main() {
  # check required modules
    
  if (-not (Get-Module -ListAvailable -Name "Az.Resources")) {
    Write-Host "Module Az.Resources is not installed, please follow the instructions to set it up https://docs.microsoft.com/en-us/powershell/azure/new-azureps-module-az?view=azps-1.8.0"
    return
  } 

  # load modules
  Import-Module Az -ErrorAction SilentlyContinue

  if (! (Get-AzContext).Account) {

    Write-Host "Connecting to Azure ..."

    Connect-AzAccount 
  }

  Write-Host "Selecting subscription ..."

  if (!$subscriptionId) {
    $subscriptionId = (Get-AzContext).Subscription.Id
  }
  else {
    Get-AzSubscription -SubscriptionId $subscriptionId | Set-AzContext
  }

  if (!$?) {
    Write-Host "Script experienced an error to setup default subscription, aborting..."
    return
  }

  Write-Host "Current subscription $subscriptionId"

  Write-Host "Checking whether Microsoft.ChangeAnalysis is registered with subscription and adding it if not."

  Write-Host
    
  # Check if provider is registered and if not try to register it and wait.
  CheckAndRegisterProvider

  Write-Host

  #Check if feature flag exists and if not exit.
  if ( (CheckRequiredFeatureFlag) -eq $false) {
    
    Exit
  }
    
  Write-Host

  Write-Host "Creating empty configuration profile"
    
  # Check or Create empty profile.

  Write-Host "Check if subscription '$SubscriptionId' already has a registered notifications configuration profile."

  $response = CreateOrUpdateConfigurationProfile "GET" $null 

  if ($response -eq "NotFound") {
    Write-Host "Configuration profile doesnt exist, going to create new."
    $response = CreateOrUpdateConfigurationProfile "PUT" $EmptyProfile

    if ($response -eq "Error") {
      Write-Host "Failed to create configuration profile, aborting."
      Exit
    }
  }elseif ($response -eq "Error"){
     Write-Host "Failed to check if notifications configuration profile already registered with subscription."
     Exit
  }else {
    Write-Host "Notifications configuration profile already exists for current subscription."
  }

  Write-Host
  $servicePrincipalToAssign = $response.identity.principalId

  Write-Host "Azure Application Change Analysis Notifications Profile Managed Identity '$servicePrincipalToAssign'"

  Write-Host

  Write-Host "Creating custom role definition to access workspace 'WorkspaceResourceId'shared keys"
  $CustomRoleDefinitionName = "$CustomRoleDefinitionName $SubscriptionId"

  AddCustomRoleDefinition 

  Write-Host

  if ( (AddCustomRoleToServicePrincipal $servicePrincipalToAssign) -eq $false)
  {
     Write-Host "There was error to assign role to managed identity service principal."
     Exit
  }

  Write-Host  

  Write-Host  "Updating configuration profile with final settings."


  $response = CreateOrUpdateConfigurationProfile "PATCH" $UpdatedProfile

  if ($response -eq "Error") {
    Write-Error "Failed to update configuration profile, aborting..."
    Exit
  }

  Write-Host "At this point everything should be completed within several hours the change notifications should appear in selected workspace!" 
  Exit
    
}

# Entry point:
Main

