terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    infoblox = {
      source  = "infobloxopen/infoblox"
      version = "2.10.0"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.aws_region
}


# 2. Build the VPC and subnets
resource "aws_vpc" "nios" {
  cidr_block = "10.255.0.0/16"
  tags = { Name = "nios-vpc" }
}

resource "aws_subnet" "mgmt" {
  vpc_id            = aws_vpc.nios.id
  cidr_block        = "10.255.1.0/24"
  availability_zone = "${var.aws_region}a"
  tags = { Name = "nios-mgmt-subnet" }
}

resource "aws_subnet" "lan" {
  vpc_id            = aws_vpc.nios.id
  cidr_block        = "10.255.2.0/24"
  availability_zone = "${var.aws_region}a"
  tags = { Name = "nios-lan-subnet" }
}

resource "aws_security_group" "nios_sg" {
  name        = "nios-mgmt-sg"
  description = "Allow SSH & WAPI"
  vpc_id      = aws_vpc.nios.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "nios-security-group" }
}

# 3. Two ENIs – one mgmt (with EIP), one LAN
resource "aws_network_interface" "mgmt" {
  subnet_id       = aws_subnet.mgmt.id
  security_groups = [aws_security_group.nios_sg.id]
  tags = { Name = "nios-mgmt-eni" }
}

resource "aws_eip" "mgmt_eip" {
  # vpc = true
  tags = { Name = "GM-eip"}
}

resource "aws_eip_association" "mgmt_assoc" {
  allocation_id        = aws_eip.mgmt_eip.id
  network_interface_id = aws_network_interface.mgmt.id
}

resource "aws_network_interface" "lan" {
  subnet_id = aws_subnet.lan.id
  tags = { Name = "nios-lan-eni" }
}

# 4. Launch the instance with both NICs
resource "aws_instance" "nios_master" {
  ami           = var.ami_id
  instance_type = var.instance_type

  network_interface {
    network_interface_id = aws_network_interface.mgmt.id
    device_index         = 0
  }
  network_interface {
    network_interface_id = aws_network_interface.lan.id
    device_index         = 1
  }

  key_name = var.key_pair_name

  root_block_device {
    volume_size           = var.boot_disk_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = { Name = "${var.name_prefix}-nios-master" }

  # Wait until AWS reports 2/2 status checks OK
  provisioner "local-exec" {
    command = "aws ec2 wait instance-status-ok --instance-ids ${self.id} --region ${var.aws_region}"
  }
  
}

# 5. (Optional) Use the Infoblox provider to configure the Grid Master
provider "infoblox" {
  server   = aws_eip.mgmt_eip.public_ip
  username = var.infoblox_username
  password = var.infoblox_password
}

# resource "infoblox_grid" "master" {
#   # example of initializing the grid…  
#   # (you’ll need to refer to the infoblox Terraform provider docs for the exact blocks you want)
# }
