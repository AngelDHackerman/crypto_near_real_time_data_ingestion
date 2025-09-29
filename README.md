EventBridge + Lambda + S3 + Athena + IAM + CloudWatch & Terraform

This is a **datalake medallion architecture**

las particiones son por hora de ingesta, no por hora de origen


[crypto price endpoint](https://pro-api.coinmarketcap.com/v2/cryptocurrency/quotes/latest)


Name            ID
Bitcoin         1
Etherium        1027 
XRP             52
Tether          825
BNB             1839
Solana          5426
USDC            3408
Dogecoin        74
Cardano         2010
Tron            1958
BAT             1697


Usar estructura Bronze: texto crudo, Silver: texto limpio y procesado & Gold: informacion valiosa para el ML 

* lambda para bronze 
* glue job para el transformer (silver)
* glue job para feature basicos (retornos, vol, momentum) (gold)
* glue crawler: actualizar Data Catalog 3 tablas: bronze_top10, silver_top10, gold_top10_features
* Athena/SageMaker consumen informacion. 

1. idempotencia & deduplicacion:
    * Usa en S3 claves únicas con timestamp del proveedor: bronze/yyyymmdd/hh/mm=MM/cmc_ts=2025-09-18T02:50:00Z.json
    * Antes de escribir a silver/gold, dedup por (asset_id, last_updated).
2. esquema y particionado: 
    * Particiona por fecha/hora y symbol: silver/dt=YYYY-MM-DD/hour=HH/symbol=BTC/part-*.parquet
    * Clave primaria “lógica”: (asset_id, as_of_ts, currency='USD').