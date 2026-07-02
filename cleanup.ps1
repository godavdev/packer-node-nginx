param(
  [ValidateSet("aws", "azure", "both")]
  [string]$Cloud = "both"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot

function Cleanup-Aws {
  $region = "us-east-2"

  Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
  Write-Host "  CLEANUP: AWS" -ForegroundColor Cyan
  Write-Host "═══════════════════════════════════════`n" -ForegroundColor Cyan

  # Terminate running instances with express-app tag
  $instances = aws ec2 describe-instances --region $region `
    --filters "Name=tag:Name,Values=express-app-*" "Name=instance-state-name,Values=running" `
    --query "Reservations[].Instances[].InstanceId" --output text 2>$null
  if ($instances) {
    Write-Host "Terminating instances: $instances" -ForegroundColor Yellow
    aws ec2 terminate-instances --region $region --instance-ids $instances | Out-Null
    Write-Host "  Instances terminated" -ForegroundColor Green
  } else {
    Write-Host "No running instances found" -ForegroundColor Yellow
  }

  # Delete security group
  $sgId = aws ec2 describe-security-groups --region $region --group-names "express-app-sg" --query "SecurityGroups[0].GroupId" --output text 2>$null
  if ($sgId) {
    aws ec2 delete-security-group --region $region --group-id $sgId 2>&1 | Out-Null
    Write-Host "Security group deleted: $sgId" -ForegroundColor Green
  } else {
    Write-Host "No security group found" -ForegroundColor Yellow
  }

  # Deregister AMIs and delete snapshots
  $amis = aws ec2 describe-images --owners self --region $region --query "Images[?starts_with(Name, 'express-nginx-app-')].[ImageId]" --output text 2>$null
  if ($amis) {
    foreach ($amiId in $amis) {
      $snapshotId = (aws ec2 describe-images --image-ids $amiId --region $region | ConvertFrom-Json).Images[0].BlockDeviceMappings[0].Ebs.SnapshotId
      aws ec2 deregister-image --image-id $amiId --region $region | Out-Null
      Write-Host "AMI deregistered: $amiId" -ForegroundColor Green
      if ($snapshotId) {
        aws ec2 delete-snapshot --snapshot-id $snapshotId --region $region | Out-Null
        Write-Host "Snapshot deleted: $snapshotId" -ForegroundColor Green
      }
    }
  } else {
    Write-Host "No AMIs found" -ForegroundColor Yellow
  }

  Write-Host "`n  AWS cleanup complete" -ForegroundColor Green
}

function Cleanup-Azure {
  Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
  Write-Host "  CLEANUP: AZURE" -ForegroundColor Cyan
  Write-Host "═══════════════════════════════════════`n" -ForegroundColor Cyan

  # Delete all express-vm VMs
  $vms = az vm list --resource-group packer-images --query "[?contains(name, 'express-vm')].name" -o tsv 2>$null
  if ($vms) {
    foreach ($vm in $vms) {
      az vm delete --resource-group packer-images --name $vm --yes | Out-Null
      Write-Host "VM deleted: $vm" -ForegroundColor Green
    }
  } else {
    Write-Host "No VMs found" -ForegroundColor Yellow
  }

  # Delete packer-images RG (contains the managed image)
  $exists = az group exists --name "packer-images" 2>$null
  if ($exists -eq "true") {
    az group delete --name packer-images --yes --no-wait | Out-Null
    Write-Host "Resource group 'packer-images' deletion initiated" -ForegroundColor Green
  } else {
    Write-Host "Resource group 'packer-images' not found" -ForegroundColor Yellow
  }

  Write-Host "`n  Azure cleanup complete" -ForegroundColor Green
}

# ── Main ────────────────────────────────────────────────────────────

if ($Cloud -eq "aws" -or $Cloud -eq "both") {
  Cleanup-Aws
}

if ($Cloud -eq "azure" -or $Cloud -eq "both") {
  Cleanup-Azure
}

Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  CLEANUP DONE" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════" -ForegroundColor Cyan
