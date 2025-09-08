terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"
}

provider "aws" {
  region = var.region
}

# Optionally create a key pair from a local public key file
resource "random_id" "key_suffix" {
  byte_length = 4
}

resource "aws_key_pair" "generated" {
  count      = var.public_key_path != "" ? 1 : 0
  key_name   = "tf-generated-key-${random_id.key_suffix.hex}"
  public_key = file(var.public_key_path)
}

# Networking: VPC, subnets, IGW, route table
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr
  tags = { Name = "tf-separate-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "tf-separate-igw" }
}

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr_1
  map_public_ip_on_launch = true
  availability_zone       = var.availability_zone != "" ? var.availability_zone : null
  tags = { Name = "tf-public-subnet-1" }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr_2
  map_public_ip_on_launch = true
  availability_zone       = var.availability_zone != "" ? var.availability_zone : null
  tags = { Name = "tf-public-subnet-2" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "tf-public-rt" }
}

resource "aws_route_table_association" "a1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "a2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# Security Groups
# SG for Flask instance — allow SSH, HTTP for flask (5000), and incoming from express SG (3000) if needed
resource "aws_security_group" "flask_sg" {
  name        = "flask-sg"
  description = "Allow SSH and Flask port, and allow from express-sg for communication"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "Flask app port"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # allow Express SG to connect to Flask on 5000
  ingress {
    description      = "Allow express instance in express_sg"
    from_port        = 5000
    to_port          = 5000
    protocol         = "tcp"
    security_groups  = [aws_security_group.express_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "flask-sg" }
}

# SG for Express instance — allow SSH, Express port, and allow from flask SG (5000) if they need to talk back
resource "aws_security_group" "express_sg" {
  name        = "express-sg"
  description = "Allow SSH and Express port"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "Express app port"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # allow Flask SG to connect to Express if needed
  ingress {
    description     = "Allow flask instance in flask_sg (optional)"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.flask_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "express-sg" }
}

# Use existing key_name if provided else created key pair resource
locals {
  effective_key_name = var.key_name != "" ? var.key_name : (aws_key_pair.generated.count > 0 ? aws_key_pair.generated[0].key_name : null)
}

# Data: find official Ubuntu 22.04 Jammy AMI (region-specific)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Flask EC2 Instance
resource "aws_instance" "flask" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public_1.id
  vpc_security_group_ids = [aws_security_group.flask_sg.id]
  key_name               = local.effective_key_name

  tags = { Name = "flask-instance" }

  user_data = <<-EOF
              #!/bin/bash
              set -e
              exec >/var/log/user-data-flask.log 2>&1
              apt-get update -y
              apt-get upgrade -y
              apt-get install -y python3 python3-venv python3-pip curl git build-essential

              mkdir -p /opt/flask_app
              cat > /opt/flask_app/app.py <<'PY'
              from flask import Flask, jsonify
              app = Flask(__name__)
              @app.route('/')
              def index():
                  return jsonify({"message": "Hello from Flask on port 5000"})
              if __name__ == '__main__':
                  app.run(host='0.0.0.0', port=5000)
              PY

              python3 -m venv /opt/flask_app/venv
              /opt/flask_app/venv/bin/pip install --upgrade pip
              /opt/flask_app/venv/bin/pip install flask gunicorn

              cat > /etc/systemd/system/flask.service <<'SERV'
              [Unit]
              Description=Gunicorn instance to serve Flask app
              After=network.target

              [Service]
              User=root
              Group=www-data
              WorkingDirectory=/opt/flask_app
              Environment="PATH=/opt/flask_app/venv/bin"
              ExecStart=/opt/flask_app/venv/bin/gunicorn --bind 0.0.0.0:5000 app:app

              [Install]
              WantedBy=multi-user.target
              SERV

              systemctl daemon-reload
              systemctl enable flask.service
              systemctl start flask.service
              EOF
}

# Express EC2 Instance
resource "aws_instance" "express" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public_2.id
  vpc_security_group_ids = [aws_security_group.express_sg.id]
  key_name               = local.effective_key_name

  tags = { Name = "express-instance" }

  user_data = <<-EOF
              #!/bin/bash
              set -e
              exec >/var/log/user-data-express.log 2>&1
              apt-get update -y
              apt-get upgrade -y
              apt-get install -y curl nodejs npm build-essential

              mkdir -p /opt/express_app
              cat > /opt/express_app/index.js <<'JS'
              const express = require('express');
              const app = express();
              const port = 3000;
              app.get('/', (req, res) => {
                res.json({ message: 'Hello from Express on port 3000' });
              });
              app.listen(port, '0.0.0.0', () => {
                console.log(`Express app listening at http://0.0.0.0:${port}`);
              });
              JS

              cat > /opt/express_app/package.json <<'JSON'
              {
                "name": "sample-express",
                "version": "1.0.0",
                "main": "index.js",
                "scripts": {
                  "start": "node index.js"
                },
                "dependencies": {
                  "express": "^4.18.2"
                }
              }
              JSON

              cd /opt/express_app
              npm install --production

              cat > /etc/systemd/system/express.service <<'SERV'
              [Unit]
              Description=Node/Express app
              After=network.target

              [Service]
              User=root
              Group=www-data
              WorkingDirectory=/opt/express_app
              ExecStart=/usr/bin/node /opt/express_app/index.js
              Restart=always
              Environment=NODE_ENV=production

              [Install]
              WantedBy=multi-user.target
              SERV

              systemctl daemon-reload
              systemctl enable express.service
              systemctl start express.service
              EOF
}

# Outputs
output "flask_instance_public_ip" {
  value = aws_instance.flask.public_ip
  description = "Public IP of Flask instance"
}

output "express_instance_public_ip" {
  value = aws_instance.express.public_ip
  description = "Public IP of Express instance"
}

output "flask_url" {
  value = "http://${aws_instance.flask.public_ip}:5000"
}

output "express_url" {
  value = "http://${aws_instance.express.public_ip}:3000"
}
