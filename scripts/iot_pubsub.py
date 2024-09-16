import time
import json
from AWSIoTPythonSDK.MQTTLib import AWSIoTMQTTClient
import boto3

# IoT Core endpoint
iot_endpoint = "${iot_endpoint}"

# Create an IoT client
myMQTTClient = AWSIoTMQTTClient("example-thing")
myMQTTClient.configureEndpoint(iot_endpoint, 8883)

# Configure credentials
myMQTTClient.configureCredentials(
    "/home/ec2-user/root-ca.pem",
    "/home/ec2-user/private.key",
    "/home/ec2-user/certificate.pem"
)

# Connect to IoT Core
myMQTTClient.connect()

# Publish to a topic
def publish_message():
    message = {"message": "Hello from EC2!"}
    myMQTTClient.publish("my/test/topic", json.dumps(message), 1)
    print(f"Published: {message}")

# Subscribe to a topic
def customCallback(client, userdata, message):
    print(f"Received message from topic {message.topic}: {message.payload}")

myMQTTClient.subscribe("my/test/topic", 1, customCallback)

# Main loop
try:
    while True:
        publish_message()
        time.sleep(5)
except KeyboardInterrupt:
    print("Disconnecting...")
    myMQTTClient.disconnect()