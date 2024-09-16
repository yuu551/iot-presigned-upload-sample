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
    while True:
        topic, payload, qos = publish_queue.get()
        if topic is None:
            break
        myMQTTClient.publish(topic, payload, qos)

def on_response_message(client, userdata, message):
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
        notify_file_uploaded(os.path.basename(file_path), bucket, key)
        print(f"File uploaded successfully: {os.path.basename(file_path)}")
    except Exception as e:
        print(f"Error during upload: {str(e)}")

def setup_mqtt_client():
    global myMQTTClient
    myMQTTClient = AWSIoTMQTTClient("example-thing")
    myMQTTClient.configureEndpoint(iot_endpoint, 8883)
    myMQTTClient.configureCredentials(
        "/home/ec2-user/root-ca.pem",
        "/home/ec2-user/private.key",
        "/home/ec2-user/certificate.pem"
    )
    myMQTTClient.connect()
    # サブスクライブできるよう設定
    myMQTTClient.subscribe("response/file_url", 1, on_response_message)

def request_signed_url(file_name, file_size):
    request_id = str(uuid.uuid4())
    request_payload = {
        "request_id": request_id,
        "file_name": file_name,
        "file_size": file_size,
        "device_id": "example-thing"
    }
    publish_queue.put(("request/upload_url", json.dumps(request_payload), 1))

def upload_file_to_s3(file_path, signed_url):
    with open(file_path, 'rb') as file:
        response = requests.put(signed_url, data=file)
    
    if response.status_code != 200:
        raise Exception(f"Error uploading file: {response.status_code}")

def notify_file_uploaded(file_name, bucket, key):
    s3_file_path = f"s3://{bucket}/{key}"
    notification_payload = {
        "file_name": file_name,
        "s3_file_path": s3_file_path
    }
    publish_queue.put(("notification/file_uploaded", json.dumps(notification_payload), 1))

def upload_file(file_path):
    file_name = os.path.basename(file_path)
    file_size = os.path.getsize(file_path)

    upload_queue.put(file_path)
    request_signed_url(file_name, file_size)

def main():
    if len(sys.argv) != 2:
        print("Usage: python script.py <file_name>")
        sys.exit(1)
    
    file_name = sys.argv[1]
    file_path = os.path.join(os.getcwd(), file_name)
    
    if not os.path.exists(file_path):
        print(f"Error: File '{file_name}' does not exist in the current directory.")
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