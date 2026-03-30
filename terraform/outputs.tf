output "jenkins_public_ip" {
  value       = aws_instance.jenkins.public_ip
  description = "Public IP of the Jenkins server — use this to access the UI"
}

output "jenkins_public_dns" {
  value       = aws_instance.jenkins.public_dns
  description = "Public DNS of the Jenkins server"
}

output "app_public_ip" {
  value       = aws_instance.app.public_ip
  description = "Public IP of the app server — test the API here"
}

output "app_private_ip" {
  value       = aws_instance.app.private_ip
  description = "Private IP of the app server — Jenkins deploys to this"
}

output "app_api_url" {
  value       = "http://${aws_instance.app.public_ip}:3000/api/health"
  description = "Direct URL to test the deployed API"
}

output "jenkins_url" {
  value       = "http://${aws_instance.jenkins.public_ip}:8080"
  description = "URL to access Jenkins UI"
}
