param(
  [string]$ImageVersion = "1.0.0"
)

$ErrorActionPreference = "Stop"

az group create --name packer-images --location "East US" --output none 2>$null

packer build -only="azure-arm.express_nginx_app" -var "image_version=$ImageVersion" packer/

