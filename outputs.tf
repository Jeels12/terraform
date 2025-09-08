output "public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.app_instance.public_ip
}

output "flask_url" {
  value = "http://${aws_instance.app_instance.public_ip}:5000"
}

output "express_url" {
  value = "http://${aws_instance.app_instance.public_ip}:3000"
}
