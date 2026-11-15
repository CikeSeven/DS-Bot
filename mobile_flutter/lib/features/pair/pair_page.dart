// Pairing: scan the QR code the computer shows (Settings → Phone), paste its
// link, or open a dsbot://pair link. The code goes inside the encrypted
// handshake; the Relay Server never sees it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/app_state.dart';
import '../../link/link.dart';
import '../../ui/glass.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class PairPage extends StatefulWidget {
  const PairPage({super.key, this.initialLink, this.canCancel = false});

  final String? initialLink;
  final bool canCancel;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final _link = TextEditingController();
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  PairingOffer? _offer;
  bool _busy = false;
  String? _error;
  bool _camera = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialLink;
    if (initial != null && initial.isNotEmpty) {
      _link.text = initial;
      scheduleMicrotask(() => _pair(initial));
    }
  }

  @override
  void dispose() {
    _link.dispose();
    unawaited(_scanner.dispose());
    super.dispose();
  }

  Future<void> _pair(String text) async {
    if (_busy) return;
    final link = text.trim();
    PairingOffer offer;
    try {
      offer = parsePairingUri(link);
    } on FormatException catch (error) {
      setState(() => _error = t(error.message));
      return;
    }
    setState(() {
      _offer = offer;
      _busy = true;
      _error = null;
    });
    HapticFeedback.mediumImpact();
    try {
      await AppScope.read(context).pair(link);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorText(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return GlassPage(
      bar: GlassBar(
        title: Text(t('Pair with your computer')),
        leading: widget.canCancel ? IconBtn(AppIcon.close, onTap: () => AppScope.read(context).cancelPairing()) : null,
      ),
      bodyBuilder: (context) => ListView(
        padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 12, 20, 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          Text(
            t('On the computer, open DS Bot Settings → Phone and show the QR code. Then scan it here.'),
            style: TypeScale.rowPreview.copyWith(color: p.ink2),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Center(child: _scanBox(p)),
          const SizedBox(height: 24),
          if (_offer != null) _offerCard(p, _offer!),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: Palette.danger)),
            ),
          const SizedBox(height: 24),
          Text(t('Or paste the pairing link'), style: TypeScale.smallStrong.copyWith(color: p.ink2)),
          const SizedBox(height: 8),
          Field(controller: _link, hint: 'dsbot://pair?…', mono: true, onSubmitted: _pair, textInputAction: TextInputAction.go),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: Btn(t('Paste'), kind: BtnKind.secondary, icon: AppIcon.copy, onTap: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) {
                  _link.text = data!.text!;
                  await _pair(data.text!);
                }
              }),
            ),
            const SizedBox(width: 12),
            Expanded(child: Btn(t('Pair'), busy: _busy, onTap: () => _pair(_link.text))),
          ]),
        ],
      ),
    );
  }

  Widget _scanBox(Palette p) {
    final size = MediaQuery.sizeOf(context).width.clamp(200.0, 300.0) - 20;
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: Container(
        width: size,
        height: size,
        color: p.bubble,
        child: _camera
            ? Stack(fit: StackFit.expand, children: [
                MobileScanner(
                  controller: _scanner,
                  onDetect: (capture) {
                    final value = capture.barcodes.firstOrNull?.rawValue;
                    if (value != null && value.startsWith('dsbot://pair')) unawaited(_pair(value));
                  },
                  errorBuilder: (context, error) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(t('The camera is not available. Paste the link instead.'), textAlign: TextAlign.center, style: TypeScale.small.copyWith(color: p.ink2)),
                    ),
                  ),
                ),
                IgnorePointer(child: CustomPaint(painter: _FramePainter(p.accent))),
              ])
            : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Ico(AppIcon.qr, size: 56, color: p.ink3),
                const SizedBox(height: 16),
                Btn(t('Use the camera'), icon: AppIcon.camera, onTap: () => setState(() => _camera = true)),
              ]),
      ),
    );
  }

  Widget _offerCard(Palette p, PairingOffer offer) {
    final fingerprint = identityFingerprint(offer.hostKey);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.dialog), border: Border.all(color: p.line)),
      child: Row(children: [
        RowIcon(AppIcon.monitor),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(offer.name.isEmpty ? t('Computer') : offer.name, style: TypeScale.rowNameStrong.copyWith(color: p.ink)),
            const SizedBox(height: 2),
            Text('${t('Fingerprint')} ${fingerprint.substring(0, 4)} ${fingerprint.substring(4, 8)} ${fingerprint.substring(8)}',
                style: TypeScale.mono.copyWith(color: p.ink2)),
            Text(t('Check that this matches the code on the computer'), style: TypeScale.caption.copyWith(color: p.ink3)),
          ]),
        ),
        if (_busy) SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: p.accent)),
      ]),
    );
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const inset = 28.0;
    const arm = 28.0;
    final r = Rect.fromLTRB(inset, inset, size.width - inset, size.height - inset);
    for (final (corner, dx, dy) in [(r.topLeft, 1.0, 1.0), (r.topRight, -1.0, 1.0), (r.bottomLeft, 1.0, -1.0), (r.bottomRight, -1.0, -1.0)]) {
      canvas.drawLine(corner, corner + Offset(arm * dx, 0), paint);
      canvas.drawLine(corner, corner + Offset(0, arm * dy), paint);
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.color != color;
}
