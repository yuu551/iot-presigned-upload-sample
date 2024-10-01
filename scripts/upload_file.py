import time
import json
from AWSIoTPythonSDK.MQTTLib import AWSIoTMQTTClient
import sys
import os
import requests
import uuid
from queue import Queue
import threading

# グローバル変数
iot_endpoint = "${iot_endpoint}"
myMQTTClient = None
upload_queue = Queue()
publish_queue = Queue()

def publish_worker():
    """
    MQTTメッセージを非同期で公開するワーカー関数
    """
    while True:
        topic, payload, qos = publish_queue.get()
        if topic is None:
            break
        myMQTTClient.publish(topic, payload, qos)

def on_response_message(client, userdata, message):
    """
    署名付きURLのレスポンスを処理するコールバック関数
    """
    payload = json.loads(message.payload.decode())
    file_path = upload_queue.get()
    signed_url = payload.get("url")
    bucket = payload.get("bucket")
    key = payload.get("key")

    if not signed_url:
        print("Error: No signed URL received")
        return

    try:
        upload_file_to_s3(file_path, signed_url)
        notify_file_uploaded(bucket, key)
        print(f"File uploaded successfully: {os.path.basename(file_path)}")
    except Exception as e:
        print(f"Error during upload: {str(e)}")

def setup_mqtt_client():
    """
    AWS IoT Core用のMQTTクライアントを設定する
    """
    global myMQTTClient
    myMQTTClient = AWSIoTMQTTClient("example-thing")
    myMQTTClient.configureEndpoint(iot_endpoint, 8883)
    myMQTTClient.configureCredentials(
        "/home/ec2-user/root-ca.pem",
        "/home/ec2-user/private.key",
        "/home/ec2-user/certificate.pem"
    )
    myMQTTClient.connect()
    # レスポンストピックをサブスクライブ
    myMQTTClient.subscribe("response/file_url", 1, on_response_message)

def request_signed_url(file_name):
    """
    署名付きURLをリクエストする
    """
    request_id = str(uuid.uuid4())
    request_payload = {
        "request_id": request_id,
        "file_name": file_name,
        "device_id": "example-thing"
    }
    publish_queue.put(("request/upload_url", json.dumps(request_payload), 1))

def upload_file_to_s3(file_path, signed_url):
    """
    署名付きURLを使用してファイルをS3にアップロードする
    """
    with open(file_path, 'rb') as file:
        response = requests.put(signed_url, data=file)
    
    if response.status_code != 200:
        raise Exception(f"Error uploading file: {response.status_code}")

def notify_file_uploaded(bucket, key):
    """
    ファイルのアップロードが完了したことを通知する
    """
    s3_file_path = f"s3://{bucket}/{key}"
    notification_payload = {
        "s3_file_path": s3_file_path
    }
    publish_queue.put(("notification/file_uploaded", json.dumps(notification_payload), 1))

def upload_file(file_path):
    """
    指定されたファイルのアップロードプロセスを開始する
    """
    file_name = os.path.basename(file_path)
    upload_queue.put(file_path)
    request_signed_url(file_name)

def main():
    """
    メイン関数：コマンドライン引数を処理し、アップロードプロセスを開始する
    """
    if len(sys.argv) != 2:
        print("Usage: python script.py <file_path>")
        sys.exit(1)
    
    file_path = sys.argv[1]
    
    if not os.path.exists(file_path):
        print(f"Error: File '{file_path}' does not exist.")
        sys.exit(1)

    setup_mqtt_client()

    # Publish workerスレッドの開始
    publish_thread = threading.Thread(target=publish_worker)
    publish_thread.start()

    upload_file(file_path)

    try:
        while True:
            time.sleep(5)
    except KeyboardInterrupt:
        print("Interrupted by user, shutting down.")
    finally:
        # Publish workerスレッドの終了
        publish_queue.put((None, None, None))
        publish_thread.join()
        myMQTTClient.disconnect()

if __name__ == "__main__":
    main()