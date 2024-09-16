# Terraformのバージョンと必要なプロバイダーを指定
terraform {
  required_version = ">=0.13"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~>5.61.0"
    }
  }
}

# AWSプロバイダーの設定
provider "aws" {
  region  = "ap-northeast-1"
  profile = "private-tf"
}