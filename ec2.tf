# 現在のAWSリージョンとアカウントIDを取得
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# VPCの作成
resource "aws_vpc" "vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

# パブリックサブネットの作成
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = true
}

# プライベートサブネットの作成
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-1a"
}

# インターネットゲートウェイの作成
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.vpc.id
}

# Elastic IPの作成（NAT Gateway用）
resource "aws_eip" "nat_eip" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.this]
}

# NAT Gatewayの作成
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id
}

# パブリックルートテーブルの作成
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

# プライベートルートテーブルの作成
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
}

# パブリックルートテーブルの関連付け
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public.id
}

# プライベートルートテーブルの関連付け
resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private.id
}

# セキュリティグループの作成
resource "aws_security_group" "allow_outbound" {
  name        = "allow_outbound"
  description = "Allow outbound traffic"
  vpc_id      = aws_vpc.vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# テンプレートファイルの読み込みとローカル変数の設定
locals {
  iot_pubsub_script = templatefile("${path.module}/scripts/iot_pubsub.py", {
    iot_endpoint = data.aws_iot_endpoint.data.endpoint_address
  })

  upload_file_script = templatefile("${path.module}/scripts/upload_file.py", {
    iot_endpoint = data.aws_iot_endpoint.data.endpoint_address
  })

  setup_script = templatefile("${path.module}/scripts/setup.sh", {
    iot_pubsub_script  = local.iot_pubsub_script
    upload_file_script = local.upload_file_script
    aws_region         = data.aws_region.current.name
  })
}

# IAMロールの作成
resource "aws_iam_role" "ec2_iot_role" {
  name = "ec2_iot_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

# IAMロールにポリシーをアタッチ
resource "aws_iam_role_policy_attachment" "secrets_manager_access" {
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
  role       = aws_iam_role.ec2_iot_role.name
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.ec2_iot_role.name
}

# IAMインスタンスプロファイルの作成
resource "aws_iam_instance_profile" "ec2_iot_profile" {
  name = "ec2_iot_profile"
  role = aws_iam_role.ec2_iot_role.name
}

# EC2インスタンスの作成（プライベートサブネットに配置）
resource "aws_instance" "iot_example" {
  ami                    = "ami-00c79d83cf718a893"
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private_subnet.id
  iam_instance_profile   = aws_iam_instance_profile.ec2_iot_profile.name
  user_data              = local.setup_script
  vpc_security_group_ids = [aws_security_group.allow_outbound.id]
}