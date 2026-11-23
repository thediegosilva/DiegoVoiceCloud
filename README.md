# DiegoVoiceCloud — Jarvis em Flutter

Porta do projeto `jvs_auth_92kx` (Python + Next.js) para um app Flutter
(Android, iOS, Linux, Windows) com **dois modos**:

| Modo | Como funciona | Ferramentas |
|---|---|---|
| **LiveKit + PC** | App → `backend/token_server.py` (com senha) → sala LiveKit ← `backend/agent.py` | Tudo roda no PC do backend: arquivos, programas, volume, brilho, energia, casa (Voice Monkey), memória (Mem0). Câmera suportada. |
| **Gemini direto** | App ↔ Gemini Live API (WebSocket), sem servidor | Pesquisa web, casa (Voice Monkey) e memória (Mem0) rodam no app. Controle do PC só no app **desktop** (Linux/Windows), com confirmação na tela para apagar/desligar. |

```
DIEGOVOICECLOUD/
├── app/        # App Flutter
│   └── lib/
│       ├── main.dart                  # tela inicial (escolha do modo)
│       ├── config/                    # settings + prompt do Jarvis
│       ├── services/
│       │   ├── livekit_session.dart   # modo LiveKit (substitui o Next.js)
│       │   ├── gemini_live_session.dart  # modo Gemini direto
│       │   ├── tool_registry.dart     # ferramentas do modo Gemini
│       │   ├── pc_control.dart        # automação do PC (Linux/Windows)
│       │   ├── mem0_service.dart      # memória
│       │   └── voicemonkey_service.dart  # casa inteligente
│       └── ui/                        # orbe, tela de conversa, configurações
└── backend/    # Agente Python unificado + servidor de token
```

## 1. Backend (modo LiveKit)

```bash
cd backend
python3 -m venv venv
venv/bin/pip install -r requirements.txt
cp .env.example .env      # preencha (pode copiar as chaves do .env antigo)
./iniciar.sh              # Windows: iniciar.bat
```

Sobe dois processos: o agente (`agent.py dev`) e o servidor de token na porta 8787.

- **Senha obrigatória** (`JARVIS_APP_PASSWORD`): o frontend antigo não tinha,
  então qualquer pessoa com a URL do ngrok podia falar com o agente e mexer no seu PC.
- **Ações destrutivas desligadas por padrão**: apagar arquivos e desligar ou reiniciar
  só funcionam com `JARVIS_PERMITIR_DESTRUTIVO=1`. Os caminhos ficam sempre presos à sua pasta home.
- Para usar o app fora de casa: `ngrok http 8787` e coloque a URL do ngrok no app.

## 2. App Flutter

```bash
cd app
flutter pub get
flutter run -d linux        # ou: -d windows, ou com o celular conectado
```

No app, abra **Configurações** (ícone ⚙):
- **LiveKit:** URL do servidor de token (ex.: `http://192.168.0.10:8787`) e a senha.
- **Gemini direto:** chave da API do Gemini (aistudio.google.com/apikey). Mem0 e
  Voice Monkey são opcionais.
- **Half-duplex:** ative no PC sem fone se o Jarvis ficar ouvindo a própria voz.

### Pré-requisitos de build
- **Linux:** `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev`
  e, para o áudio, `pulseaudio-utils` (o `parecord` grava o microfone). Para as ferramentas
  de PC: `pactl`, `brightnessctl` e `zip` (opcionais).
- **Android:** Android SDK + `flutter doctor --android-licenses`.
- **Windows:** precisa compilar *no Windows* (Visual Studio com "Desktop development with C++").
- **iOS:** precisa compilar *num Mac* com Xcode.

## O que mudou em relação ao projeto original
- Next.js → app Flutter nativo (multiplataforma).
- 4 agentes separados (Aula 01, Mem0, Controle_PC, Controle_HOME) → 1 agente com tudo.
- Automação do PC: só Windows → Linux + Windows.
- Arquivos que faltavam no original (`prompts.py` no Mem0, `automacao_jarvis.py` no HOME) resolvidos.
- `abrir_programa` com `shell=True` (executava qualquer comando) → removido; ficou o `abrir_aplicativo`.
- Chrome CDP / pausar YouTube com pyautogui → removidos (eram específicos do Windows e frágeis).
