import json
import os
import datetime
import boto3
from botocore.exceptions import ClientError

def lambda_handler(event, context):
    # S3クライアントの初期化
    s3_client = boto3.client('s3')
    # IoT クライアントの初期化
    iot_client = boto3.client('iot-data')
    # 環境変数からS3バケット名を取得
    bucket_name = os.environ['S3_BUCKET']

    # デバイスIDの取得（イベントから）
    device_id = event.get('device_id', 'unknown')

    # オブジェクトキーの設定（デバイスIDをプレフィックスとして使用）
    timestamp = datetime.datetime.now().strftime('%Y%m%d%H%M%S')
    object_key = f"{device_id}/upload_{timestamp}.txt"

    try:
        # 署名付きURLの生成
        url = s3_client.generate_presigned_url(
            'put_object',
            Params={'Bucket': bucket_name, 'Key': object_key},
            ExpiresIn=3600  # URLの有効期限（秒）
        )

        # MQTTメッセージの作成
        message = {
            'url': url,
            'bucket': bucket_name,
            'key': object_key
        }

        # MQTTトピックの設定
        topic = 'response/file_url'

        # MQTTメッセージの発行
        iot_client.publish(
            topic=topic,
            qos=1,
            payload=json.dumps(message)
        )

        return {
            'statusCode': 200,
            'body': json.dumps('URL generated and sent successfully')
        }

    except ClientError as e:
        print(e)
        return {
            'statusCode': 500,
            'body': json.dumps('Error generating URL')
        }