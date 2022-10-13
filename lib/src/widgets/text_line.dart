import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:tuple/tuple.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/documents/attribute.dart';
import '../models/documents/nodes/container.dart' as container_node;
import '../models/documents/nodes/embeddable.dart';
import '../models/documents/nodes/leaf.dart';
import '../models/documents/nodes/leaf.dart' as leaf;
import '../models/documents/nodes/line.dart';
import '../models/documents/nodes/node.dart';
import '../models/documents/style.dart';
import '../utils/color.dart';
import '../utils/font.dart';
import '../utils/platform.dart';
import 'box.dart';
import 'controller.dart';
import 'cursor.dart';
import 'default_styles.dart';
import 'delegate.dart';
import 'keyboard_listener.dart';
import 'link.dart';
import 'proxy.dart';
import 'text_selection.dart';

class TextLine extends StatefulWidget {
  const TextLine({
    required this.line,
    required this.embedBuilder,
    required this.styles,
    required this.readOnly,
    required this.controller,
    required this.onLaunchUrl,
    required this.linkActionPicker,
    this.textDirection,
    this.customStyleBuilder,
    // 修改，添加mentionBuilder
    this.mentionBuilder,
    this.emojiBuilder,
    this.linkParse,
    Key? key,
  }) : super(key: key);

  final Line line;
  final TextDirection? textDirection;
  final EmbedBuilder embedBuilder;
  final DefaultStyles styles;
  final bool readOnly;
  final QuillController controller;
  final CustomStyleBuilder? customStyleBuilder;
  final ValueChanged<String>? onLaunchUrl;
  final LinkActionPicker linkActionPicker;
  final InlineSpan Function(Embed, TextStyle)? mentionBuilder;
  final InlineSpan? Function(String)? emojiBuilder;
  final void Function(String)? linkParse;

  @override
  State<TextLine> createState() => _TextLineState();
}

class _TextLineState extends State<TextLine> {
  bool _metaOrControlPressed = false;

  UniqueKey _richTextKey = UniqueKey();

  final _linkRecognizers = <Node, GestureRecognizer>{};

  QuillPressedKeys? _pressedKeys;

  void _pressedKeysChanged() {
    final newValue = _pressedKeys!.metaPressed || _pressedKeys!.controlPressed;
    if (_metaOrControlPressed != newValue) {
      setState(() {
        _metaOrControlPressed = newValue;
        _richTextKey = UniqueKey();
      });
    }
  }

  bool get canLaunchLinks {
    // In readOnly mode users can launch links
    // by simply tapping (clicking) on them
    if (widget.readOnly) return true;

    // In editing mode it depends on the platform:

    // Desktop platforms (macos, linux, windows):
    // only allow Meta(Control)+Click combinations
    if (isDesktop()) {
      return _metaOrControlPressed;
    }
    // Mobile platforms (ios, android): always allow but we install a
    // long-press handler instead of a tap one. LongPress is followed by a
    // context menu with actions.
    return true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pressedKeys == null) {
      _pressedKeys = QuillPressedKeys.of(context);
      _pressedKeys!.addListener(_pressedKeysChanged);
    } else {
      _pressedKeys!.removeListener(_pressedKeysChanged);
      _pressedKeys = QuillPressedKeys.of(context);
      _pressedKeys!.addListener(_pressedKeysChanged);
    }
  }

  @override
  void didUpdateWidget(covariant TextLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.readOnly != widget.readOnly) {
      _richTextKey = UniqueKey();
      _linkRecognizers
        ..forEach((key, value) {
          value.dispose();
        })
        ..clear();
    }
  }

  @override
  void dispose() {
    _pressedKeys?.removeListener(_pressedKeysChanged);
    _linkRecognizers
      ..forEach((key, value) => value.dispose())
      ..clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    assert(debugCheckHasMediaQuery(context));
    if (widget.line.hasEmbed && widget.line.childCount == 1) {
      // For video, it is always single child
      final embed = widget.line.children.single as Embed;
      //  修改，添加判断是否VideoEmbed或者ImageEmbed
      // if (embed.value is VideoEmbed || embed.value is ImageEmbed) {
      //   // 修改，添加embedSize参数
      //   final width = (embed.value.data['width'] ?? 100).toDouble();
      //   final height = (embed.value.data['height'] ?? 100).toDouble();
      //   final size =
      //       (width != null && height != null) ? Size(width, height) : null;
      //
      //   return EmbedProxy(
      //       widget.embedBuilder(
      //           context, widget.controller, embed, widget.readOnly),
      //       embedSize: size);
      // } else
      if (embed.value is BlockEmbed && embed.value.type == 'divider') {
        /// 修改，下划线回调
        return EmbedProxy(widget.embedBuilder(
            context, widget.controller, embed, widget.readOnly));
      } else {
        return EmbedProxy(widget.embedBuilder(
            context, widget.controller, embed, widget.readOnly));
      }
    }
    final textSpan = _getTextSpanForWholeLine(context);
    final strutStyle = StrutStyle.fromTextStyle(textSpan.style!);
    final textAlign = _getTextAlign();
    final child = RichText(
      key: _richTextKey,
      text: textSpan,
      textAlign: textAlign,
      textDirection: widget.textDirection,
      strutStyle: strutStyle,
      textScaleFactor: MediaQuery.textScaleFactorOf(context),
    );
    return RichTextProxy(
        textStyle: textSpan.style!,
        textAlign: textAlign,
        textDirection: widget.textDirection!,
        strutStyle: strutStyle,
        locale: Localizations.localeOf(context),
        child: child);
  }

  InlineSpan _getTextSpanForWholeLine(BuildContext context) {
    final lineStyle = _getLineStyle(widget.styles);
    if (!widget.line.hasEmbed) {
      return _buildTextSpan(widget.styles, widget.line.children, lineStyle);
    }

    // The line could contain more than one Embed & more than one Text
    final textSpanChildren = <InlineSpan>[];
    var textNodes = LinkedList<Node>();
    for (final child in widget.line.children) {
      if (child is Embed) {
        if (textNodes.isNotEmpty) {
          textSpanChildren
              .add(_buildTextSpan(widget.styles, textNodes, lineStyle));
          textNodes = LinkedList<Node>();
        }
        // Here it should be image
        final embed = WidgetSpan(
            child: EmbedProxy(widget.embedBuilder(
                context, widget.controller, child, widget.readOnly)));
        textSpanChildren.add(embed);
        continue;
      }

      // here child is Text node and its value is cloned
      textNodes.add(child.clone());
    }

    if (textNodes.isNotEmpty) {
      textSpanChildren.add(_buildTextSpan(widget.styles, textNodes, lineStyle));
    }

    return TextSpan(style: lineStyle, children: textSpanChildren);
  }

  TextAlign _getTextAlign() {
    final alignment = widget.line.style.attributes[Attribute.align.key];
    if (alignment == Attribute.leftAlignment) {
      return TextAlign.start;
    } else if (alignment == Attribute.centerAlignment) {
      return TextAlign.center;
    } else if (alignment == Attribute.rightAlignment) {
      return TextAlign.end;
    } else if (alignment == Attribute.justifyAlignment) {
      return TextAlign.justify;
    }
    return TextAlign.start;
  }

  TextSpan _buildTextSpan(DefaultStyles defaultStyles, LinkedList<Node> nodes,
      TextStyle lineStyle) {
    if (nodes.isEmpty && kIsWeb) {
      nodes = LinkedList<Node>()..add(leaf.Text('\u{200B}'));
    }
    final children = nodes
        .map((node) =>
            _getTextSpanFromNode(defaultStyles, node, widget.line.style))
        .toList(growable: false);

    return TextSpan(children: children, style: lineStyle);
  }

  TextStyle _getLineStyle(DefaultStyles defaultStyles) {
    var textStyle = const TextStyle();

    if (widget.line.style.containsKey(Attribute.placeholder.key)) {
      return defaultStyles.placeHolder!.style;
    }

    final header = widget.line.style.attributes[Attribute.header.key];
    final m = <Attribute, TextStyle>{
      Attribute.h1: defaultStyles.h1!.style,
      Attribute.h2: defaultStyles.h2!.style,
      Attribute.h3: defaultStyles.h3!.style,
    };

    textStyle = textStyle.merge(m[header] ?? defaultStyles.paragraph!.style);

    // Only retrieve exclusive block format for the line style purpose
    Attribute? block;
    widget.line.style.getBlocksExceptHeader().forEach((key, value) {
      if (Attribute.exclusiveBlockKeys.contains(key)) {
        block = value;
      }
    });

    TextStyle? toMerge;
    if (block == Attribute.blockQuote) {
      toMerge = defaultStyles.quote!.style;
    } else if (block == Attribute.codeBlock) {
      toMerge = defaultStyles.code!.style;
    } else if (block == Attribute.list) {
      toMerge = defaultStyles.lists!.style;
    }

    textStyle = textStyle.merge(toMerge);
    textStyle = _applyCustomAttributes(textStyle, widget.line.style.attributes);

    return textStyle;
  }

  TextStyle _applyCustomAttributes(
      TextStyle textStyle, Map<String, Attribute> attributes) {
    if (widget.customStyleBuilder == null) {
      return textStyle;
    }
    attributes.keys.forEach((key) {
      final attr = attributes[key];
      if (attr != null) {
        /// Custom Attribute
        final customAttr = widget.customStyleBuilder!.call(attr);
        textStyle = textStyle.merge(customAttr);
      }
    });
    return textStyle;
  }

  InlineSpan _getTextSpanFromNode(
      DefaultStyles defaultStyles, Node node, Style lineStyle) {
    // TODO: 2022/3/2 需要业务分离TextLine与提及
    if (node is Embed && node.value is MentionEmbed) {
      final nodeStyle = node.style;
      if (widget.mentionBuilder != null) {
        // NOTE: 2022/3/2 通过外部获取@的TextSpan
        return widget.mentionBuilder!.call(
          node,
          _getInlineTextStyle(node, defaultStyles, nodeStyle, lineStyle, false),
        );
      }
      return TextSpan(text: node.value.toString());
    }

    final textNode = node as leaf.Text;
    final nodeStyle = textNode.style;
    final isLink = nodeStyle.containsKey(Attribute.link.key) &&
        nodeStyle.attributes[Attribute.link.key]!.value != null;

    final children = <InlineSpan>[];
    if (isLink) {
      return TextSpan(
        text: textNode.value,
        style: _getInlineTextStyle(
            textNode, defaultStyles, nodeStyle, lineStyle, true),
        recognizer: canLaunchLinks ? _getRecognizer(node) : null,
        mouseCursor: canLaunchLinks ? SystemMouseCursors.click : null,
      );
    } else {
      final emojiSeparator = String.fromCharCode(0);
      // NOTE: 2022/3/2 机器人会带入链接，因为Attribute值非Attribute.link，需要手动处理
      // 匹配表情和url
      final newText = textNode.value.splitMapJoin(
          RegExp(
              r'\[.*?\]|(http(s)?):\/\/[(www\.)?a-zA-Z0-9@:._\+~#=-]{1,256}\.[a-z0-9]{2,6}\b([-a-zA-Z0-9!@:_\+.~#?&//=%,]*)'),
          onMatch: (m) => '$emojiSeparator${m.group(0)}$emojiSeparator',
          onNonMatch: (m) => m);

      final splits = newText.split(emojiSeparator);
      for (final e in splits) {
        if (e.isEmpty) continue;
        if (e[0] == '[' && e[e.length - 1] == ']') {
          var child;
          final emojiName = e.substring(1, e.length - 1);
          if (widget.emojiBuilder != null) {
            child = widget.emojiBuilder!.call(emojiName);
          }
          if (child != null) {
            children.add(child);
          } else {
            children.add(TextSpan(
              text: e,
              style: _getInlineTextStyle(
                  textNode, defaultStyles, nodeStyle, lineStyle, false),
            ));
          }
        } else {
          final _isLink = e.startsWith('http');
          children.add(TextSpan(
            text: e,
            style: _getInlineTextStyle(
                textNode, defaultStyles, nodeStyle, lineStyle, _isLink),

            /// NOTE： 优先采用自定义的链接跳转
            recognizer: _isLink && canLaunchLinks
                ? (widget.linkParse != null
                    ? (TapGestureRecognizer()
                      ..onTap = () => widget.linkParse?.call(e))
                    : _getRecognizer(node))
                : null,
            mouseCursor:
                _isLink && canLaunchLinks ? SystemMouseCursors.click : null,
          ));
        }
      }
    }

    return TextSpan(children: children);
  }

  TextStyle _getInlineTextStyle(Node textNode, DefaultStyles defaultStyles,
      Style nodeStyle, Style lineStyle, bool isLink) {
    var res = const TextStyle(); // This is inline text style
    /// 添加MentionEmbed H1的处理
    if (textNode is Embed &&
        textNode.value is MentionEmbed &&
        lineStyle.containsKey(Attribute.header.key)) {
      lineStyle.attributes.forEach((key, value) {
        if (key == Attribute.header.key) {
          if (Attribute.h1 == value && defaultStyles.h1 != null) {
            res =
                _merge(res, defaultStyles.h1!.style.copyWith(color: res.color));
          }
          if (Attribute.h2 == value && defaultStyles.h2 != null) {
            res =
                _merge(res, defaultStyles.h2!.style.copyWith(color: res.color));
          }
          if (Attribute.h3 == value && defaultStyles.h3 != null) {
            res =
                _merge(res, defaultStyles.h3!.style.copyWith(color: res.color));
          }
        }
      });
    }

    final color = textNode.style.attributes[Attribute.color.key];
    <String, TextStyle?>{
      Attribute.bold.key: defaultStyles.bold,
      Attribute.italic.key: defaultStyles.italic,
      Attribute.small.key: defaultStyles.small,
      Attribute.link.key: defaultStyles.link,
      Attribute.underline.key: defaultStyles.underline,
      Attribute.strikeThrough.key: defaultStyles.strikeThrough,
      // NOTE: 2022/3/2 添加@与#样式
      Attribute.at.key: defaultStyles.at,
      Attribute.channel.key: defaultStyles.channel,
    }.forEach((k, s) {
      if (nodeStyle.values.any((v) => v.key == k)) {
        if (k == Attribute.underline.key || k == Attribute.strikeThrough.key) {
          var textColor = defaultStyles.color;
          if (color?.value is String) {
            textColor = stringToColor(color?.value, textColor);
          }
          res = _merge(res.copyWith(decorationColor: textColor),
              s!.copyWith(decorationColor: textColor));
        } else if (k == Attribute.link.key && !isLink) {
          // null value for link should be ignored
          // i.e. nodeStyle.attributes[Attribute.link.key]!.value == null
        } else {
          res = _merge(res, s!);
        }
      }
    });

    /// NOTE: 兼容没有属性的情况下的http
    if (nodeStyle.isEmpty && isLink) {
      res = _merge(res, defaultStyles.link!);
    }
    if (nodeStyle.containsKey(Attribute.inlineCode.key)) {
      res = _merge(res, defaultStyles.inlineCode!.styleFor(lineStyle));
    }

    final font = textNode.style.attributes[Attribute.font.key];
    if (font != null && font.value != null) {
      res = res.merge(TextStyle(fontFamily: font.value));
    }

    final size = textNode.style.attributes[Attribute.size.key];
    if (size != null && size.value != null) {
      switch (size.value) {
        case 'small':
          res = res.merge(defaultStyles.sizeSmall);
          break;
        case 'large':
          res = res.merge(defaultStyles.sizeLarge);
          break;
        case 'huge':
          res = res.merge(defaultStyles.sizeHuge);
          break;
        default:
          double? fontSize;
          if (size.value is double) {
            fontSize = size.value;
          } else if (size.value is int) {
            fontSize = size.value.toDouble();
          } else if (size.value is String) {
            fontSize = double.tryParse(size.value);
          }
          if (fontSize != null) {
            res = res.merge(TextStyle(fontSize: fontSize));
          } else {
            throw 'Invalid size ${size.value}';
          }
      }
    }

    if (color != null && color.value != null) {
      var textColor = defaultStyles.color;
      if (color.value is String) {
        textColor = stringToColor(color.value);
      }
      if (textColor != null) {
        res = res.merge(TextStyle(color: textColor));
      }
    }

    final background = textNode.style.attributes[Attribute.background.key];
    if (background != null && background.value != null) {
      final backgroundColor = stringToColor(background.value);
      res = res.merge(TextStyle(backgroundColor: backgroundColor));
    }

    res = _applyCustomAttributes(res, textNode.style.attributes);
    return res;
  }

  GestureRecognizer _getRecognizer(Node segment) {
    if (_linkRecognizers.containsKey(segment)) {
      return _linkRecognizers[segment]!;
    }

    if (isDesktop() || widget.readOnly) {
      _linkRecognizers[segment] = TapGestureRecognizer()
        ..onTap = () => _tapNodeLink(segment);
    } else {
      _linkRecognizers[segment] = LongPressGestureRecognizer()
        ..onLongPress = () => _longPressLink(segment);
    }
    return _linkRecognizers[segment]!;
  }

  Future<void> _launchUrl(String url) async {
    await launchUrl(Uri.parse(url));
  }

  void _tapNodeLink(Node node) {
    final link = node.style.attributes[Attribute.link.key]?.value;

    _tapLink(link);
  }

  void _tapLink(String? link) {
    if (link == null) {
      return;
    }

    var launchUrl = widget.onLaunchUrl;
    launchUrl ??= _launchUrl;

    link = link.trim();
    if (!linkPrefixes
        .any((linkPrefix) => link!.toLowerCase().startsWith(linkPrefix))) {
      link = 'https://$link';
    }

    /// NOTE: 添加自定义外部link解析
    if (widget.linkParse != null) {
      widget.linkParse?.call(link);
    } else {
      launchUrl(link);
    }
  }

  Future<void> _longPressLink(Node node) async {
    final link = node.style.attributes[Attribute.link.key]!.value!;
    final action = await widget.linkActionPicker(node);
    switch (action) {
      case LinkMenuAction.launch:
        _tapLink(link);
        break;
      case LinkMenuAction.copy:
        // ignore: unawaited_futures
        Clipboard.setData(ClipboardData(text: link));
        break;
      case LinkMenuAction.remove:
        final range = getLinkRange(node);
        widget.controller
            .formatText(range.start, range.end - range.start, Attribute.link);
        break;
      case LinkMenuAction.none:
        break;
    }
  }

  TextStyle _merge(TextStyle a, TextStyle b) {
    final decorations = <TextDecoration?>[];
    if (a.decoration != null) {
      decorations.add(a.decoration);
    }
    if (b.decoration != null) {
      decorations.add(b.decoration);
    }
    return a.merge(b).apply(
        decoration: TextDecoration.combine(
            List.castFrom<dynamic, TextDecoration>(decorations)));
  }
}

class EditableTextLine extends RenderObjectWidget {
  const EditableTextLine(
    this.line,
    this.leading,
    this.body,
    this.indentWidth,
    this.verticalSpacing,
    this.textDirection,
    this.textSelection,
    this.color,
    this.enableInteractiveSelection,
    this.hasFocus,
    this.devicePixelRatio,
    this.cursorCont,
  );

  final Line line;
  final Widget? leading;
  final Widget body;
  final double indentWidth;
  final Tuple2 verticalSpacing;
  final TextDirection textDirection;
  final TextSelection textSelection;
  final Color color;
  final bool enableInteractiveSelection;
  final bool hasFocus;
  final double devicePixelRatio;
  final CursorCont cursorCont;

  @override
  RenderObjectElement createElement() {
    return _TextLineElement(this);
  }

  @override
  RenderObject createRenderObject(BuildContext context) {
    final defaultStyles = DefaultStyles.getInstance(context);
    return RenderEditableTextLine(
        line,
        textDirection,
        textSelection,
        enableInteractiveSelection,
        hasFocus,
        devicePixelRatio,
        _getPadding(),
        color,
        cursorCont,
        defaultStyles.inlineCode!);
  }

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderEditableTextLine renderObject) {
    final defaultStyles = DefaultStyles.getInstance(context);
    renderObject
      ..setLine(line)
      ..setPadding(_getPadding())
      ..setTextDirection(textDirection)
      ..setTextSelection(textSelection)
      ..setColor(color)
      ..setEnableInteractiveSelection(enableInteractiveSelection)
      ..hasFocus = hasFocus
      ..setDevicePixelRatio(devicePixelRatio)
      ..setCursorCont(cursorCont)
      ..setInlineCodeStyle(defaultStyles.inlineCode!);
  }

  EdgeInsetsGeometry _getPadding() {
    return EdgeInsetsDirectional.only(
        start: indentWidth,
        top: verticalSpacing.item1,
        bottom: verticalSpacing.item2);
  }
}

enum TextLineSlot { LEADING, BODY }

class RenderEditableTextLine extends RenderEditableBox {
  /// Creates new editable paragraph render box.
  RenderEditableTextLine(
      this.line,
      this.textDirection,
      this.textSelection,
      this.enableInteractiveSelection,
      this.hasFocus,
      this.devicePixelRatio,
      this.padding,
      this.color,
      this.cursorCont,
      this.inlineCodeStyle);

  RenderBox? _leading;
  RenderContentProxyBox? _body;
  Line line;
  TextDirection textDirection;
  TextSelection textSelection;
  Color color;
  bool enableInteractiveSelection;
  bool hasFocus = false;
  double devicePixelRatio;
  EdgeInsetsGeometry padding;
  CursorCont cursorCont;
  EdgeInsets? _resolvedPadding;
  bool? _containsCursor;
  List<TextBox>? _selectedRects;
  late Rect _caretPrototype;
  InlineCodeStyle inlineCodeStyle;
  final Map<TextLineSlot, RenderBox> children = <TextLineSlot, RenderBox>{};

  Iterable<RenderBox> get _children sync* {
    if (_leading != null) {
      yield _leading!;
    }
    if (_body != null) {
      yield _body!;
    }
  }

  void setCursorCont(CursorCont c) {
    if (cursorCont == c) {
      return;
    }
    cursorCont = c;
    markNeedsLayout();
  }

  void setDevicePixelRatio(double d) {
    if (devicePixelRatio == d) {
      return;
    }
    devicePixelRatio = d;
    markNeedsLayout();
  }

  void setEnableInteractiveSelection(bool val) {
    if (enableInteractiveSelection == val) {
      return;
    }

    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  void setColor(Color c) {
    if (color == c) {
      return;
    }

    color = c;
    if (containsTextSelection()) {
      safeMarkNeedsPaint();
    }
  }

  void setTextSelection(TextSelection t) {
    if (textSelection == t) {
      return;
    }

    final containsSelection = containsTextSelection();
    if (_attachedToCursorController) {
      cursorCont.removeListener(markNeedsLayout);
      cursorCont.color.removeListener(safeMarkNeedsPaint);
      _attachedToCursorController = false;
    }

    textSelection = t;
    _selectedRects = null;
    _containsCursor = null;
    if (attached && containsCursor()) {
      cursorCont.addListener(markNeedsLayout);
      cursorCont.color.addListener(safeMarkNeedsPaint);
      _attachedToCursorController = true;
    }

    if (containsSelection || containsTextSelection()) {
      safeMarkNeedsPaint();
    }
  }

  void setTextDirection(TextDirection t) {
    if (textDirection == t) {
      return;
    }
    textDirection = t;
    _resolvedPadding = null;
    markNeedsLayout();
  }

  void setLine(Line l) {
    if (line == l) {
      return;
    }
    line = l;
    _containsCursor = null;
    markNeedsLayout();
  }

  void setPadding(EdgeInsetsGeometry p) {
    assert(p.isNonNegative);
    if (padding == p) {
      return;
    }
    padding = p;
    _resolvedPadding = null;
    markNeedsLayout();
  }

  void setLeading(RenderBox? l) {
    _leading = _updateChild(_leading, l, TextLineSlot.LEADING);
  }

  void setBody(RenderContentProxyBox? b) {
    _body = _updateChild(_body, b, TextLineSlot.BODY) as RenderContentProxyBox?;
  }

  void setInlineCodeStyle(InlineCodeStyle newStyle) {
    if (inlineCodeStyle == newStyle) return;
    inlineCodeStyle = newStyle;
    markNeedsLayout();
  }

  // Start selection implementation

  bool containsTextSelection() {
    return line.documentOffset <= textSelection.end &&
        textSelection.start <= line.documentOffset + line.length - 1;
  }

  bool containsCursor() {
    return _containsCursor ??= cursorCont.isFloatingCursorActive
        ? line
            .containsOffset(cursorCont.floatingCursorTextPosition.value!.offset)
        : textSelection.isCollapsed &&
            line.containsOffset(textSelection.baseOffset);
  }

  RenderBox? _updateChild(
      RenderBox? old, RenderBox? newChild, TextLineSlot slot) {
    if (old != null) {
      dropChild(old);
      children.remove(slot);
    }
    if (newChild != null) {
      children[slot] = newChild;
      adoptChild(newChild);
    }
    return newChild;
  }

  List<TextBox> _getBoxes(TextSelection textSelection) {
    final parentData = _body!.parentData as BoxParentData?;
    return _body!.getBoxesForSelection(textSelection).map((box) {
      return TextBox.fromLTRBD(
        box.left + parentData!.offset.dx,
        box.top + parentData.offset.dy,
        box.right + parentData.offset.dx,
        box.bottom + parentData.offset.dy,
        box.direction,
      );
    }).toList(growable: false);
  }

  void _resolvePadding() {
    if (_resolvedPadding != null) {
      return;
    }
    _resolvedPadding = padding.resolve(textDirection);
    assert(_resolvedPadding!.isNonNegative);
  }

  @override
  TextSelectionPoint getBaseEndpointForSelection(TextSelection textSelection) {
    return _getEndpointForSelection(textSelection, true);
  }

  @override
  TextSelectionPoint getExtentEndpointForSelection(
      TextSelection textSelection) {
    return _getEndpointForSelection(textSelection, false);
  }

  TextSelectionPoint _getEndpointForSelection(
      TextSelection textSelection, bool first) {
    if (textSelection.isCollapsed) {
      return TextSelectionPoint(
          Offset(0, preferredLineHeight(textSelection.extent)) +
              getOffsetForCaret(textSelection.extent),
          null);
    }
    final boxes = _getBoxes(textSelection);
    assert(boxes.isNotEmpty);
    final targetBox = first ? boxes.first : boxes.last;
    return TextSelectionPoint(
        Offset(first ? targetBox.start : targetBox.end, targetBox.bottom),
        targetBox.direction);
  }

  @override
  TextRange getLineBoundary(TextPosition position) {
    final lineDy = getOffsetForCaret(position)
        .translate(0, 0.5 * preferredLineHeight(position))
        .dy;
    final lineBoxes =
        _getBoxes(TextSelection(baseOffset: 0, extentOffset: line.length - 1))
            .where((element) => element.top < lineDy && element.bottom > lineDy)
            .toList(growable: false);
    return TextRange(
        start:
            getPositionForOffset(Offset(lineBoxes.first.left, lineDy)).offset,
        end: getPositionForOffset(Offset(lineBoxes.last.right, lineDy)).offset);
  }

  @override
  Offset getOffsetForCaret(TextPosition position) {
    return _body!.getOffsetForCaret(position, _caretPrototype) +
        (_body!.parentData as BoxParentData).offset;
  }

  @override
  TextPosition? getPositionAbove(TextPosition position) {
    return _getPosition(position, -0.5);
  }

  @override
  TextPosition? getPositionBelow(TextPosition position) {
    return _getPosition(position, 1.5);
  }

  @override
  bool get isRepaintBoundary => true;

  TextPosition? _getPosition(TextPosition textPosition, double dyScale) {
    assert(textPosition.offset < line.length);
    final offset = getOffsetForCaret(textPosition)
        .translate(0, dyScale * preferredLineHeight(textPosition));
    if (_body!.size
        .contains(offset - (_body!.parentData as BoxParentData).offset)) {
      return getPositionForOffset(offset);
    }
    return null;
  }

  @override
  TextPosition getPositionForOffset(Offset offset) {
    return _body!.getPositionForOffset(
        offset - (_body!.parentData as BoxParentData).offset);
  }

  @override
  TextRange getWordBoundary(TextPosition position) {
    return _body!.getWordBoundary(position);
  }

  @override
  double preferredLineHeight(TextPosition position) {
    return _body!.preferredLineHeight;
  }

  @override
  container_node.Container get container => line;

  double get cursorWidth => cursorCont.style.width;

  double get cursorHeight =>
      cursorCont.style.height ??
      preferredLineHeight(const TextPosition(offset: 0));

  // TODO: This is no longer producing the highest-fidelity caret
  // heights for Android, especially when non-alphabetic languages
  // are involved. The current implementation overrides the height set
  // here with the full measured height of the text on Android which looks
  // superior (subjectively and in terms of fidelity) in _paintCaret. We
  // should rework this properly to once again match the platform. The constant
  // _kCaretHeightOffset scales poorly for small font sizes.
  //
  /// On iOS, the cursor is taller than the cursor on Android. The height
  /// of the cursor for iOS is approximate and obtained through an eyeball
  /// comparison.
  void _computeCaretPrototype() {
    if (isAppleOS()) {
      _caretPrototype = Rect.fromLTWH(0, 0, cursorWidth, cursorHeight + 2);
    } else {
      _caretPrototype = Rect.fromLTWH(0, 2, cursorWidth, cursorHeight - 4.0);
    }
  }

  void _onFloatingCursorChange() {
    _containsCursor = null;
    markNeedsPaint();
  }

  // End caret implementation

  //

  // Start render box overrides

  bool _attachedToCursorController = false;

  @override
  void attach(covariant PipelineOwner owner) {
    super.attach(owner);
    for (final child in _children) {
      child.attach(owner);
    }
    cursorCont.floatingCursorTextPosition.addListener(_onFloatingCursorChange);
    if (containsCursor()) {
      cursorCont.addListener(markNeedsLayout);
      cursorCont.color.addListener(safeMarkNeedsPaint);
      _attachedToCursorController = true;
    }
  }

  @override
  void detach() {
    super.detach();
    for (final child in _children) {
      child.detach();
    }
    cursorCont.floatingCursorTextPosition
        .removeListener(_onFloatingCursorChange);
    if (_attachedToCursorController) {
      cursorCont.removeListener(markNeedsLayout);
      cursorCont.color.removeListener(safeMarkNeedsPaint);
      _attachedToCursorController = false;
    }
  }

  @override
  void redepthChildren() {
    _children.forEach(redepthChild);
  }

  @override
  void visitChildren(RenderObjectVisitor visitor) {
    _children.forEach(visitor);
  }

  @override
  List<DiagnosticsNode> debugDescribeChildren() {
    final value = <DiagnosticsNode>[];
    void add(RenderBox? child, String name) {
      if (child != null) {
        value.add(child.toDiagnosticsNode(name: name));
      }
    }

    add(_leading, 'leading');
    add(_body, 'body');
    return value;
  }

  @override
  bool get sizedByParent => false;

  @override
  double computeMinIntrinsicWidth(double height) {
    _resolvePadding();
    final horizontalPadding = _resolvedPadding!.left + _resolvedPadding!.right;
    final verticalPadding = _resolvedPadding!.top + _resolvedPadding!.bottom;
    final leadingWidth = _leading == null
        ? 0
        : _leading!.getMinIntrinsicWidth(height - verticalPadding).ceil();
    final bodyWidth = _body == null
        ? 0
        : _body!
            .getMinIntrinsicWidth(math.max(0, height - verticalPadding))
            .ceil();
    return horizontalPadding + leadingWidth + bodyWidth;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    _resolvePadding();
    final horizontalPadding = _resolvedPadding!.left + _resolvedPadding!.right;
    final verticalPadding = _resolvedPadding!.top + _resolvedPadding!.bottom;
    final leadingWidth = _leading == null
        ? 0
        : _leading!.getMaxIntrinsicWidth(height - verticalPadding).ceil();
    final bodyWidth = _body == null
        ? 0
        : _body!
            .getMaxIntrinsicWidth(math.max(0, height - verticalPadding))
            .ceil();
    return horizontalPadding + leadingWidth + bodyWidth;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    _resolvePadding();
    final horizontalPadding = _resolvedPadding!.left + _resolvedPadding!.right;
    final verticalPadding = _resolvedPadding!.top + _resolvedPadding!.bottom;
    if (_body != null) {
      return _body!
              .getMinIntrinsicHeight(math.max(0, width - horizontalPadding)) +
          verticalPadding;
    }
    return verticalPadding;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    _resolvePadding();
    final horizontalPadding = _resolvedPadding!.left + _resolvedPadding!.right;
    final verticalPadding = _resolvedPadding!.top + _resolvedPadding!.bottom;
    if (_body != null) {
      return _body!
              .getMaxIntrinsicHeight(math.max(0, width - horizontalPadding)) +
          verticalPadding;
    }
    return verticalPadding;
  }

  @override
  double computeDistanceToActualBaseline(TextBaseline baseline) {
    _resolvePadding();
    return _body!.getDistanceToActualBaseline(baseline)! +
        _resolvedPadding!.top;
  }

  @override
  void performLayout() {
    final constraints = this.constraints;
    _selectedRects = null;

    _resolvePadding();
    assert(_resolvedPadding != null);

    if (_body == null && _leading == null) {
      size = constraints.constrain(Size(
        _resolvedPadding!.left + _resolvedPadding!.right,
        _resolvedPadding!.top + _resolvedPadding!.bottom,
      ));
      return;
    }
    final innerConstraints = constraints.deflate(_resolvedPadding!);

    final indentWidth = textDirection == TextDirection.ltr
        ? _resolvedPadding!.left
        : _resolvedPadding!.right;

    _body!.layout(innerConstraints, parentUsesSize: true);
    (_body!.parentData as BoxParentData).offset =
        Offset(_resolvedPadding!.left, _resolvedPadding!.top);

    if (_leading != null) {
      final leadingConstraints = innerConstraints.copyWith(
          minWidth: indentWidth,
          maxWidth: indentWidth,
          maxHeight: _body!.size.height);
      _leading!.layout(leadingConstraints, parentUsesSize: true);
      (_leading!.parentData as BoxParentData).offset =
          Offset(0, _resolvedPadding!.top);
    }

    size = constraints.constrain(Size(
      _resolvedPadding!.left + _body!.size.width + _resolvedPadding!.right,
      _resolvedPadding!.top + _body!.size.height + _resolvedPadding!.bottom,
    ));

    _computeCaretPrototype();
  }

  CursorPainter get _cursorPainter => CursorPainter(
        editable: _body,
        style: cursorCont.style,
        prototype: _caretPrototype,
        color: cursorCont.isFloatingCursorActive
            ? cursorCont.style.backgroundColor
            : cursorCont.color.value,
        devicePixelRatio: devicePixelRatio,
      );

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_leading != null) {
      final parentData = _leading!.parentData as BoxParentData;
      final effectiveOffset = offset + parentData.offset;
      context.paintChild(_leading!, effectiveOffset);
    }

    if (_body != null) {
      final parentData = _body!.parentData as BoxParentData;
      final effectiveOffset = offset + parentData.offset;

      if (inlineCodeStyle.backgroundColor != null) {
        for (final item in line.children) {
          if (item is! leaf.Text ||
              !item.style.containsKey(Attribute.inlineCode.key)) {
            continue;
          }
          final textRange = TextSelection(
              baseOffset: item.offset, extentOffset: item.offset + item.length);
          final rects = _body!.getBoxesForSelection(textRange);
          final paint = Paint()..color = inlineCodeStyle.backgroundColor!;
          for (final box in rects) {
            final rect = box.toRect().translate(0, 1).shift(effectiveOffset);
            if (inlineCodeStyle.radius == null) {
              final paintRect = Rect.fromLTRB(
                  rect.left - 2, rect.top, rect.right + 2, rect.bottom);
              context.canvas.drawRect(paintRect, paint);
            } else {
              final paintRect = RRect.fromLTRBR(rect.left - 2, rect.top,
                  rect.right + 2, rect.bottom, inlineCodeStyle.radius!);
              context.canvas.drawRRect(paintRect, paint);
            }
          }
        }
      }

      if (hasFocus &&
          cursorCont.show.value &&
          containsCursor() &&
          !cursorCont.style.paintAboveText) {
        _paintCursor(context, effectiveOffset, line.hasEmbed);
      }

      context.paintChild(_body!, effectiveOffset);

      if (hasFocus &&
          cursorCont.show.value &&
          containsCursor() &&
          cursorCont.style.paintAboveText) {
        _paintCursor(context, effectiveOffset, line.hasEmbed);
      }

      // paint the selection on the top
      if (enableInteractiveSelection &&
          line.documentOffset <= textSelection.end &&
          textSelection.start <= line.documentOffset + line.length - 1) {
        final local = localSelection(line, textSelection, false);
        _selectedRects ??= _body!.getBoxesForSelection(
          local,
        );
        _paintSelection(context, effectiveOffset);
      }
    }
  }

  void _paintSelection(PaintingContext context, Offset effectiveOffset) {
    assert(_selectedRects != null);
    final paint = Paint()..color = color;
    for (final box in _selectedRects!) {
      context.canvas.drawRect(box.toRect().shift(effectiveOffset), paint);
    }
  }

  void _paintCursor(
      PaintingContext context, Offset effectiveOffset, bool lineHasEmbed) {
    final position = cursorCont.isFloatingCursorActive
        ? TextPosition(
            offset: cursorCont.floatingCursorTextPosition.value!.offset -
                line.documentOffset,
            affinity: cursorCont.floatingCursorTextPosition.value!.affinity)
        : TextPosition(
            offset: textSelection.extentOffset - line.documentOffset,
            affinity: textSelection.base.affinity);
    _cursorPainter.paint(
        context.canvas, effectiveOffset, position, lineHasEmbed);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (_leading != null) {
      final childParentData = _leading!.parentData as BoxParentData;
      final isHit = result.addWithPaintOffset(
          offset: childParentData.offset,
          position: position,
          hitTest: (result, transformed) {
            assert(transformed == position - childParentData.offset);
            return _leading!.hitTest(result, position: transformed);
          });
      if (isHit) return true;
    }
    if (_body == null) return false;
    final parentData = _body!.parentData as BoxParentData;
    return result.addWithPaintOffset(
        offset: parentData.offset,
        position: position,
        hitTest: (result, position) {
          return _body!.hitTest(result, position: position);
        });
  }

  @override
  Rect getLocalRectForCaret(TextPosition position) {
    final caretOffset = getOffsetForCaret(position);
    var rect =
        Rect.fromLTWH(0, 0, cursorWidth, cursorHeight).shift(caretOffset);
    final cursorOffset = cursorCont.style.offset;
    // Add additional cursor offset (generally only if on iOS).
    if (cursorOffset != null) rect = rect.shift(cursorOffset);
    return rect;
  }

  @override
  TextPosition globalToLocalPosition(TextPosition position) {
    assert(container.containsOffset(position.offset),
        'The provided text position is not in the current node');
    return TextPosition(
      offset: position.offset - container.documentOffset,
      affinity: position.affinity,
    );
  }

  void safeMarkNeedsPaint() {
    if (!attached) {
      //Should not paint if it was unattached.
      return;
    }
    markNeedsPaint();
  }

  @override
  Rect getCaretPrototype(TextPosition position) => _caretPrototype;
}

class _TextLineElement extends RenderObjectElement {
  _TextLineElement(EditableTextLine line) : super(line);

  final Map<TextLineSlot, Element> _slotToChildren = <TextLineSlot, Element>{};

  @override
  EditableTextLine get widget => super.widget as EditableTextLine;

  @override
  RenderEditableTextLine get renderObject =>
      super.renderObject as RenderEditableTextLine;

  @override
  void visitChildren(ElementVisitor visitor) {
    _slotToChildren.values.forEach(visitor);
  }

  @override
  void forgetChild(Element child) {
    assert(_slotToChildren.containsValue(child));
    assert(child.slot is TextLineSlot);
    assert(_slotToChildren.containsKey(child.slot));
    _slotToChildren.remove(child.slot);
    super.forgetChild(child);
  }

  @override
  void mount(Element? parent, dynamic newSlot) {
    super.mount(parent, newSlot);
    _mountChild(widget.leading, TextLineSlot.LEADING);
    _mountChild(widget.body, TextLineSlot.BODY);
  }

  @override
  void update(EditableTextLine newWidget) {
    super.update(newWidget);
    assert(widget == newWidget);
    _updateChild(widget.leading, TextLineSlot.LEADING);
    _updateChild(widget.body, TextLineSlot.BODY);
  }

  @override
  void insertRenderObjectChild(RenderBox child, TextLineSlot? slot) {
    // assert(child is RenderBox);
    _updateRenderObject(child, slot);
    assert(renderObject.children.keys.contains(slot));
  }

  @override
  void removeRenderObjectChild(RenderObject child, TextLineSlot? slot) {
    assert(child is RenderBox);
    assert(renderObject.children[slot!] == child);
    _updateRenderObject(null, slot);
    assert(!renderObject.children.keys.contains(slot));
  }

  @override
  void moveRenderObjectChild(
      RenderObject child, dynamic oldSlot, dynamic newSlot) {
    throw UnimplementedError();
  }

  void _mountChild(Widget? widget, TextLineSlot slot) {
    final oldChild = _slotToChildren[slot];
    final newChild = updateChild(oldChild, widget, slot);
    if (oldChild != null) {
      _slotToChildren.remove(slot);
    }
    if (newChild != null) {
      _slotToChildren[slot] = newChild;
    }
  }

  void _updateRenderObject(RenderBox? child, TextLineSlot? slot) {
    switch (slot) {
      case TextLineSlot.LEADING:
        renderObject.setLeading(child);
        break;
      case TextLineSlot.BODY:
        renderObject.setBody(child as RenderContentProxyBox?);
        break;
      default:
        throw UnimplementedError();
    }
  }

  void _updateChild(Widget? widget, TextLineSlot slot) {
    final oldChild = _slotToChildren[slot];
    final newChild = updateChild(oldChild, widget, slot);
    if (oldChild != null) {
      _slotToChildren.remove(slot);
    }
    if (newChild != null) {
      _slotToChildren[slot] = newChild;
    }
  }
}
