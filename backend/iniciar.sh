#!/bin/bash
# Sobe o agente Jarvis + o servidor de token (Linux).
cd "$(dirname "$0")"
[ -d venv ] || { echo "Crie o venv: python3 -m venv venv && venv/bin/pip install -r requirements.txt"; exit 1; }
[ -f .env ] || { echo "Copie .env.example para .env e preencha."; exit 1; }
source venv/bin/activate
python token_server.py &
TOKEN_PID=$!
trap "kill $TOKEN_PID 2>/dev/null" EXIT
python agent.py dev
