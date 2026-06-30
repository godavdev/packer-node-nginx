param(
  [string]$Cloud,
  [string]$Artifact,
  [string]$Build = "manual"
)

$ErrorActionPreference = "Stop"

if (-not $Cloud)   { $Cloud    = $env:CLOUD }
if (-not $Artifact) { $Artifact = $env:PACKER_ARTIFACT_ID }
if (-not $Build)   { $Build    = $env:PACKER_BUILD_NAME }
$ProjectRoot = Split-Path -Path $PSScriptRoot -Parent | Split-Path -Parent

Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  POST-PROCESSOR: Deploying $Cloud" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════`n" -ForegroundColor Cyan

if ($Cloud -eq "aws") {
  $region = "us-east-2"
  $amiId = ($Artifact -split ':')[1]
  Write-Host "AMI ID: $amiId" -ForegroundColor Yellow

  # Ensure security group allows HTTP on port 80
  $sgName = "express-app-sg"
  $sgId = aws ec2 describe-security-groups --region $region --group-names $sgName --query "SecurityGroups[0].GroupId" --output text 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Creating security group '$sgName'..." -ForegroundColor Yellow
    $vpcId = aws ec2 describe-vpcs --region $region --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text
    $sgId = aws ec2 create-security-group --region $region --group-name $sgName --description "Express app HTTP" --vpc-id $vpcId --query "GroupId" --output text
    aws ec2 authorize-security-group-ingress --region $region --group-id $sgId --protocol tcp --port 22 --cidr 0.0.0.0/0 | Out-Null
    aws ec2 authorize-security-group-ingress --region $region --group-id $sgId --protocol tcp --port 80 --cidr 0.0.0.0/0 | Out-Null
    Write-Host "  Security group created: $sgId" -ForegroundColor Green
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
    --user-data "file://$ProjectRoot\deploy\cloud-init.yaml" `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=express-app-$Build}]" `
    --query "Instances[0].InstanceId" `
    --output text

  Write-Host "Instance launched: $instanceId" -ForegroundColor Green

  # Wait and get public IP
  Write-Host "Waiting for public IP..." -ForegroundColor Yellow
  Start-Sleep -Seconds 10
  $publicIp = aws ec2 describe-instances --region $region --instance-ids $instanceId --query "Reservations[0].Instances[0].PublicIpAddress" --output text

  Write-Host "`n  Access your app at: http://$publicIp" -ForegroundColor Green
}

elseif ($Cloud -eq "azure") {
  $vmName = "express-vm-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Write-Host "Image: $Artifact" -ForegroundColor Yellow
  Write-Host "VM: $vmName" -ForegroundColor Yellow

  $output = az vm create `
    --resource-group packer-images `
    --name $vmName `
    --image $Artifact `
    --admin-username azureuser `
    --custom-data "$ProjectRoot\deploy\cloud-init.yaml" `
    --nsg-rule HTTP

  $publicIp = ($output | ConvertFrom-Json).publicIpAddress
  Write-Host "`n  Access your app at: http://$publicIp" -ForegroundColor Green
}

else {
  Write-Host "Unknown cloud: $Cloud" -ForegroundColor Red
  exit 1
}

Write-Host "`n  Deploy complete for $Cloud" -ForegroundColor Green
