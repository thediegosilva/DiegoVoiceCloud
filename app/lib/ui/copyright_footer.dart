import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Rodapé da tela de abertura: direitos reservados ao autor + link do site.
/// Tocar no site pergunta antes de abrir o navegador.
class CopyrightFooter extends StatelessWidget {
  const CopyrightFooter({super.key});

  static const author = 'Diego Silva';
  static const siteLabel = 'thediegosilva.github.io';
  static final siteUrl = Uri.parse('https://thediegosilva.github.io/');

  Future<void> _openSite(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.language_rounded),
        title: const Text('Ir para o site?'),
        content: const Text('Você quer abrir o site de $author ($siteLabel) no navegador?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Agora não')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Abrir site')),
        ],
      ),
    );
    if (go != true) return;
    final ok = await launchUrl(siteUrl, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não consegui abrir o navegador.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white54);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('© ${DateTime.now().year} $author. Todos os direitos reservados.',
            textAlign: TextAlign.center, style: style),
        const SizedBox(height: 2),
        TextButton.icon(
          onPressed: () => _openSite(context),
          icon: const Icon(Icons.language_rounded, size: 16),
          label: const Text(siteLabel, style: TextStyle(decoration: TextDecoration.underline)),
        ),
      ],
    );
  }
}
