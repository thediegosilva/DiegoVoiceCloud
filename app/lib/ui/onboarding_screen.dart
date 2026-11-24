import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../config/settings.dart';
import '../services/voice_session.dart';
import 'assistant_logo.dart';
import 'copyright_footer.dart';

/// Perguntas da primeira abertura: como a IA deve chamar o usuário e a data
/// de nascimento. Depois disso, o app abre direto na tela inicial.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.settings, required this.onDone});

  final AppSettings settings;
  final VoidCallback onDone;

  /// "dd/mm/aaaa" → data válida (entre 1900 e hoje) ou null.
  static DateTime? parseDate(String t) => _OnboardingScreenState._parse(t);

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final _name = TextEditingController(text: widget.settings.userName);
  late final _date = TextEditingController(text: _fmt(widget.settings.birthDate));
  String? _dateError;

  static String _fmt(DateTime? d) => d == null
      ? ''
      : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  static DateTime? _parse(String t) {
    final m = RegExp(r'^(\d{2})/(\d{2})/(\d{4})$').firstMatch(t.trim());
    if (m == null) return null;
    final d = int.parse(m[1]!), mo = int.parse(m[2]!), y = int.parse(m[3]!);
    final date = DateTime(y, mo, d);
    if (date.day != d || date.month != mo || date.year != y) return null; // ex.: 31/02
    if (y < 1900 || date.isAfter(DateTime.now())) return null;
    return date;
  }

  bool get _valid => _name.text.trim().isNotEmpty && OnboardingScreen.parseDate(_date.text) != null;

  @override
  void dispose() {
    _name.dispose();
    _date.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: OnboardingScreen.parseDate(_date.text) ?? DateTime(now.year - 25, 1, 1),
      firstDate: DateTime(1900),
      lastDate: now,
      initialDatePickerMode: DatePickerMode.year,
      helpText: 'Data de nascimento',
    );
    if (d != null) {
      setState(() {
        _date.text = _fmt(d);
        _dateError = null;
      });
    }
  }

  void _finish() {
    final d = OnboardingScreen.parseDate(_date.text);
    if (d == null) {
      setState(() => _dateError = 'Data inválida. Use dia/mês/ano, ex.: 15/08/1995');
      return;
    }
    final s = widget.settings;
    s.userName = _name.text.trim();
    s.birthDate = d;
    s.mode = ConnectionMode.gemini; // padrão: Modelo de IA
    s.onboardingDone = true;
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ai = widget.settings.assistantName;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: AssistantLogo(state: SessionState.listening, level: 0.1, size: 96)),
                  const SizedBox(height: 8),
                  Text('Olá! Eu sou $ai.',
                      textAlign: TextAlign.center, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text('Antes de começar, quero te conhecer um pouco.',
                      textAlign: TextAlign.center, style: text.bodyMedium?.copyWith(color: Colors.white70)),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _name,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    maxLength: 40,
                    decoration: const InputDecoration(
                      labelText: 'Como você quer que eu te chame?',
                      hintText: 'Seu nome ou apelido',
                      prefixIcon: Icon(Icons.person_rounded),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _date,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, _DateMask()],
                    decoration: InputDecoration(
                      labelText: 'Data de nascimento',
                      hintText: 'dd/mm/aaaa',
                      errorText: _dateError,
                      prefixIcon: const Icon(Icons.cake_rounded),
                      suffixIcon: IconButton(
                        tooltip: 'Escolher no calendário',
                        icon: const Icon(Icons.calendar_month_rounded),
                        onPressed: _pickDate,
                      ),
                    ),
                    onChanged: (_) => setState(() => _dateError = null),
                    onSubmitted: (_) => _valid ? _finish() : null,
                  ),
                  const SizedBox(height: 6),
                  Text('Uso isso para te chamar pelo nome e lembrar do seu aniversário. Fica só neste aparelho.',
                      style: text.bodySmall?.copyWith(color: Colors.white54)),
                  const SizedBox(height: 24),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                    onPressed: _valid ? _finish : null,
                    child: const Text('Começar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(height: 32),
                  const CopyrightFooter(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Coloca as barras sozinho: "15081995" → "15/08/1995".
class _DateMask extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final b = StringBuffer();
    for (var i = 0; i < digits.length && i < 8; i++) {
      if (i == 2 || i == 4) b.write('/');
      b.write(digits[i]);
    }
    final t = b.toString();
    return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }
}
