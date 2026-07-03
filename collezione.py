"""Download della collezione preconfezionata Normattiva.

Lo script scarica il file ZIP associato alla collezione "Codici" e gestisce
la ripresa del download nel caso in cui la connessione venga interrotta.
"""

from __future__ import annotations

import os
import time

import requests


URL = "https://api.normattiva.it/t/normattiva.api/bff-opendata/v1/api/v1/collections/download/collection-preconfezionata"
PARAMS = {
    "nome": "Codici",
    "formato": "AKN",
    "formatoRichiesta": "M",
}
HEADERS = {
    "Accept": "*/*",
    "Accept-Language": "it-IT,it;q=0.9",
    "Connection": "keep-alive",
    "Origin": "https://qas.dati.normattiva.it",
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    ),
}
FILE_NAME = "Codici_Multivigente.zip"
REQUEST_TIMEOUT_SECONDS = 20
RETRY_DELAY_SECONDS = 3
CHUNK_SIZE = 8192


def get_resume_offset(file_name: str) -> int:
    """Return the number of already downloaded bytes, if any."""

    if os.path.exists(file_name):
        return os.path.getsize(file_name)
    return 0


def build_headers(resume_offset: int) -> dict[str, str]:
    """Return request headers, including Range when the download is resumed."""

    headers = HEADERS.copy()
    if resume_offset > 0:
        headers["Range"] = f"bytes={resume_offset}-"
    return headers


def download_file() -> None:
    """Download the file, retrying automatically after temporary failures."""

    while True:
        resume_offset = get_resume_offset(FILE_NAME)
        headers = build_headers(resume_offset)

        if resume_offset > 0:
            print(f"Ripresa del download dal byte {resume_offset}...")

        try:
            with requests.get(
                URL,
                params=PARAMS,
                headers=headers,
                stream=True,
                timeout=REQUEST_TIMEOUT_SECONDS,
            ) as response:
                if response.status_code == 416:
                    print("Il file e gia stato scaricato integralmente.")
                    return

                response.raise_for_status()

                mode = "ab" if resume_offset > 0 else "wb"
                with open(FILE_NAME, mode) as file_handle:
                    for chunk in response.iter_content(chunk_size=CHUNK_SIZE):
                        if chunk:
                            file_handle.write(chunk)

            print("Il file e stato scaricato con successo.")
            return

        except requests.RequestException as exc:
            print(f"Connessione interrotta: {exc}. Nuovo tentativo tra {RETRY_DELAY_SECONDS} secondi...")
            time.sleep(RETRY_DELAY_SECONDS)


if __name__ == "__main__":
    download_file()
