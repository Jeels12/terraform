terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Optionally create a key pair from a provided public key path (if user provided)
resource "aws_key_pair" "generated" {
  count = var.public_key_path != "" ? 1 : 0
  key_name   = "tf-generated-key-${random_id.keysuffix.hex}"
  public_key = file(var.public_key_path)
}

resource "random_id" "keysuffix" {
  keepers = {
    # random but deterministic per plan
    ts = timestamp()
  }
  byte_length = 4
}

# Security Group: allow SSH + ports 3000 & 5000
resource "aws_security_group" "dev_sg" {
  name        = "dev-flask-express-sg"
  description = "Allow SSH, Express(3000) and Flask(5000)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ip]
    description = "SSH"
  }

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Express app"
  }

  ingress {
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Flask app"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "dev-flask-express-sg"
  }
}

# Get default VPC
data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

# EC2 instance
resource "aws_instance" "app_instance" {
  ami                    = var.ami
  instance_type          = var.instance_type
  key_name               = var.key_name != "" ? var.key_name : (aws_key_pair.generated.count > 0 ? aws_key_pair.generated[0].key_name : null)
  subnet_id              = element(data.aws_subnet_ids.default.ids, 0)
  vpc_security_group_ids = [aws_security_group.dev_sg.id]

  # user_data will bootstrap the instance: install python/node, create apps & services.
  user_data = <<-EOF
              #!/bin/bash
              set -e
              # Simple cloud-init script for Ubuntu-like systems.
              exec >/var/log/user-data.log 2>&1
              apt-get update -y
              apt-get upgrade -y

              # Install essentials
              apt-get install -y python3 python3-venv python3-pip git build-essential curl

              # Install Node.js (LTS) from NodeSource
              curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
              apt-get install -y nodejs

              # Directory setup
              mkdir -p /opt/flask_app
              mkdir -p /opt/express_app

              # --------- Create sample Flask app ---------
              cat > /opt/flask_app/app.py <<'PY'
              from flask import Flask, jsonify
              app = Flask(__name__)

              @app.route('/')
              def index():
                  return jsonify({"message": "Hello from Flask on port 5000"})

              if __name__ == '__main__':
                  app.run(host='0.0.0.0', port=5000)
              PY

              # virtualenv & install dependencies
              python3 -m venv /opt/flask_app/venv
              /opt/flask_app/venv/bin/pip install --upgrade pip
              /opt/flask_app/venv/bin/pip install flask gunicorn

              # Create systemd service for Flask (gunicorn)
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

              # --------- Create sample Express app ---------
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

              # Create systemd service for Express
              cat > /etc/systemd/system/express.service <<'SERV2'
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
              SERV2

              # Start & enable services
              systemctl daemon-reload
              systemctl enable flask.service
              systemctl start flask.service
              systemctl enable express.service
              systemctl start express.service

              # Provide a quick health-check file
              echo "Flask and Express launched by cloud-init" > /var/www-apps-readme.txt

              EOF

  tags = {
    Name = "flask-express-instance"
  }

  # Wait for instance to be accessible
  provisioner "local-exec" {
    command = "echo 'EC2 instance created: ${self.public_ip}'"
  }
}

# Optional: if user provided no existing key_name and supplied a public_key_path, output the generated key name and save public key path
output "instance_public_ip" {
  value = aws_instance.app_instance.public_ip
}

output "instance_id" {
  value = aws_instance.app_instance.id
}

output "security_group_id" {
  value = aws_security_group.dev_sg.id
}
