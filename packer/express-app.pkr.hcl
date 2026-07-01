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
  instance_type = var.aws_instance_type
  region        = var.aws_region

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }

  ssh_username = "ubuntu"

  tags = {
    Name        = "${var.app_name}-${var.image_version}"
    Environment = var.node_env
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
    Environment = var.node_env
    ManagedBy   = "packer"
  }

  location           = var.azure_location
  vm_size            = var.azure_vm_size
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
    source      = "${path.root}/../.dockerignore"
    destination = "/opt/express-app/.dockerignore"
  }

  provisioner "file" {
    source      = "${path.root}/../package.json"
    destination = "/opt/express-app/package.json"
  }

  provisioner "file" {
    source      = "${path.root}/../package-lock.json"
    destination = "/opt/express-app/package-lock.json"
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

  # ── Step 6: Systemd service to start app on boot ─────────────────
  provisioner "file" {
    source      = "${path.root}/scripts/express-app.service"
    destination = "/tmp/express-app.service"
  }

  provisioner "shell" {
    inline = [
      "sudo mv /tmp/express-app.service /etc/systemd/system/express-app.service",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable express-app.service"
    ]
  }

  # ── Step 7: (Deploy manually via packer/scripts/deploy.ps1) ─────
}
