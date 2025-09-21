import os, json,hashlib, time, datetime, urllib.request
import boto3

s3 = boto3.client("s3")
secrets = boto3.client("secretsmanager")

RAW_BUCKET = os.environ["RAW_BUCKET"]
BRONZE_PREFIX = os.environ["BRONZE_PREFIX"]
SECRET_ARN  = os.environ["SECRET_ARN"]
TOP_LIST = [c.strip() for c in os.environ.get("TOP_LIST", "BTC,ETH").split(",")]

def _get_api_key():
    sec = secrets.get_secret_value(SecretId=SECRET_ARN)
    payload = sec.get("SecretString") or "{}"
    return json.loads(payload).get("API_KEY")