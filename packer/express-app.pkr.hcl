packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
    azure = {
      version = ">= 2.0.0"
      source  = "github.com/hashicorp/azure"
    }
  }
}

# -------------------------------------------------------------------
# AWS source
# -------------------------------------------------------------------
source "amazon-ebs" "express_nginx_app" {
  ami_name      = "${var.app_name}-${var.image_version}"
  instance_type = "t3.micro"
  region        = "us-east-2"

  source_ami   = "ami-0e5497a77ef21b5ac"
  ssh_username = "ubuntu"

  tags = {
    Name        = "${var.app_name}-${var.image_version}"
    Environment = "production"
    ManagedBy   = "packer"
  }
}

# -------------------------------------------------------------------
# Azure source
# -------------------------------------------------------------------
source "azure-arm" "express_nginx_app" {
  managed_image_name                = "${var.app_name}-${var.image_version}"
  managed_image_resource_group_name = "packer-images"

  os_type         = "Linux"
  image_publisher = "Canonical"
  image_offer     = "0001-com-ubuntu-server-jammy"
  image_sku       = "22_04-lts-gen2"

  azure_tags = {
    Name        = "${var.app_name}-${var.image_version}"
    Environment = "production"
    ManagedBy   = "packer"
  }

  location           = "East US"
  vm_size            = "Standard_B1s"
  use_azure_cli_auth = true
}

# -------------------------------------------------------------------
# Shared build
# -------------------------------------------------------------------
build {
  sources = [
    "source.amazon-ebs.express_nginx_app",
    "source.azure-arm.express_nginx_app"
  ]

  # ── Step 1: Install Docker + Docker Compose ─────────────────────
  provisioner "shell" {
    script = "${path.root}/scripts/provision.sh"
  }

  # ── Step 2: Create app directory ─────────────────────────────────
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/express-app && sudo chown $(whoami) /opt/express-app"
    ]
  }

  # ── Step 3: Copy project files ───────────────────────────────────
  provisioner "file" {
    source      = "${path.root}/../compose.yml"
    destination = "/opt/express-app/compose.yml"
  }

  provisioner "file" {
    source      = "${path.root}/../Dockerfile"
    destination = "/opt/express-app/Dockerfile"
  }

  provisioner "file" {
    source      = "${path.root}/../package.json"
    destination = "/opt/express-app/package.json"
  }

  provisioner "file" {
    source      = "${path.root}/../src"
    destination = "/opt/express-app/src"
  }

  provisioner "file" {
    source      = "${path.root}/../public"
    destination = "/opt/express-app/public"
  }

  provisioner "file" {
    source      = "${path.root}/../nginx"
    destination = "/opt/express-app/nginx"
  }

  provisioner "shell" {
    inline = ["cp /opt/express-app/package.json /opt/express-app/package-lock.json"]
  }

  # ── Step 4: Build Docker images ──────────────────────────────────
  provisioner "shell" {
    inline = [
      "cd /opt/express-app",
      "sudo docker compose build"
    ]
  }

  # ── Step 5: Verify ───────────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "sudo docker compose --version",
      "sudo docker images",
      "echo 'Image build complete'"
    ]
  }

  # ── Step 6: Launch VMs from the freshly built images ─────────────
  # post-processor "shell-local" {
  #   only             = ["amazon-ebs.express_nginx_app"]
  #   environment_vars = ["CLOUD=aws"]
  #   script           = "${path.root}/scripts/deploy.ps1"
  #   execute_command  = ["powershell", "-File", "{{.Script}}"]
  # }

  # post-processor "shell-local" {
  #   only             = ["azure-arm.express_nginx_app"]
  #   environment_vars = ["CLOUD=azure"]
  #   script           = "${path.root}/scripts/deploy.ps1"
  #   execute_command  = ["powershell", "-File", "{{.Script}}"]
  # }
}
