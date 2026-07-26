# Whisper Transkriptions-Server

Eigener REST-API-Server für Schweizerdeutsch → Hochdeutsch Transkription.  
Basiert auf [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (CPU/GPU).

## Starten

```bash
cd deployment/whisper
docker compose up -d --build
```

Beim ersten Start lädt Docker das Whisper-Modell herunter (~3 GB für large-v3). Dies kann einige Minuten dauern. Fortschritt im Log: `docker compose logs -f`.

## API

| Endpoint | Beschreibung |
|----------|-------------|
| `GET  http://localhost:9000/health` | Status & Modell-Info |
| `POST http://localhost:9000/transcribe` | Audio-Datei hochladen, Text zurück |

### Beispiel (cURL)

```bash
curl -X POST http://localhost:9000/transcribe \
  -F "audio=@sitzung.webm" \
  | python3 -m json.tool
```

## Konfiguration (`docker-compose.yml`)

| Variable | Standard | Beschreibung |
|----------|----------|-------------|
| `WHISPER_MODEL` | `large-v3` | Modellgrösse (tiny/base/small/medium/large-v2/large-v3) |
| `WHISPER_DEVICE` | `cpu` | `cpu` oder `cuda` (NVIDIA GPU) |
| `WHISPER_COMPUTE_TYPE` | `int8` | CPU: `int8`; GPU: `float16` |

### Für schwächere Server

```yaml
WHISPER_MODEL: "medium"        # ~1.5 GB, gute Qualität
WHISPER_COMPUTE_TYPE: "int8"
```

### GPU aktivieren (NVIDIA)

1. `nvidia-container-toolkit` auf dem Host installieren
2. In `docker-compose.yml`:
   - `WHISPER_DEVICE: "cuda"` und `WHISPER_COMPUTE_TYPE: "float16"` setzen
   - `deploy`-Block auskommentieren

## Performance (CPU, Intel i7)

| Modell | RAM | Geschwindigkeit |
|--------|-----|----------------|
| small | ~500 MB | ~0.5× Echtzeit |
| medium | ~1.5 GB | ~0.2× Echtzeit |
| large-v3 | ~3 GB | ~0.08× Echtzeit |

*(1h Aufnahme ≈ 12 min Wartezeit mit large-v3 auf normaler CPU)*

## Verzeichnisstruktur

```
deployment/whisper/
├── Dockerfile          # Python + faster-whisper + ffmpeg
├── docker-compose.yml  # Konfiguration
├── server.py           # FastAPI-Server
├── requirements.txt    # Python-Abhängigkeiten
├── models/             # Modell-Cache (automatisch befüllt)
└── outputs/            # Ausgabe-Verzeichnis (optional)
```
