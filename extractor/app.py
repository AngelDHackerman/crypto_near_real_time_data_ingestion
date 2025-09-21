import os, json,hashlib, time, datetime, urllib.request
import boto3

s3 = boto3.client("s3")
secrets = boto3.client("secretsmanager")

RAW_BUCKET = os.environ["RAW_BUCKET"]
BRONZE_PREFIX = os.environ["BRONZE_PREFIX"]
SECRET_ARN  = os.environ["SECRET_ARN"]
TOP_LIST_ID = [c.strip() for c in os.environ.get("TOP_LIST_ID", "1").split(",")]

def _get_api_key():
    sec = secrets.get_secret_value(SecretId=SECRET_ARN)
    payload = sec.get("SecretString") or "{}"
    return json.loads(payload).get("API_KEY")

def _fetch_coin(coin_id, api_key):
    # Example: CoinMarketCap /v2/cryptocurrency/quotes/latest?id=1
    url = f"https://pro-api.coinmarketcap.com/v2/cryptocurrency/quotes/latest?id={coin_id}"
    req = urllib.request.Request(url, headers={"X-CMC_PRO_API_KEY": api_key, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read()
    return json.loads(body.decode("utf-8"))

def _s3_key(coin, ts_epoch, payload_bytes):
    dt = datetime.datetime.fromtimestamp(ts_epoch, tz=datetime.timezone.utc)
    y, m, d, h = dt.year, f"{dt.month:02d}", f"{dt.day:02d}", f"{dt.hour:02d}"
    sha = hashlib.sha1(payload_bytes).hexdigest()
    return f"{BRONZE_PREFIX}/coin={coin}/year={y}/month={m}/day={d}/hour{h}/part-{ts_epoch}-{sha}.json"
        
def handler(event, context):
    api_key = _get_api_key()
    now = int(time.time())
    written = []
    for coin in TOP_LIST_ID:
        data = _fetch_coin(coin, api_key)
        payload_bytes = json.dumps(data, separators=(",",":")).encode("utf-8")
        key = _s3_key(coin, now, payload_bytes)
        # Simple idempotence: if the object exists, do not rewrite
        try:
            s3.head_object(Bucket=RAW_BUCKET, Key=key)
            exists = True
        except s3.exceptions.ClientError:
            exists = False
        if not exists:
            s3.put_object(Bucket=RAW_BUCKET, Key=key, Body=payload_bytes)
            written.append(key)
    return {"Written": written}
        