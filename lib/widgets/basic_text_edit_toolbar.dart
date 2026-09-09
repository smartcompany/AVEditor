import 'package:aveditor/models/text_overlay.dart';
import 'package:aveditor/models/text_overlay_style.dart';
import 'package:aveditor/widgets/overlay_fonts.dart';
import 'package:flutter/material.dart';

/// Shared with the on-canvas [TextField] TapRegion so toolbar taps do not
/// count as "outside" and dismiss the keyboard.
const Object kBasicTextEditTapGroup = 'basic_text_edit';

/// Brief window after a toolbar pointer so style/color taps cannot dismiss
/// inline editing via [TapRegion.onTapOutside].
class BasicTextEditDismissGuard {
  BasicTextEditDismissGuard._();

  static DateTime? _armedUntil;

  static void arm([Duration ttl = const Duration(milliseconds: 600)]) {
    _armedUntil = DateTime.now().add(ttl);
  }

  static bool get isArmed {
    final until = _armedUntil;
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _armedUntil = null;
      return false;
    }
    return true;
  }
}

enum _TrayMode { fonts, colors }

/// YouTube Shorts–style strip above the keyboard for basic text editing.
class BasicTextEditToolbar extends StatefulWidget {
  const BasicTextEditToolbar({
    super.key,
    required this.overlay,
    required this.onChanged,
  });

  final TextOverlay overlay;
  final ValueChanged<TextOverlay> onChanged;

  static const colors = <Color>[
    Colors.white,
    Colors.black,
    Color(0xFFFF4D4D),
    Color(0xFFFF8A3D),
    Color(0xFFFFD166),
    Color(0xFF06D6A0),
    Color(0xFF4CC9F0),
    Color(0xFF7B61FF),
    Color(0xFFFF5DA2),
    Color(0xFFB0B0B0),
  ];

  static const barBackground = _barBg;
  static const _barBg = Color(0xFF12141A);
  static const _controlsBg = Color(0xFF1A1C22);
  static const _trayBg = Color(0xFF2A2F3A);

  @override
  State<BasicTextEditToolbar> createState() => _BasicTextEditToolbarState();
}

class _BasicTextEditToolbarState extends State<BasicTextEditToolbar> {
  _TrayMode _tray = _TrayMode.colors;

  TextOverlay get _overlay => widget.overlay;

  void _emit(TextOverlay next) {
    BasicTextEditDismissGuard.arm();
    widget.onChanged(next);
  }

  void _cycleAlign() {
    final next = switch (_overlay.textAlign) {
      TextAlign.left || TextAlign.start => TextAlign.center,
      TextAlign.center => TextAlign.right,
      _ => TextAlign.left,
    };
    _emit(_overlay.copyWith(textAlign: next));
  }

  void _cycleStyle() {
    _emit(
      _overlay.copyWith(
        style: _overlay.style.next,
        templateId: null,
        packItemId: null,
      ),
    );
  }

  Future<void> _pickFont(String id) async {
    await OverlayFonts.ensureLoaded(id);
    if (!mounted) return;
    // Stay on the font tray so the user can preview other faces.
    _emit(_overlay.copyWith(fontFamily: id));
  }

  IconData get _alignIcon {
    return switch (_overlay.textAlign) {
      TextAlign.left || TextAlign.start => Icons.format_align_left,
      TextAlign.right || TextAlign.end => Icons.format_align_right,
      _ => Icons.format_align_center,
    };
  }

  /// Shorts A button: fill → stroke → box → dim box.
  Widget _buildStyleGlyph() {
    final style = _overlay.style;
    final color = _overlay.color;
    final fill = switch (style) {
      TextOverlayStyle.plain => color,
      TextOverlayStyle.outline =>
        color.computeLuminance() > 0.6 ? Colors.black : Colors.white,
      TextOverlayStyle.box =>
        color.computeLuminance() > 0.55 ? Colors.black : Colors.white,
      TextOverlayStyle.boxDim => Colors.white,
    };
    final bg = switch (style) {
      TextOverlayStyle.plain || TextOverlayStyle.outline => Colors.transparent,
      TextOverlayStyle.box => color,
      TextOverlayStyle.boxDim => color.withValues(alpha: 0.55),
    };
    final border = style == TextOverlayStyle.outline
        ? Border.all(color: color, width: 2)
        : null;

    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: border,
      ),
      child: Text(
        'A',
        style: TextStyle(
          color: fill,
          fontSize: 16,
          fontWeight: FontWeight.w800,
          height: 1,
          shadows: style == TextOverlayStyle.plain
              ? const [Shadow(blurRadius: 4, color: Color(0x88000000))]
              : null,
        ),
      ),
    );
  }

  Widget _buildAaSample({
    required OverlayFontOption font,
    required Color color,
    double size = 18,
  }) {
    return Text(
      'Aa',
      style: font
          .apply(
            TextStyle(
              color: color,
              fontSize: size,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          )
          .copyWith(fontSize: size, height: 1),
    );
  }

  Widget _buildColorSwatch({
    required Color color,
    required bool selected,
    required VoidCallback onTap,
    double size = 28,
  }) {
    final isLight = color.computeLuminance() > 0.85;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? const Color(0xFF4CC9F0)
                : (isLight ? Colors.white38 : Colors.white24),
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }

  /// IconButton can steal focus / drop IME — use a plain tap target instead.
  Widget _buildToolButton({
    required Widget child,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(child: child),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final font = OverlayFonts.byId(_overlay.fontFamily);
    final fontsOpen = _tray == _TrayMode.fonts;
    final colorsOpen = _tray == _TrayMode.colors;

    return TapRegion(
      groupId: kBasicTextEditTapGroup,
      child: ExcludeFocus(
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => BasicTextEditDismissGuard.arm(),
          child: Material(
            color: BasicTextEditToolbar._barBg,
            child: SizedBox(
              height: 52,
              child: Row(
                children: [
                  // Selected / primary controls — separate strip from the tray.
                  ColoredBox(
                    color: BasicTextEditToolbar._controlsBg,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(width: 4),
                        _ToolbarChip(
                          selected: fontsOpen,
                          onTap: () =>
                              setState(() => _tray = _TrayMode.fonts),
                          child: _buildAaSample(
                            font: font,
                            color: fontsOpen
                                ? const Color(0xFF4CC9F0)
                                : Colors.white,
                          ),
                        ),
                        _buildToolButton(
                          onTap: _cycleAlign,
                          child: Icon(
                            _alignIcon,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                        _buildToolButton(
                          onTap: _cycleStyle,
                          child: _buildStyleGlyph(),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 2, right: 10),
                          child: _buildColorSwatch(
                            color: _overlay.color,
                            selected: colorsOpen,
                            onTap: () =>
                                setState(() => _tray = _TrayMode.colors),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(width: 1, color: Colors.white12),
                  // Options tray — lighter panel so it reads as a sub-list.
                  Expanded(
                    child: ColoredBox(
                      color: BasicTextEditToolbar._trayBg,
                      child: fontsOpen
                          ? _buildFontScroller()
                          : _buildColorScroller(),
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

  Widget _buildColorScroller() {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: BasicTextEditToolbar.colors.length,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (context, index) {
        final color = BasicTextEditToolbar.colors[index];
        final selected = color.toARGB32() == _overlay.color.toARGB32();
        return Center(
          child: _buildColorSwatch(
            color: color,
            selected: selected,
            onTap: () => _emit(_overlay.copyWith(color: color)),
          ),
        );
      },
    );
  }

  Widget _buildFontScroller() {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      itemCount: OverlayFonts.all.length,
      separatorBuilder: (_, _) => const SizedBox(width: 6),
      itemBuilder: (context, index) {
        final option = OverlayFonts.all[index];
        final selected =
            option.id == OverlayFonts.byId(_overlay.fontFamily).id;
        return Center(
          child: _ToolbarChip(
            selected: selected,
            onTap: () => _pickFont(option.id),
            child: Text(
              option.label,
              style: option
                  .apply(
                    TextStyle(
                      color: selected
                          ? const Color(0xFF4CC9F0)
                          : Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                  .copyWith(fontSize: 13),
            ),
          ),
        );
      },
    );
  }
}

class _ToolbarChip extends StatelessWidget {
  const _ToolbarChip({
    required this.child,
    required this.onTap,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFF2A2E38) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: child,
        ),
      ),
    );
  }
}
