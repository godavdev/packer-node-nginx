param(
  [string]$Cloud,
  [string]$Artifact,
  [string]$Build = "manual"
)

$ErrorActionPreference = "Stop"

if (-not $Cloud)   { $Cloud    = $env:CLOUD }
if (-not $Artifact) { $Artifact = $env:PACKER_ARTIFACT_ID }
if (-not $Build)   { $Build    = $env:PACKER_BUILD_NAME }

Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  DEPLOY: $Cloud" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════`n" -ForegroundColor Cyan

if ($Cloud -eq "aws") {
  $region = "us-east-2"
  $amiId = ($Artifact -split ':')[1]
  Write-Host "AMI ID: $amiId" -ForegroundColor Yellow

  # Cleanup: terminate previous instances with same tag
  $oldInstances = aws ec2 describe-instances --region $region `
    --filters "Name=tag:Name,Values=express-app-$Build" "Name=instance-state-name,Values=running" `
    --query "Reservations[].Instances[].InstanceId" --output text 2>$null
  if ($oldInstances) {
    Write-Host "Terminating old instances: $oldInstances" -ForegroundColor Yellow
    aws ec2 terminate-instances --region $region --instance-ids $oldInstances | Out-Null
  }

  # Ensure security group for HTTP only (no SSH)
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
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=express-app-$Build}]" `
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
}

elseif ($Cloud -eq "azure") {
  $vmName = "express-vm-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Write-Host "Image: $Artifact" -ForegroundColor Yellow
  Write-Host "VM: $vmName" -ForegroundColor Yellow

  # Cleanup: delete previous VMs with the same tag or older than 1h
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
    --image $Artifact `
    --size Standard_D2s_v3 `
    --admin-username azureuser `
    --nsg-rule SSH

  $props = $output | ConvertFrom-Json
  $publicIp = $props.publicIpAddress

  # Replace NSG to allow HTTP instead of SSH
  $nsgName = "${vmName}NSG"
  az network nsg rule create --resource-group packer-images --nsg-name $nsgName --name HTTP --priority 1000 --protocol Tcp --destination-port-ranges 80 --access Allow 2>$null | Out-Null
  az network nsg rule delete --resource-group packer-images --nsg-name $nsgName --name default-allow-ssh 2>$null | Out-Null

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
}

else {
  Write-Host "Unknown cloud: $Cloud" -ForegroundColor Red
  exit 1
}

Write-Host "`n  Deploy complete for $Cloud" -ForegroundColor Green
