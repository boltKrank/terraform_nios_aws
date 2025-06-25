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

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.nios.id
  tags = {
    Name = "nios-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.nios.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public-rt"
  }
}

resource "aws_subnet" "mgmt" {
  vpc_id            = aws_vpc.nios.id
  cidr_block        = "10.255.1.0/24"
  availability_zone = "${var.aws_region}a"
  tags = { Name = "nios-mgmt-subnet" }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.mgmt.id
  route_table_id = aws_route_table.public.id
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
  instance_id = aws_instance.nios_master.id
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

  user_data = <<-EOF
    #infoblox-config
    set_grid_master: true
    remote_console_enabled: y
    default_admin_password: "${var.infoblox_password}"
    temp_license: dns dhcp enterprise nios IB-V825 
  EOF


    # If you need to override NIC settings inside the appliance:
    # network_mgmt:
    #   ip_address: "${aws_eip.mgmt_eip.public_ip}"
    #   netmask: "255.255.255.0"
    #   gateway: "${cidrhost("${aws_subnet.mgmt.cidr_block}",1)}"
    # EOF


  # Wait until AWS reports 2/2 status checks OK
  # provisioner "local-exec" {
  #   command = "aws ec2 wait instance-status-ok --instance-ids ${self.id} --region ${var.aws_region}"
  # }

  provisioner "local-exec" {
  interpreter = ["bash", "-c"]
  command     = <<-EOF
    until aws ec2 wait instance-status-ok --instance-ids ${self.id} --region ${var.aws_region}; do
      echo "Instance ${self.id} not ready yet—sleeping 15 s before retry…"
      sleep 15
    done
    echo "Instance ${self.id} is now healthy."
  EOF
}

  
}


# 5. (Optional) Use the Infoblox provider to configure the Grid Master
# provider "infoblox" {
#   server   = aws_eip.mgmt_eip.public_ip
#   username = var.infoblox_username
#   password = var.infoblox_password
# }

# resource "infoblox_grid" "master" {
#   # example of initializing the grid…  
#   # (you’ll need to refer to the infoblox Terraform provider docs for the exact blocks you want)
# }


###############################################################################
# 1. Member MGMT ENI + EIP + LAN ENI
###############################################################################
resource "aws_network_interface" "member_mgmt" {
  subnet_id       = aws_subnet.mgmt.id
  security_groups = [aws_security_group.nios_sg.id]
  tags            = { Name = "${var.name_prefix}-member-mgmt" }
}

resource "aws_eip" "member_mgmt_eip" {
  # vpc = true
}

resource "aws_eip_association" "member_mgmt_assoc" {
  allocation_id        = aws_eip.member_mgmt_eip.id
  network_interface_id = aws_network_interface.member_mgmt.id
}

resource "aws_network_interface" "member_lan" {
  subnet_id = aws_subnet.lan.id
  tags      = { Name = "${var.name_prefix}-member-lan" }
}

###############################################################################
# 1. Fetch a one-time join token from the Grid Master
###############################################################################

data "http" "join_token" {
  depends_on     = [aws_instance.nios_master]
  url            = "https://${aws_eip.mgmt_eip.public_ip}/wapi/v2.10/request_member"
  method         = "POST"
  insecure       = true

  # send the request payload
  request_body = jsonencode({
    master_ipv4addr = aws_eip.mgmt_eip.public_ip
  })

  # (optional) you can still set headers here
  request_headers = {
    Content-Type = "application/json"
    Authorization = "Basic ${base64encode("${var.infoblox_username}:${var.infoblox_password}")}"
  }
}

locals {
  # read the HTTP response body (was `body` in v2, now `response_body`)2  
  join_token = jsondecode(data.http.join_token.response_body).token
}


# ###############################################################################
# # 2. Launch the member with inline cloud-init to auto-join
# ###############################################################################
# resource "aws_instance" "nios_member" {
#   ami           = var.ami_id
#   instance_type = var.instance_type

#   network_interface {
#     network_interface_id = aws_network_interface.member_mgmt.id
#     device_index         = 0
#   }
#   network_interface {
#     network_interface_id = aws_network_interface.member_lan.id
#     device_index         = 1
#   }

#   key_name = var.key_pair_name

#   user_data = <<-EOF
#     #cloud-config
#     write_files:
#       - path: /etc/infoblox/join_info.json
#         content: |
#           {
#             "grid_master": "${aws_eip.mgmt_eip.public_ip}",
#             "token":       "${local.join_token}"
#           }
#     runcmd:
#       - /usr/local/sbin/infoblox-join-grid.sh --input /etc/infoblox/join_info.json
#   EOF

#   provisioner "local-exec" {
#     interpreter = ["bash", "-c"]
#     command     = <<-CMD
#       until aws ec2 wait instance-status-ok \
#              --instance-ids ${self.id} \
#              --region ${var.aws_region}; do
#         echo "Waiting 15s for member ${self.id} to be healthy…"
#         sleep 15
#       done
#       echo "✅ NIOS member ${self.id} is up and joined!"
#     CMD
#   }

#   tags = {
#     Name = "${var.name_prefix}-nios-member"
#   }
# }