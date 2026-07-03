"""Download and print the detail of a Normattiva legal act.

The script sends a POST request to the public Normattiva endpoint using the
URN of the act and prints a formatted preview of the JSON response.
"""

from __future__ import annotations

import json

import requests


ENDPOINT_URL = "https://api.normattiva.it/t/normattiva.api/bff-opendata/v1/api/v1/atto/dettaglio-atto-urn"
ACT_URN = "urn:nir:stato:regio.decreto:1942-03-16;262"
REQUEST_TIMEOUT_SECONDS = 30


def build_headers() -> dict[str, str]:
    """Return the headers required by the API gateway."""

    return {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Origin": "https://qas.dati.normattiva.it",
        "User-Agent": (
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        ),
    }


def fetch_act_details(urn: str) -> dict:
    """Fetch the act detail JSON for the given URN."""

    payload = {"urn": urn}
    response = requests.post(
        ENDPOINT_URL,
        json=payload,
        headers=build_headers(),
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    response.raise_for_status()

    try:
        return response.json()
    except ValueError as exc:
        raise ValueError("La risposta del server non contiene JSON valido.") from exc


def main() -> None:
    """Execute the request and print a readable preview of the result."""

    try:
        act_details = fetch_act_details(ACT_URN)
    except requests.RequestException as exc:
        print(f"Errore di connessione o risposta HTTP non valida: {exc}")
        return
    except ValueError as exc:
        print(f"Errore nel parsing della risposta: {exc}")
        return

    print(f"Acquisizione completata con successo per l'URN: {ACT_URN}\n")
    preview = json.dumps(act_details, indent=2, ensure_ascii=False)
    print(preview[:1000] + "\n... [continua]")


if __name__ == "__main__":
    main()
