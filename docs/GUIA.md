# Guia completo — DiegoVoiceCloud

> Detalhes técnicos de cada recurso. Visão geral no [README](../README.md).

App Flutter (Android, iOS, Linux, Windows) com **dois modos**:

| Modo | Como funciona | Ferramentas |
|---|---|---|
| **LiveKit + PC** | App → `backend/token_server.py` (com senha) → sala LiveKit ← `backend/agent.py` | Tudo roda no PC do backend: arquivos, programas, volume, brilho, energia, casa (Voice Monkey), memória (Mem0). Câmera suportada. |
| **Modelo de IA direto** | App ↔ Gemini Live API (WebSocket), sem servidor | Pesquisa web, casa (Voice Monkey) e memória (Mem0) rodam no app. Controle do PC só no app **desktop** (Linux/Windows), com confirmação na tela para apagar/desligar. |

```
DiegoVoiceCloud/
├── app/        # App Flutter
│   └── lib/
│       ├── main.dart                  # tela inicial (escolha do modo)
│       ├── config/                    # settings + personalidade da IA
│       ├── services/
│       │   ├── livekit_session.dart   # modo LiveKit (substitui o Next.js)
│       │   ├── gemini_live_session.dart  # modo Modelo de IA direto
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
cp .env.example .env      # preencha com as suas chaves
./iniciar.sh              # Windows: iniciar.bat
```

Sobe dois processos: o agente (`agent.py dev`) e o servidor de token na porta 8787.

- **Senha obrigatória** (`ASSISTENTE_APP_PASSWORD`): o frontend antigo não tinha,
  então qualquer pessoa com a URL do ngrok podia falar com o agente e mexer no seu PC.
- **Ações destrutivas desligadas por padrão**: apagar arquivos e desligar ou reiniciar
  só funcionam com `ASSISTENTE_PERMITIR_DESTRUTIVO=1`. Os caminhos ficam sempre presos à sua pasta home.
- Para usar o app fora de casa: `ngrok http 8787` e coloque a URL do ngrok no app.

## 2. App Flutter

```bash
cd app
flutter pub get
flutter run -d linux        # ou: -d windows, ou com o celular conectado
```

No app, abra **Configurações** (ícone ⚙):
- **LiveKit:** URL do servidor de token (ex.: `http://192.168.0.10:8787`) e a senha.
- **Modelo de IA direto:** chave da API do Gemini (aistudio.google.com/apikey). Mem0 e
  Voice Monkey são opcionais.
- **Half-duplex:** ative no PC sem fone se a IA ficar ouvindo a própria voz.

### Pré-requisitos de build
- **Linux:** `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev`
  e, para o áudio, `pulseaudio-utils` (o `parecord` grava o microfone). Para as ferramentas
  de PC: `pactl`, `brightnessctl` e `zip` (opcionais).
- **Android:** Android SDK + `flutter doctor --android-licenses`.
- **Windows:** precisa compilar *no Windows* (Visual Studio com "Desktop development with C++").
- **iOS:** precisa compilar *num Mac* com Xcode.

## Primeira abertura

Na primeira vez que o app abre, ele pergunta **como você quer ser chamado** e a sua **data de
nascimento**. A data pode ser digitada (as barras entram sozinhas) ou escolhida no calendário.
A IA passa a chamar você pelo nome, sabe a sua idade e **dá parabéns no dia do seu
aniversário**. Esses dados ficam só no aparelho e podem ser mudados em Configurações → Geral.
O modo **Modelo de IA** já vem marcado por padrão.

## Histórico de conversas

Toque no **☰** da tela inicial para abrir a lateral com as conversas, como no ChatGPT.
- Elas ficam salvas **só no aparelho**, em arquivos na pasta privada do app. Nada vai para servidor.
- O título é automático (o começo da sua primeira fala) e dá para **renomear**.
- Dá para **fixar até 5** conversas no topo, **excluir uma por uma** ou **excluir tudo**.
- Ao abrir uma conversa, você pode ler e copiar as mensagens e tocar em **"Continuar conversa"**.
  A IA recebe o final da conversa e continua de onde parou. No modo LiveKit, o histórico só
  aparece na tela, e o agente do PC não recebe.
- Fotos não são guardadas no histórico: ficam como "📸 Foto".

## 3. Nome da IA e acordar pela voz

O nome da IA **muda com a voz** (Configurações → Assistente): com voz masculina ela se chama
**Diego**, e com voz feminina, **Lexy**. Os dois nomes podem ser trocados. É como ela se
apresenta e a palavra que a acorda. Na personalidade, `{NOME}` vira o nome atual. No modo
LiveKit, o app manda o nome e a voz para o backend.

| Aparelho | Como acordar |
|---|---|
| **Android** | Ligue **"Acordar ao ouvir o nome"**. O app baixa um modelo de voz offline (Vosk, 32 MB) e um serviço com notificação fixa fica escutando, **mesmo com a tela apagada**. Ao ouvir o nome, acende a tela e abre o modo assistente por cima da tela de bloqueio, com a logo pulsando enquanto ela fala. Fecha sozinho após uns segundos de silêncio, ou quando você diz "valeu, era só isso". Permita **"Aparecer sobre outros apps"** e **"Sem economia de bateria"** no próprio card. |
| **iPhone** | O iOS não deixa apps escutarem com a tela bloqueada (só a Siri). Diga **"E aí Siri, falar com Assistente"**. Para usar o nome da IA, crie um atalho no app **Atalhos** com a ação **"Chamar a IA"** e dê a ele o nome (ex.: Lexy). |
| **PC** | Use o botão "Iniciar chamada". |

**Precisão (medida com voz sintética e o modelo offline em pt-BR):**
- **Diego:** 24 de 24 chamadas reconhecidas e 2 alarmes falsos em 69 frases comuns, testando "diga", "Diogo", "Tiago chegou", "o dia é longo"… Os dois alarmes foram "o dia é longo" e "digo isso sempre".
- **Lexy:** a palavra não existe no vocabulário offline, mas o reconhecedor a ouve como "léxico", então essa variação já vem incluída. 24 de 24 chamadas reconhecidas, e o único alarme falso foi falar a própria palavra "léxico".

O truque é a gramática: além do nome, ela inclui ~400 palavras comuns do português
(`app/android/app/src/main/res/raw/wake_distractors.txt`). Só com o nome, o reconhecedor forçava quase tudo a virar o
nome. Se não estiver acordando, ligue **Sensibilidade alta** ou use **"Testar: diga o nome"**.
A escuta do nome usa o microfone do celular. Depois que ela acorda, a conversa vai pelo fone
Bluetooth, se ele estiver conectado.

## Áudio no Android (fone Bluetooth e com fio)

A conversa funciona como uma chamada de voz (`CallAudio.kt`):
- Prioridade: **fone Bluetooth → fone com fio/USB → alto-falante**. Com fone Bluetooth, **o
  microfone do fone também é usado**, então dá para falar longe do celular.
- Se o fone conectar ou desconectar no meio da conversa, o áudio troca sozinho.
- A voz da IA toca como áudio de chamada (`USAGE_VOICE_COMMUNICATION`): é esse som que o
  Android manda para o fone, e o cancelamento de eco usa ele como referência.
- A rota atual aparece ao lado do status da chamada (ícone de Bluetooth com o nome do fone).

Antes, o microfone era aberto com `speakerphone: true`, o que **forçava o alto-falante mesmo
com o fone conectado**. A voz também tocava como mídia, fora da rota de chamada.

## Câmera

- A miniatura e o painel ampliado mostram a **imagem ao vivo** da câmera. Antes, o painel
  ampliado mostrava as fotos enviadas para a IA (uma a cada 1,2 s), por isso parecia travado e
  atrasado.
- **📷 Tirar foto:** manda uma foto em boa resolução para a IA analisar. Funciona até com a
  câmera desligada: ela liga, tira a foto e desliga. A foto aparece na conversa.

## 4. Rede entre os seus aparelhos

Em **Configurações → Rede entre meus aparelhos**:
1. Ligue **"Conectar meus aparelhos"**, dê um nome a cada aparelho (PC, Android, iPhone)
   e toque em **"Gerar código novo"** em um deles.
2. Copie o código e cole nos outros aparelhos. Use **o mesmo código em todos**.
3. Teste com **"Procurar aparelhos"**.

Depois é só pedir: *"Fala pro Android pedir ao PC para abrir o Spotify"*, ou
*"Manda um recado pro PC: lembrar de comprar pão"*.

**Segurança:** as mensagens passam por um servidor MQTT público (`broker.emqx.io`, com
`broker.hivemq.com` como reserva, os dois com TLS), mas vão cifradas com **AES-256-GCM**,
usando uma chave derivada do seu código (PBKDF2). O servidor só vê bytes embaralhados num canal
de nome aleatório. Mensagens alteradas, de outro código, repetidas ou com mais de 10 minutos
são descartadas. Pedidos perigosos (terminal, apagar, desligar) sempre pedem confirmação na tela
do aparelho que vai executar. **Quem tiver o código manda nas suas IAs**: se perder um aparelho,
gere um código novo nos outros.

**Limites:** para receber pedidos, o app precisa estar aberto no PC e no iPhone. Receber com o
app fechado no iPhone exigiria notificações push da Apple, que precisam de conta paga de
desenvolvedor. No Android, funciona em segundo plano. As ferramentas da rede existem no modo
**Modelo de IA direto**. Tarefas recebidas rodam por texto, usando os "Modelos do agente" e as chaves
do Gemini do aparelho que recebe.
