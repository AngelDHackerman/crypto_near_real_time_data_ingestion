import os, json, hashlib, time, datetime, urllib.parse, urllib.request
from botocore.exceptions import ClientError
import boto3

s3 = boto3.client("s3")
secrets = boto3.client("secretsmanager")

RAW_BUCKET   = os.environ["RAW_BUCKET"]
BRONZE_PREFIX = os.environ["BRONZE_PREFIX"].rstrip("/")
SECRET_ARN   = os.environ["SECRET_ARN"]
TOP_LIST_ID  = [int(c.strip()) for c in os.environ.get("TOP_LIST_ID", "1").split(",")]

# (Opcional) prefijos separados para manifest y status para aislarlos totalmente del raw operativo
MANIFEST_PREFIX = os.environ.get("MANIFEST_PREFIX", f"{BRONZE_PREFIX}/manifests").rstrip("/")
STATUS_PREFIX   = os.environ.get("STATUS_PREFIX", f"{BRONZE_PREFIX}/status").rstrip("/")

# ---------- helpers de normalización ----------
NUMERIC_TOP_FLOAT = {
    # campos de nivel raíz que nos interesan como float
    "circulating_supply",
    "max_supply",
    "total_supply",
    "self_reported_circulating_supply",
    "self_reported_market_cap",
    "tvl_ratio",
}

# campos bajo quote.USD que deben ser float
NUMERIC_USD_FLOAT = {
    "price",
    "volume_24h",
    "volume_change_24h",
    "percent_change_1h",
    "percent_change_24h",
    "percent_change_7d",
    "percent_change_30d",
    "percent_change_60d",
    "percent_change_90d",
    "market_cap",
    "market_cap_dominance",
    "fully_diluted_market_cap",
    "tvl",
}

def _to_float(x):
    if x is None:
        return None
    # números y strings numéricas → float; lo demás, lo dejamos
    if isinstance(x, (int, float)):
        return float(x)
    if isinstance(x, str):
        try:
            return float(x)
        except Exception:
            return x
    return x

def _normalize_coin_types(coin_obj: dict) -> dict:
    # copia superficial
    c = dict(coin_obj) if isinstance(coin_obj, dict) else coin_obj

    # 1) raíz → forzar floats en métricos conocidos
    if isinstance(c, dict):
        for k in list(c.keys()):
            if k in NUMERIC_TOP_FLOAT:
                c[k] = _to_float(c.get(k))

    # 2) quote.USD → forzar floats en todas las métricas
    try:
        usd = c.get("quote", {}).get("USD", {})
        if isinstance(usd, dict):
            for k in list(usd.keys()):
                if k in NUMERIC_USD_FLOAT:
                    usd[k] = _to_float(usd.get(k))
        # re-asigna por si 'quote' venía como copy-on-write
        if "quote" in c and isinstance(c["quote"], dict):
            c["quote"]["USD"] = usd
    except Exception:
        # Si quote no existe o no es dict, ignoramos
        pass

    # Nota: no tocamos 'platform', 'tags', etc. BTC puede traer platform=None y USDC un objeto; eso está bien.
    return c

# ------------------------------------------------------

def _get_api_key():
    sec = secrets.get_secret_value(SecretId=SECRET_ARN)
    payload = sec.get("SecretString") or "{}"
    return json.loads(payload).get("API_KEY")

def _fetch_many_by_ids(ids, api_key, timeout_sec=15):
    ids_csv = ",".join(str(i) for i in ids)
    url = "https://pro-api.coinmarketcap.com/v2/cryptocurrency/quotes/latest"
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
    # particiones por id, año, mes, día, hora
    return f"{BRONZE_PREFIX}/id={coin_id}/year={y}/month={m}/day={d}/hour={h}/part-{ts_epoch}-{sha}.json"

def handler(event, context):
    api_key = _get_api_key()
    now = int(time.time())

    # 1) Llamada batched
    resp = _fetch_many_by_ids(TOP_LIST_ID, api_key)
    data_map = resp.get("data", {})  # {"1": {...}, "1027": {...}, ...}

    written, missing = [], []

    # 2) Escribir 1 objeto por ID (normalizado)
    for coin_id in TOP_LIST_ID:
        coin_key = str(coin_id)
        coin_obj = data_map.get(coin_key)

        if not coin_obj:
            missing.append(coin_id)
            print(f"[WARN] ID {coin_id} no vino en la respuesta CMC")
            continue

        # 🔧 Normaliza tipos para evitar unions en Glue
        coin_obj_norm = _normalize_coin_types(coin_obj)

        payload_bytes = json.dumps(
            coin_obj_norm,
            separators=(",", ":")   # minified (1 línea)
        ).encode("utf-8")

        key = _s3_key(coin_id, now, payload_bytes)

        # idempotencia simple
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
            Key=key,
            Body=payload_bytes,
            ContentType="application/json"
        )
        written.append(key)
        print(f"[INFO] wrote {key}")

    # 3) Manifest (en prefijo separado)
    dt = datetime.datetime.fromtimestamp(now, tz=datetime.timezone.utc)
    y, m, d, h = dt.year, f"{dt.month:02d}", f"{dt.day:02d}", f"{dt.hour:02d}"

    manifest_key = f"{MANIFEST_PREFIX}/year={y}/month={m}/day={d}/hour={h}/{now}-manifest.json"
    manifest = {
        "ts_epoch": now,
        "ids_requested": TOP_LIST_ID,
        "written": written,
        "missing": missing,
    }
    s3.put_object(
        Bucket=RAW_BUCKET,
        Key=manifest_key,
        Body=json.dumps(manifest, separators=(",", ":")).encode("utf-8"),
        ContentType="application/json",
    )

    # 4) Status (en prefijo separado)
    status = resp.get("status", {})
    status_key = f"{STATUS_PREFIX}/year={y}/month={m}/day={d}/hour={h}/{now}-status.json"
    s3.put_object(
        Bucket=RAW_BUCKET,
        Key=status_key,
        Body=json.dumps(status, separators=(",", ":")).encode("utf-8"),
        ContentType="application/json",
    )

    result = {"Written": written}
    if missing:
        result["MissingIDs"] = missing
    return result
