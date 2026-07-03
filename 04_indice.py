import json
import os

import requests
import urllib3
from requests.auth import HTTPBasicAuth


urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


INDEX_NAME = "tkg_versions"
BASE_URL = os.getenv("ES_URL", "https://localhost:9200")
USERNAME = os.getenv("ES_USERNAME", "admin")
PASSWORD = os.getenv("ES_PASSWORD")


def build_index_payload() -> dict:
  return {
    "settings": {
      "index": {
        "number_of_shards": 3,
        "number_of_replicas": 1,
      },
      "analysis": {
        "analyzer": {
          "it_text": {
            "type": "custom",
            "tokenizer": "standard",
            "filter": ["lowercase", "italian_elision", "italian_stop", "italian_stemmer"],
          }
        },
        "filter": {
          "italian_elision": {
            "type": "elision",
            "articles": ["c", "l", "all", "dell", "d", "gli", "i", "da", "in", "su", "del", "dei", "delle"],
          },
          "italian_stop": {"type": "stop", "stopwords": "_italian_"},
          "italian_stemmer": {"type": "stemmer", "language": "light_italian"},
        },
      },
    },
    "mappings": {
      "properties": {
        "id": {"type": "keyword"},
        "artId": {"type": "keyword"},
        "versionId": {"type": "keyword"},
        "title": {"type": "text", "analyzer": "it_text"},
        "text": {"type": "text", "analyzer": "it_text"},
        "aliases": {"type": "text", "analyzer": "it_text"},
        "keywords": {"type": "keyword"},
        "valid_from": {"type": "date", "format": "strict_date_optional_time||epoch_millis"},
        "valid_to": {"type": "date", "format": "strict_date_optional_time||epoch_millis"},
        "year_from": {"type": "integer"},
        "year_to": {"type": "integer"},
        "embedding": {"type": "dense_vector", "dims": 384, "index": True, "similarity": "cosine"},
      }
    },
  }


def create_index() -> None:
  if not PASSWORD:
    raise RuntimeError("ES_PASSWORD non impostata. Esporta la password prima di eseguire lo script.")

  response = requests.put(
    f"{BASE_URL}/{INDEX_NAME}",
    json=build_index_payload(),
    auth=HTTPBasicAuth(USERNAME, PASSWORD),
    verify=False,
    timeout=30,
  )

  try:
    response.raise_for_status()
  except requests.HTTPError as error:
    raise RuntimeError(f"Creazione indice fallita: {response.status_code} {response.text}") from error

  try:
    result = response.json()
  except json.JSONDecodeError:
    result = response.text

  print(f"Indice creato correttamente: {INDEX_NAME}")
  print(f"Stato HTTP: {response.status_code}")
  print(f"Risposta: {result}")


if __name__ == "__main__":
  create_index()