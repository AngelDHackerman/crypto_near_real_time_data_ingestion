import os, json,hashlib, time, datetime, urllib.parse, urllib.request
from botocore.exceptions import ClientError
import boto3

s3 = boto3.client("s3")
secrets = boto3.client("secretsmanager")

RAW_BUCKET = os.environ["RAW_BUCKET"]
BRONZE_PREFIX = os.environ["BRONZE_PREFIX"].rstrip("/")
SECRET_ARN  = os.environ["SECRET_ARN"]
TOP_LIST_ID = [int(c.strip()) for c in os.environ.get("TOP_LIST_ID", "1").split(",")]

def _get_api_key():
    sec = secrets.get_secret_value(SecretId=SECRET_ARN)
    payload = sec.get("SecretString") or "{}"
    return json.loads(payload).get("API_KEY")

def _fetch_many_by_ids(ids, api_key, timeout_sec=15):
    # CMC accepts IDs splitted by comma in one request
    # Example: CoinMarketCap /v2/cryptocurrency/quotes/latest?id=1,2,3,4
    ids_csv = ",".join(str(i) for i in ids)
    url = f"https://pro-api.coinmarketcap.com/v2/cryptocurrency/quotes/latest"
    qs = urllib.parse.urlencode({"id": ids_csv})
    req = urllib.request.Request(
        f"{url}?{qs}",
        headers={
            "X-CMC_PRO_API_KEY": api_key, 
            "Accept": "application/json",
            "User-Agent": "near-real-time-crypto-ingestor/1.0"
        }
    )
    with urllib.request.urlopen(req, timeout=timeout_sec) as r:
        body = r.read()
    return json.loads(body.decode("utf-8"))

def _s3_key(coin_id, ts_epoch, payload_bytes):
    dt = datetime.datetime.fromtimestamp(ts_epoch, tz=datetime.timezone.utc)
    y, m, d, h = dt.year, f"{dt.month:02d}", f"{dt.day:02d}", f"{dt.hour:02d}"
    sha = hashlib.sha1(payload_bytes).hexdigest()
    # Partitions by id, year, month, day, hour
    # partition ID is first just for better visualization, this is just a "landing" bucket partition
    return f"{BRONZE_PREFIX}/id={coin_id}/year={y}/month={m}/day={d}/hour={h}/part-{ts_epoch}-{sha}.json"
        
def handler(event, context):
    api_key = _get_api_key()
    now = int(time.time())
    
    # 1) Call lambda batch
    resp = _fetch_many_by_ids(TOP_LIST_ID, api_key)
    data_map = resp.get("data", {}) # {"1": {...}, "1027": {...}, ...}
    
    written = []
    missing = []
    
    # 2) Write an object by each ID 
    for coin_id in TOP_LIST_ID:
        coin_key = str(coin_id)
        coin_obj = data_map.get(coin_key)
        
        if not coin_obj:
            missing.append(coin_id)
            print(f"[WARN] ID {coin_id} no vino en la respuesta CMC")
            continue
        
        payload_bytes = json.dumps(coin_obj, separators=(",", ":")).encode("utf-8")
        key = _s3_key(coin_id, now, payload_bytes)
        
        # Idempotence: avoid duplicates
        try:
            s3.head_object(Bucket=RAW_BUCKET, Key=key)
            print(f"[INFO] skip exists {key}")
            continue
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code")
            if code not in ("404", "NotFound", "NoSuchKey"):
                raise
            
        s3.put_object(
            Bucket=RAW_BUCKET,
            Key = key,
            Body=payload_bytes,
            ContentType ="application/json"
        )
        written.append(key)
        print(f"[INFO] wrote {key}")
        
    # 3) Manifest: records what IDs were saved
    dt = datetime.datetime.fromtimestamp(now, tz=datetime.timezone.utc)
    y, m, d, h = dt.year, f"{dt.month:02d}", f"{dt.day:02d}", f"{dt.hour:02d}"
    
    manifest_key=f"{BRONZE_PREFIX}/manifests/year={y}/month={m}/day={d}/hour={h}/{now}-manifest.json"
    manifest = {
        "ts_epoch": now,
        "ids_requested": TOP_LIST_ID,
        "written": written,
        "missing": missing,
    }
    s3.put_object(
        Bucket=RAW_BUCKET,
        Key=manifest_key,
        Body=json.dumps(manifest, separators=(",",":")).encode("utf-8"),
        ContentType="application/json",
    )
    
    # 4) Status object. Diagnost of API rates, errors and timestamp from CMC
    status = resp.get("status", {})
    s3.put_object(
        Bucket=RAW_BUCKET,
        Key=f"{BRONZE_PREFIX}/status/year={y}/month={m}/day={d}/hour={h}/{now}-status.json",
        Body=json.dumps(status, separators=(",",":")).encode("utf-8"),
        ContentType="application/json",
    )
        
    result = {"Written": written}
    if missing:
        result["MissingIDs"] = missing
    return result