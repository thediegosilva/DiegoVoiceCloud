@echo off
REM Sobe o agente do assistente + o servidor de token (Windows).
cd /d "%~dp0"
if not exist "venv\Scripts\activate.bat" (
  echo Crie o venv: python -m venv venv ^&^& venv\Scripts\pip install -r requirements.txt
  pause
  exit /b
)
if not exist ".env" (
  echo Copie .env.example para .env e preencha.
  pause
  exit /b
)
call venv\Scripts\activate
start "Assistente Token Server" /min python token_server.py
python agent.py dev
pause
