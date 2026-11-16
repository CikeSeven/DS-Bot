// Pairing: scan the QR code the computer shows (Settings → Phone), paste its
// link, or open a dsbot://pair link. The code goes inside the encrypted
// handshake; the Relay Server never sees it. The page sits on the onboarding
// sky; its card walks through camera, handshake and the connected check, and
// the computer is saved only once that check has played.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/app_state.dart';
import '../../link/rust_link.dart';
import '../../ui/liquid_glass.dart';
import '../../ui/glass_button.dart';
import '../../ui/i18n.dart';
import '../../ui/icons.dart';
import '../../ui/motion.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'pair_help.dart';
import 'scanner_card.dart';

class PairPage extends StatefulWidget {
  const PairPage({super.key, this.initialLink, this.canCancel = false, this.onBack});

  final String? initialLink;

  /// Opened over a paired computer (Computers → Add): a close button goes back.
  final bool canCancel;

  /// On a fresh install, back to the welcome page.
  final VoidCallback? onBack;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> with SingleTickerProviderStateMixin {
  late final _entrance = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
  // The glass parts fade themselves in (see LiquidGlass.appear), briefly and
  // one after the other: a pane that is part way in costs the engine an extra
  // pass over the backdrop.
  late final _cardIn = appearing(_entrance, 0.14, 0.3);
  late final _actionsIn = appearing(_entrance, 0.42, 0.56);
  final _link = TextEditingController();
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  ScanStage _stage = ScanStage.idle;
  ScanStage _resume = ScanStage.idle;
  PairingOffer? _offer;
  String? _error;
  String _connected = '';
  bool _busy = false;
  bool _locked = false;
  bool _manual = false;
  int _shakes = 0;

  @override
  void initState() {
    super.initState();
    _take(widget.initialLink);
  }

  // A link opened while this page already shows (the launch link arrives after
  // the first frame) comes as a new initialLink, not a new page.
  @override
  void didUpdateWidget(PairPage old) {
    super.didUpdateWidget(old);
    if (widget.initialLink != old.initialLink) _take(widget.initialLink);
  }

  void _take(String? link) {
    if (link == null || link.isEmpty) return;
    _link.text = link;
    scheduleMicrotask(() => _pair(link));
  }

  @override
  void dispose() {
    _entrance.dispose();
    _link.dispose();
    unawaited(_scanner.dispose());
    super.dispose();
  }

  void _openCamera() {
    if (_busy) return;
    HapticFeedback.selectionClick();
    setState(() {
      _stage = ScanStage.camera;
      _error = null;
    });
  }

  void _closeCamera() => setState(() {
    _stage = ScanStage.idle;
    _locked = false;
  });

  /// The system back: undo the innermost step first, and leave the app only
  /// when there is nowhere to go back to.
  void _back() {
    if (_stage == ScanStage.camera) {
      _closeCamera();
    } else if (_manual) {
      FocusScope.of(context).unfocus();
      setState(() => _manual = false);
    } else if (_busy) {
      // A pairing in flight finishes or fails on its own.
    } else if (widget.canCancel) {
      AppScope.read(context).cancelPairing();
    } else if (widget.onBack != null) {
      widget.onBack!();
    } else {
      unawaited(SystemNavigator.pop());
    }
  }

  Future<void> _detected(String value) async {
    if (_busy || _locked) return;
    HapticFeedback.selectionClick();
    setState(() => _locked = true);
    // Let the frame close in on the code before the card moves on.
    await Future<void>.delayed(const Duration(milliseconds: 320));
    if (mounted) await _pair(value);
  }

  Future<void> _pair(String text) async {
    if (_busy) return;
    final link = text.trim();
    PairingOffer offer;
    try {
      offer = parsePairingUri(link);
    } on FormatException catch (error) {
      _fail(t(error.message));
      return;
    }
    final app = AppScope.read(context);
    final reduce = reduceMotion(context);
    FocusScope.of(context).unfocus();
    setState(() {
      _resume = _stage == ScanStage.camera ? ScanStage.camera : ScanStage.idle;
      _offer = offer;
      _busy = true;
      _error = null;
      _stage = ScanStage.connecting;
    });
    unawaited(_scanner.stop());
    final started = DateTime.now();
    final PairedComputer paired;
    try {
      paired = await app.connect(link);
    } on Object catch (error) {
      if (mounted) _fail(errorText(error));
      return;
    }
    // The handshake reads as a moment even when the computer answers at once.
    final rest = const Duration(milliseconds: 900) - DateTime.now().difference(started);
    if (rest > Duration.zero && !reduce) await Future<void>.delayed(rest);
    if (!mounted) return;
    setState(() {
      _stage = ScanStage.success;
      _connected = paired.name.isEmpty ? t('Computer') : paired.name;
    });
    HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    HapticFeedback.mediumImpact();
    await Future<void>.delayed(Duration(milliseconds: reduce ? 500 : 1250));
    if (!mounted) return;
    await app.adopt(paired);
  }

  void _fail(String message) {
    HapticFeedback.heavyImpact();
    setState(() {
      _busy = false;
      _locked = false;
      _error = message;
      _shakes++;
      if (_stage == ScanStage.connecting) _stage = _resume;
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    final at = text.indexOf('dsbot://pair');
    if (at < 0) {
      _fail(t('The clipboard has no pairing link'));
      return;
    }
    final link = text.substring(at).split(RegExp(r'\s')).first;
    _link.text = link;
    await _pair(link);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom > 0;
    final page = Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final full = math.min(math.min(box.maxWidth - 56, 340.0), box.maxHeight * 0.58).clamp(180.0, 340.0);
                  final card = keyboard ? full * 0.6 : full;
                  return SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ConstrainedBox(
                      // Centered in the space when it fits, scrollable when it does not.
                      constraints: BoxConstraints(minHeight: box.maxHeight),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(height: 4),
                          Reveal(
                            animation: _entrance,
                            end: 0.55,
                            child: Text(
                              t('Connect your computer'),
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 28, height: 1.25, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: p.ink),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Reveal(
                            animation: _entrance,
                            start: 0.08,
                            end: 0.62,
                            child: Text(
                              t('On the computer, open DS Bot Settings → Phone, show the QR code, and scan it.'),
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 15, height: 1.5, color: p.ink2),
                            ),
                          ),
                          const SizedBox(height: 24),
                          Reveal(
                            animation: _entrance,
                            start: 0.12,
                            end: 0.85,
                            offset: 36,
                            curve: SpringCurve.shape,
                            fade: false,
                            child: Shake(
                              trigger: _shakes,
                              child: TweenAnimationBuilder<double>(
                                tween: Tween(end: card),
                                duration: const Duration(milliseconds: 320),
                                curve: Curves.easeOutCubic,
                                builder: (context, size, _) => ScannerCard(
                                  stage: _stage,
                                  size: size,
                                  scanner: _scanner,
                                  onOpenCamera: _openCamera,
                                  onCloseCamera: _closeCamera,
                                  onDetect: _detected,
                                  compact: keyboard,
                                  locked: _locked,
                                  connectedName: _connected,
                                  appear: _cardIn,
                                ),
                              ),
                            ),
                          ),
                          AnimatedSize(
                            duration: const Duration(milliseconds: 360),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.topCenter,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_offer != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 16),
                                    child: _OfferCard(offer: _offer!),
                                  ),
                                if (_error != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: _ErrorPill(message: _error!),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Reveal(
                animation: _entrance,
                start: 0.35,
                end: 1,
                offset: 20,
                fade: false,
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.bottomCenter,
                  child: _manual ? _manualEntry() : _actions(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: page,
    );
  }

  Widget _topBar() {
    final app = AppScope.read(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
      child: Row(
        children: [
          if (widget.canCancel)
            _RoundIcon(icon: AppIcon.close, label: t('Cancel'), onTap: app.cancelPairing)
          else if (widget.onBack != null)
            _RoundIcon(icon: AppIcon.back, label: t('Back'), onTap: _busy ? null : widget.onBack)
          else
            const SizedBox(width: 42),
          const Spacer(),
          _RoundIcon(icon: AppIcon.question, label: t('How to pair'), onTap: () => showPairHelp(context)),
        ],
      ),
    );
  }

  Widget _actions() {
    return Row(
      children: [
        Expanded(
          child: _ActionPill(icon: AppIcon.copy, label: t('Paste link'), appear: _actionsIn, onTap: _busy ? null : _paste),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _ActionPill(icon: AppIcon.edit, label: t('Enter link'), appear: _actionsIn, onTap: _busy ? null : () => setState(() => _manual = true)),
        ),
      ],
    );
  }

  Widget _manualEntry() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _GlassField(
          controller: _link,
          onSubmitted: _pair,
          onClose: () {
            FocusScope.of(context).unfocus();
            setState(() => _manual = false);
          },
        ),
        const SizedBox(height: 12),
        HighlightGlassButton(label: t('Connect'), icon: null, height: 52, busy: _busy, onTap: () => _pair(_link.text)),
      ],
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.label, this.onTap});

  final AppIcon icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        onTap: onTap,
        haptic: true,
        scale: 0.9,
        child: LiquidGlass(
          radius: 21,
          blur: 14,
          shadow: false,
          child: SizedBox.square(
            dimension: 42,
            child: Center(child: Ico(icon, size: 20, color: context.p.ink)),
          ),
        ),
      ),
    );
  }
}

class _ActionPill extends StatelessWidget {
  const _ActionPill({required this.icon, required this.label, required this.appear, this.onTap});

  final AppIcon icon;
  final String label;
  final Animation<double> appear;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        haptic: true,
        scale: 0.96,
        child: LiquidGlass(
          radius: 26,
          blur: 16,
          shadow: false,
          appear: appear,
          // Disabled dims what is on the glass, never the glass itself.
          child: AnimatedOpacity(
            opacity: onTap == null ? 0.45 : 1,
            duration: const Duration(milliseconds: 200),
            child: SizedBox(
              height: 52,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Ico(icon, size: 18, color: p.ink2),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: TypeScale.rowNameStrong.copyWith(fontSize: 15, color: p.ink),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassField extends StatelessWidget {
  const _GlassField({required this.controller, required this.onSubmitted, required this.onClose});

  final TextEditingController controller;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    return LiquidGlass(
      radius: 18,
      blur: 16,
      shadow: false,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              onSubmitted: onSubmitted,
              textInputAction: TextInputAction.go,
              keyboardType: TextInputType.url,
              autocorrect: false,
              style: TypeScale.mono.copyWith(fontSize: 14, color: p.ink),
              decoration: const InputDecoration(
                hintText: 'dsbot://pair?…',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.fromLTRB(18, 16, 8, 16),
              ),
            ),
          ),
          IconBtn(AppIcon.close, onTap: onClose),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({required this.offer});

  final PairingOffer offer;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final fingerprint = identityFingerprint(offer.hostKey);
    final host = Uri.tryParse(offer.server)?.host ?? '';
    return LiquidGlass(
      radius: 20,
      blur: 18,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color.lerp(p.accent, Colors.white, 0.25)!, Color.lerp(p.accent, Colors.black, 0.15)!],
                ),
              ),
              child: SizedBox.square(
                dimension: 44,
                child: Center(child: Ico(AppIcon.monitor, size: 20, color: Colors.white)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    offer.name.isEmpty ? t('Computer') : offer.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TypeScale.rowNameStrong.copyWith(color: p.ink),
                  ),
                  if (host.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(t('via {host}', {'host': host}), style: TypeScale.caption.copyWith(color: p.ink3)),
                  ],
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${t('Fingerprint')}  ',
                          style: TypeScale.caption.copyWith(color: p.ink3),
                        ),
                        TextSpan(
                          text: '${fingerprint.substring(0, 4)} ${fingerprint.substring(4, 8)} ${fingerprint.substring(8)}',
                          style: TypeScale.mono.copyWith(fontSize: 12.5, color: p.ink2),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorPill extends StatelessWidget {
  const _ErrorPill({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = context.p;
    final ink = p.dark ? const Color(0xFFFF7A86) : Palette.danger;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Palette.danger.withValues(alpha: p.dark ? 0.16 : 0.09),
        border: Border.all(color: Palette.danger.withValues(alpha: 0.32), width: 0.8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Ico(AppIcon.alert, size: 16, color: ink),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: TypeScale.small.copyWith(color: ink, height: 1.4)),
            ),
          ],
        ),
      ),
    );
  }
}
