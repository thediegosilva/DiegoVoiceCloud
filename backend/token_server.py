"""
Servidor de token para o app Flutter (substitui app/api/connection-details do Next.js).

- POST /token  (header: Authorization: Bearer <ASSISTENTE_APP_PASSWORD>)
  -> {"serverUrl", "roomName", "participantToken", "participantName"}

Diferente do frontend antigo, ele EXIGE senha: sem isso, quem achasse a URL
do ngrok conseguiria falar com o agente e mandar ele mexer no seu PC.
"""

import datetime
import hmac
import json
import os
import secrets

from aiohttp import web
from dotenv import load_dotenv
from livekit import api


def _env(nome: str, padrao: str = "") -> str:
    """Lê ASSISTENTE_<nome> (ou o nome antigo JARVIS_<nome>, por compatibilidade)."""
    return os.getenv(f"ASSISTENTE_{nome}") or os.getenv(f"JARVIS_{nome}", padrao)

load_dotenv()

LIVEKIT_URL = os.environ["LIVEKIT_URL"]
API_KEY = os.environ["LIVEKIT_API_KEY"]
API_SECRET = os.environ["LIVEKIT_API_SECRET"]
PASSWORD = _env("APP_PASSWORD", "")
PORT = int(os.getenv("TOKEN_SERVER_PORT", "8787"))

if len(PASSWORD) < 8:
    raise SystemExit("Defina ASSISTENTE_APP_PASSWORD no .env (mínimo 8 caracteres).")


def _autorizado(request: web.Request) -> bool:
    auth = request.headers.get("Authorization", "")
    token = auth.removeprefix("Bearer ").strip()
    return hmac.compare_digest(token.encode(), PASSWORD.encode())


async def token(request: web.Request) -> web.Response:
    if not _autorizado(request):
        return web.json_response({"error": "nao autorizado"}, status=401)

    try:
        body = await request.json()
    except (json.JSONDecodeError, ValueError):
        body = {}
    nome = str(body.get("identity") or "user")[:64]
    # Nome da IA e voz escolhidos no app (o nome muda com a voz).
    meta = json.dumps(
        {
            "assistantName": str(body.get("assistantName") or "")[:40],
            "voice": str(body.get("voice") or "")[:40],
            "userContext": str(body.get("userContext") or "")[:600],
        }
    )

    room_name = f"assistente_sala_{secrets.token_hex(4)}"
    identity = f"assistente_user_{secrets.token_hex(4)}"
    jwt = (
        api.AccessToken(API_KEY, API_SECRET)
        .with_identity(identity)
        .with_name(nome)
        .with_metadata(meta)
        .with_ttl(datetime.timedelta(minutes=15))
        .with_grants(
            api.VideoGrants(
                room_join=True,
                room=room_name,
                can_publish=True,
                can_publish_data=True,
                can_subscribe=True,
            )
        )
        .to_jwt()
    )
    return web.json_response(
        {
            "serverUrl": LIVEKIT_URL,
            "roomName": room_name,
            "participantToken": jwt,
            "participantName": nome,
        },
        headers={"Cache-Control": "no-store"},
    )


async def health(_: web.Request) -> web.Response:
    return web.json_response({"ok": True})


app = web.Application()
app.router.add_post("/token", token)
app.router.add_get("/health", health)

if __name__ == "__main__":
    print(f"Token server em http://0.0.0.0:{PORT}  (POST /token)")
    web.run_app(app, host="0.0.0.0", port=PORT)
