output "public_ip" {
  description = "Jenkins UI is at http://<this-ip>:8080 once user_data finishes (2-3 minutes after apply)"
  value       = aws_instance.jenkins.public_ip
}

output "instance_id" {
  value = aws_instance.jenkins.id
}
