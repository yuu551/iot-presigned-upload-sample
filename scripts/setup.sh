#!/bin/bash
yum update -y
yum install -y python3 python3-pip jq
pip3 install AWSIoTPythonSDK boto3 requests

# Retrieve secrets from Secrets Manager
SECRET=$(aws secretsmanager get-secret-value --secret-id iot_certificate_test --region ${aws_region} --query SecretString --output text)

# Extract certificate and private key
echo $SECRET | jq -r '.certificate_pem' > /home/ec2-user/certificate.pem
echo $SECRET | jq -r '.private_key' > /home/ec2-user/private.key

# Download root CA
curl https://www.amazontrust.com/repository/AmazonRootCA1.pem -o /home/ec2-user/root-ca.pem

# Copy the Python script to the EC2 instance
cat <<EOT > /home/ec2-user/iot_pubsub.py
${iot_pubsub_script}
EOT

# Copy the Python script to the EC2 instance
cat <<EOT > /home/ec2-user/upload_file.py
${upload_file_script}
EOT

# Set appropriate permissions
chown ec2-user:ec2-user /home/ec2-user/*.pem /home/ec2-user/*.key /home/ec2-user/*.py
chmod 600 /home/ec2-user/*.pem /home/ec2-user/*.key
chmod 644 /home/ec2-user/*.py