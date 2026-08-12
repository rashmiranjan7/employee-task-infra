output "endpoint" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "database_name" {
  value = aws_db_instance.this.db_name
}

output "master_username" {
  value = var.master_username
}

output "master_password" {
  value     = random_password.master.result
  sensitive = true
}
