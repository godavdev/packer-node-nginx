$ErrorActionPreference = "Stop"

$Cloud    = $env:CLOUD
$Artifact = $env:PACKER_ARTIFACT_ID
$Build    = $env:PACKER_BUILD_NAME
$ProjectRoot = Split-Path -Path $PSScriptRoot -Parent | Split-Path -Parent

Write-Host "`n═══════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  POST-PROCESSOR: Deploying $Cloud" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════`n" -ForegroundColor Cyan

if ($Cloud -eq "aws") {
  # PACKER_ARTIFACT_ID = "us-east-1:ami-0abc123..."
  $amiId = ($Artifact -split ':')[1]
  Write-Host "AMI ID: $amiId" -ForegroundColor Yellow

  aws ec2 run-instances `
    --image-id $amiId `
    --instance-type t3.micro `
    --region us-east-2 `
    --user-data "file://$ProjectRoot\deploy\cloud-init.yaml" `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=express-app-$Build}]"
}
elseif ($Cloud -eq "azure") {
  # PACKER_ARTIFACT_ID = "/subscriptions/.../images/express-nginx-app-1.0.0"
  $vmName = "express-vm-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Write-Host "Image: $Artifact" -ForegroundColor Yellow
  Write-Host "VM: $vmName" -ForegroundColor Yellow

  az vm create `
    --resource-group packer-images `
    --name $vmName `
    --image $Artifact `
    --admin-username azureuser `
    --custom-data "$ProjectRoot\deploy\cloud-init.yaml"
}
else {
  Write-Host "Unknown cloud: $Cloud" -ForegroundColor Red
  exit 1
}

Write-Host "`n  Deploy complete for $Cloud" -ForegroundColor Green
