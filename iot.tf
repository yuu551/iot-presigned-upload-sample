# IoT証明書を作成し、アクティブに設定
resource "aws_iot_certificate" "cert" {
  active = true
}

# IoTデバイス（Thing）を作成
resource "aws_iot_thing" "example" {
  name = "example-thing"
}

# IoTポリシーを作成
# このポリシーは特定のトピックに対する操作を許可
resource "aws_iot_policy" "pubsub" {
  name = "PubSubToSpecificTopic"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 特定のクライアントの接続を許可
        Effect   = "Allow"
        Action   = ["iot:Connect"]
        Resource = ["arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:client/${aws_iot_thing.example.name}"]
      },
      {
        # 特定のトピックへの発行と受信を許可
        Effect   = "Allow"
        Action   = ["iot:Publish", "iot:Receive"]
        Resource = ["arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topic/my/test/topic", "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topic/request/upload_url", "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topic/notification/file_uploaded", "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topic/response/file_url"]
      },
      {
        # 特定のトピックフィルターへのサブスクリプションを許可
        Effect   = "Allow"
        Action   = ["iot:Subscribe"]
        Resource = ["arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topicfilter/my/test/topic", "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topicfilter/response/file_url"]
      }
    ]
  })
}

# ポリシーを証明書にアタッチ
resource "aws_iot_policy_attachment" "attach_policy_to_cert" {
  policy = aws_iot_policy.pubsub.name
  target = aws_iot_certificate.cert.arn
}

# 証明書をThingにアタッチ
resource "aws_iot_thing_principal_attachment" "attach_cert_to_thing" {
  principal = aws_iot_certificate.cert.arn
  thing     = aws_iot_thing.example.name
}

# 証明書情報を保存するためのSecrets Managerシークレットを作成
resource "aws_secretsmanager_secret" "iot_cert" {
  name                           = "iot_certificate_test"
  force_overwrite_replica_secret = true
  recovery_window_in_days        = 0
}

# 証明書情報をシークレットに保存
resource "aws_secretsmanager_secret_version" "iot_cert" {
  secret_id = aws_secretsmanager_secret.iot_cert.id
  secret_string = jsonencode({
    certificate_pem = aws_iot_certificate.cert.certificate_pem
    private_key     = aws_iot_certificate.cert.private_key
  })
}

# IoTのエンドポイントを取得
data "aws_iot_endpoint" "data" {
  endpoint_type = "iot:Data-ATS"
}

# IAMロールの作成（認証情報プロバイダー用）
resource "aws_iam_role" "iot_device" {
  name = "iot_device_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "credentials.iot.amazonaws.com"
      }
    }]
  })
}

# S3バケットの作成
# S3バケットの作成
resource "aws_s3_bucket" "iot_bucket" {
  bucket = "sample-iot-bucket-presigned-20240903" # ユニークな名前に変更してください
}

# Lambda関数用のIAMロールの作成
resource "aws_iam_role" "lambda_role" {
  name = "iot_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Lambda関数用のIAMポリシーの作成
resource "aws_iam_role_policy" "lambda_policy" {
  name = "iot_lambda_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.iot_bucket.arn,
          "${aws_s3_bucket.iot_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "iot:Publish"
        ]
        Resource = "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topic/response/file_url"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/index.py"
  output_path = "${path.module}/lambda/index.zip"
}

# Lambda関数の作成
resource "aws_lambda_function" "iot_lambda" {
  filename      = data.archive_file.lambda_zip.output_path
  function_name = "iot_s3_url_generator"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.lambda_handler"
  runtime       = "python3.10"

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.iot_bucket.id
    }
  }

}

# IoT Ruleの作成
resource "aws_iot_topic_rule" "iot_rule" {
  name        = "iot_s3_url_rule"
  description = "IoT Rule to invoke Lambda for S3 URL generation"
  enabled     = true
  sql         = "SELECT * FROM 'request/upload_url'"
  sql_version = "2016-03-23"

  lambda {
    function_arn = aws_lambda_function.iot_lambda.arn
  }
}

# IoT RuleがLambda関数を呼び出すための権限を付与
resource "aws_lambda_permission" "iot_lambda_permission" {
  statement_id  = "AllowIoTInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.iot_lambda.function_name
  principal     = "iot.amazonaws.com"
  source_arn    = aws_iot_topic_rule.iot_rule.arn
}