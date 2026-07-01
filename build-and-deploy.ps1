param(
  [ValidateSet("aws", "azure", "both")]
  [string]$Cloud = "both",
  [string]$ImageVersion = "1.0.0"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot

function Build-And-Deploy-Aws {
  param([string]$Version)

  $region = "us-east-2"
  $buildTag = "express-nginx-v$Version"

  Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
  Write-Host "  BUILD & DEPLOY: AWS ($Version)" -ForegroundColor Cyan
  Write-Host "═══════════════════════════════════════`n" -ForegroundColor Cyan

  # Build
  $output = & packer build -only="amazon-ebs.express_nginx_app" -var "image_version=$Version" (Join-Path $ProjectRoot "packer") 2>&1
  $output | ForEach-Object { Write-Host $_ }

  # Parse artifact ID
  $amiLine = $output | Select-String "${region}: ami-" | ForEach-Object { $_.Line }
  if (-not $amiLine) {
    throw "Could not find AMI ID in packer output"
  }
  $amiId = ($amiLine -split "${region}: ")[-1].Trim()
  Write-Host "`nAMI ID: $amiId" -ForegroundColor Yellow

  # Cleanup previous instances with same tag
  $oldInstances = aws ec2 describe-instances --region $region `
    --filters "Name=tag:Name,Values=express-app-$buildTag" "Name=instance-state-name,Values=running" `
    --query "Reservations[].Instances[].InstanceId" --output text 2>$null
  if ($oldInstances) {
    Write-Host "Terminating old instances: $oldInstances" -ForegroundColor Yellow
    aws ec2 terminate-instances --region $region --instance-ids $oldInstances | Out-Null
  }

  # Ensure security group for HTTP only
  $sgName = "express-app-sg"
  $sgId = aws ec2 describe-security-groups --region $region --group-names $sgName --query "SecurityGroups[0].GroupId" --output text 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating security group '$sgName'..." -ForegroundColor Yellow
    $vpcId = aws ec2 describe-vpcs --region $region --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text
    $sgId = aws ec2 create-security-group --region $region --group-name $sgName --description "Express app HTTP" --vpc-id $vpcId --query "GroupId" --output text
    aws ec2 authorize-security-group-ingress --region $region --group-id $sgId --protocol tcp --port 80 --cidr 0.0.0.0/0 | Out-Null
    Write-Host "  Security group created: $sgId (port 80 only)" -ForegroundColor Green
  } else {
    Write-Host "Using security group: $sgId" -ForegroundColor Yellow
  }

  # Launch instance
  $instanceId = aws ec2 run-instances `
    --region $region `
    --image-id $amiId `
    --instance-type t3.micro `
    --security-group-ids $sgId `
    --associate-public-ip-address `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=express-app-$buildTag}]" `
    --query "Instances[0].InstanceId" `
    --output text

  Write-Host "Instance launched: $instanceId" -ForegroundColor Green

  # Wait and get public IP
  Write-Host "Waiting for public IP..." -ForegroundColor Yellow
  Start-Sleep -Seconds 10
  $publicIp = aws ec2 describe-instances --region $region --instance-ids $instanceId --query "Reservations[0].Instances[0].PublicIpAddress" --output text

  Write-Host "`n  Access your app at: http://$publicIp" -ForegroundColor Green

  # Health check
  Write-Host "Waiting for app to respond..." -ForegroundColor Yellow
  $retries = 12
  do {
    Start-Sleep -Seconds 5
    try { $status = (Invoke-WebRequest -Uri "http://$publicIp" -TimeoutSec 5 -UseBasicParsing).StatusCode } catch { $status = $null }
    $retries--
  } while ($status -ne 200 -and $retries -gt 0)

  if ($status -eq 200) {
    Write-Host "  App is UP (HTTP 200)" -ForegroundColor Green
  } else {
    Write-Host "  App might still be starting (timeout)" -ForegroundColor Yellow
  }

  Write-Host "`n  Deploy complete for AWS ($Version)" -ForegroundColor Green
}

function Build-And-Deploy-Azure {
  param([string]$Version)

  $buildTag = "express-nginx-v$Version"
  $location = "East US"

  Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
  Write-Host "  BUILD & DEPLOY: AZURE ($Version)" -ForegroundColor Cyan
  Write-Host "═══════════════════════════════════════`n" -ForegroundColor Cyan

  # Pre-build: ensure resource group exists
  az group create --name packer-images --location $location --output none 2>$null
  Write-Host "Resource group 'packer-images' ready" -ForegroundColor Green

  # Build
  $output = & packer build -only="azure-arm.express_nginx_app" -var "image_version=$Version" (Join-Path $ProjectRoot "packer") 2>&1
  $output | ForEach-Object { Write-Host $_ }

  # Parse artifact ID
  $imageIdLine = $output | Select-String "ManagedImageId:" | ForEach-Object { $_.Line }
  if (-not $imageIdLine) {
    throw "Could not find ManagedImageId in packer output"
  }
  $imageId = ($imageIdLine -split "ManagedImageId: ")[-1].Trim()
  Write-Host "`nImage ID: $imageId" -ForegroundColor Yellow

  # Deploy
  $vmName = "express-vm-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Write-Host "VM: $vmName" -ForegroundColor Yellow

  # Cleanup previous VMs
  $oldVms = az vm list --resource-group packer-images --query "[?contains(name, 'express-vm')].name" -o tsv 2>$null
  if ($oldVms) {
    foreach ($oldVm in $oldVms) {
      Write-Host "Deleting old VM: $oldVm" -ForegroundColor Yellow
      az vm delete --resource-group packer-images --name $oldVm --yes --no-wait | Out-Null
    }
  }

  $output = az vm create `
    --resource-group packer-images `
    --name $vmName `
    --image $imageId `
    --size Standard_D2s_v3 `
    --admin-username azureuser `
    --nsg-rule SSH

  $props = $output | ConvertFrom-Json
  $publicIp = $props.publicIpAddress

  # Replace NSG to allow HTTP instead of SSH
  $nsgName = "${vmName}NSG"
  az network nsg rule create --resource-group packer-images --nsg-name $nsgName --name HTTP --priority 1010 --protocol Tcp --destination-port-ranges 80 --access Allow

  # Find and remove SSH rule by port (name varies by Azure CLI version)
  $sshRuleName = az network nsg rule list --resource-group packer-images --nsg-name $nsgName --query "[?destinationPortRange=='22'].name" -o tsv
  if ($sshRuleName) {
    az network nsg rule delete --resource-group packer-images --nsg-name $nsgName --name $sshRuleName
    Write-Host "  Removed SSH rule: $sshRuleName" -ForegroundColor Yellow
  }

  Write-Host "`n  Access your app at: http://$publicIp" -ForegroundColor Green

  # Health check
  Write-Host "Waiting for app to respond..." -ForegroundColor Yellow
  $retries = 12
  do {
    Start-Sleep -Seconds 5
    try { $status = (Invoke-WebRequest -Uri "http://$publicIp" -TimeoutSec 5 -UseBasicParsing).StatusCode } catch { $status = $null }
    $retries--
  } while ($status -ne 200 -and $retries -gt 0)

  if ($status -eq 200) {
    Write-Host "  App is UP (HTTP 200)" -ForegroundColor Green
  } else {
    Write-Host "  App might still be starting (timeout)" -ForegroundColor Yellow
  }

  Write-Host "`n  Deploy complete for AZURE ($Version)" -ForegroundColor Green
}

# ── Main ────────────────────────────────────────────────────────────

if ($Cloud -eq "aws" -or $Cloud -eq "both") {
  Build-And-Deploy-Aws -Version $ImageVersion
}

if ($Cloud -eq "azure" -or $Cloud -eq "both") {
  Build-And-Deploy-Azure -Version $ImageVersion
}

Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ALL DONE" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════" -ForegroundColor Cyan
