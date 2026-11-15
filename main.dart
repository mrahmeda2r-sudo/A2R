import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ===== البيانات =====
// بيانات A2R - من ملف A2R2_Settings_v2.xlsx
// لتعديل أي اسم / وحدة / TID / مبنى عدّل هنا فقط.

class Unit {
  final int num; // رقم الوحدة (بيستخدم في اسم الملف والصورة)
  final String name;
  final String tid;
  final List<String> buildings;
  const Unit(this.num, this.name, this.tid, [this.buildings = const []]);

  /// اسم الوحدة للملفات: بدون همزات/أقواس، والمسافات نقط
  String get slug => name
      .replaceAll(RegExp('[أإآ]'), 'ا')
      .replaceAll(RegExp(r'[()]'), ' ')
      .trim()
      .split(RegExp(r'[\s.]+'))
      .join('.');
}

class Session {
  final String name;
  final Unit unit;
  final String? building;
  Session(this.name, this.unit, this.building);

  String get date {
    final n = DateTime.now();
    return '${n.day.toString().padLeft(2, '0')}/${n.month.toString().padLeft(2, '0')}/${n.year}';
  }

  /// مثال: 8.المنتزه.1.يوم.14.11  (اليوم.الشهر من تاريخ الموبايل بدون أصفار)
  String get pdfName {
    final n = DateTime.now();
    return '${unit.num}.${unit.slug}.يوم.${n.day}.${n.month}';
  }

  /// اسم صورة الباتش = رقم الوحدة فقط
  String get batchName => '${unit.num}';
}

const kNames = <String>[
  'خالد محمد',
  'محمد السيد دندن',
  'احمد وليد',
  'محمد زكريا',
  'احمد مصطفى',
  'زياد أحمد',
  'مصطفى محمد',
  'ادهم ماهر',
  'احمد سعيد',
  'عبدالله محمد',
  'محمد مجدى',
  'سماح جمال',
  'امير حسين',
  'كريم صبرى',
  'احمد مجدى',
  'عمر فتحى',
  'محمد احمد',
  'احمد جابر',
  'باسم محمد',
  'باسم مصطفى',
  'احمد رمضان',
];

const _abis = ['تحت', 'فوق', 'المركز الزكي'];
const _borg = ['برج العرب', 'محرم بيك', 'ابيس', 'الرحلات', 'المنتزه'];
const _montaza = ['الاداري تحت', 'الاداري فوق', 'المركز الزكي'];
const _moharam = ['محرم بيك', 'محرم بيك 1', 'محرم بيك 2'];
const _agami = ['العجمي', 'الملاكي'];
const _qabbari = ['النقل']; // مبنى واحد -> مفيش قايمة

const kUnits = <Unit>[
  Unit(1, 'أبيس 1', '50335710', _abis),
  Unit(2, 'أبيس 2', '50335993', _abis),
  Unit(3, 'أبيس 3', '50335987', _abis),
  Unit(4, 'برج العرب 1', '50325716', _borg),
  Unit(5, 'برج العرب 2', '50335998', _borg),
  Unit(6, 'برج العرب 3', '50335994', _borg),
  Unit(7, 'برج العرب 4', '50335711', _borg),
  Unit(8, 'المنتزه 1', '50382298', _montaza),
  Unit(9, 'المنتزه 2', '50382315', _montaza),
  Unit(10, 'المنتزه 3', '50383712', _montaza),
  Unit(11, 'محرم بك 1', '50382306', _moharam),
  Unit(12, 'محرم بك 2', '50382316', _moharam),
  Unit(13, 'العجمي 1', '50382308', _agami),
  Unit(14, 'العجمي 2', '50383706', _agami),
  Unit(15, 'أبيس (احتياطي)', '50325765', _abis),
  Unit(16, 'برج العرب (احتياطي 1)', '50322364', _borg),
  Unit(17, 'برج العرب (احتياطي 2)', '50322361', _borg),
  Unit(18, 'المنتزه (احتياطي)', '50382150', _montaza),
  Unit(19, 'محرم بك (احتياطي)', '50381092', _moharam),
  Unit(20, 'العجمي (احتياطي)', '50381077', _agami),
  Unit(21, 'القباري', '50382300', _qabbari),
  Unit(22, 'مصطفى كامل', '50383702'),
  Unit(23, 'مديرية الأمن', '50382312'),
  Unit(24, 'ميناء الإسكندرية', '50383699'),
  Unit(25, 'خدمات مصر', '50383700'),
];

// ===== رسم الورقة الصغيرة =====
class Rendered {
  final Uint8List png;
  final double ratio; // height / width
  Rendered(this.png, this.ratio);
}

Future<ui.Image> decodeImage(Uint8List b) async {
  final c = await ui.instantiateImageCodec(b);
  return (await c.getNextFrame()).image;
}

TextPainter _tp(String t, double fs, TextDirection d) => TextPainter(
      text: TextSpan(
          text: t,
          style: TextStyle(
              color: Colors.black, fontSize: fs, fontWeight: FontWeight.bold)),
      textDirection: d,
    )..layout();

Future<Rendered> _render(double w, double h, void Function(Canvas) draw) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
  draw(canvas);
  final img = await rec.endRecording().toImage(w.ceil(), h.ceil());
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return Rendered(bd!.buffer.asUint8List(), h / w);
}

String _isoLtr(String s) => '\u2066$s\u2069';

/// الورقة الصغيرة فوق كل صورة إيصالات: الاسم / الوحدة (+المبنى) / TID / التاريخ
Future<Rendered> receiptLabel(double w, Session s) async {
  final fs = w * 0.034;
  final unitLine = s.building == null ? s.unit.name : '${s.unit.name} - ${s.building}';
  final lines = <TextPainter>[
    _tp(s.name, fs, TextDirection.rtl),
    _tp(unitLine, fs, TextDirection.rtl),
    _tp('TID: ${s.unit.tid}', fs, TextDirection.ltr),
    _tp(s.date, fs, TextDirection.ltr),
  ];
  final gap = fs * 0.35;
  final pad = fs * 0.9;
  final textW = lines.map((l) => l.width).reduce((a, b) => a > b ? a : b);
  final textH = lines.fold<double>(0, (a, l) => a + l.height) + gap * (lines.length - 1);
  final cardW = (textW + pad * 2).clamp(w * 0.4, w * 0.95);
  final cardH = textH + pad * 2;
  final margin = fs * 0.6;
  final h = cardH + margin * 2;
  return _render(w, h, (c) {
    final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH((w - cardW) / 2, margin, cardW, cardH), Radius.circular(fs * 0.5));
    c.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.004
          ..color = Colors.black);
    var y = margin + pad;
    for (final l in lines) {
      l.paint(c, Offset((w - l.width) / 2, y));
      y += l.height + gap;
    }
  });
}

/// الشريط الرفيع فوق صورة الباتش (بدون TID):
/// سطر 1: الاسم | الوحدة     سطر 2: المبنى | التاريخ
Future<Rendered> batchStrip(double w, Session s) async {
  final fs = w * 0.026;
  final l1 = '${s.name}  |  ${s.unit.name}';
  final l2 = s.building == null
      ? _isoLtr(s.date)
      : '${s.building}  |  ${_isoLtr(s.date)}';
  final lines = [_tp(l1, fs, TextDirection.rtl), _tp(l2, fs, TextDirection.rtl)];
  final gap = fs * 0.25;
  final pad = fs * 0.5;
  final h = lines[0].height + lines[1].height + gap + pad * 2;
  return _render(w, h, (c) {
    var y = pad;
    for (final l in lines) {
      l.paint(c, Offset((w - l.width) / 2, y));
      y += l.height + gap;
    }
    c.drawLine(Offset(0, h - 1), Offset(w, h - 1),
        Paint()..color = Colors.black..strokeWidth = w * 0.002);
  });
}

// ===== بناء الـ PDF =====
/// تصغير وضغط الصورة (JPEG) عشان الـ PDF يطلع خفيف وميتقلش على التليفون.
Future<Uint8List> _shrink(String path, {int width = 1280, int quality = 60}) async {
  try {
    final out = await FlutterImageCompress.compressWithFile(
      path,
      minWidth: width,
      minHeight: width,
      quality: quality,
      format: CompressFormat.jpeg,
      keepExif: false,
    );
    if (out != null) return out;
  } catch (_) {}
  return File(path).readAsBytes();
}

/// أول صف فيه كتابة من فوق + لون الورقة، عشان الورقة تتحط في المساحة البيضا اللي فوق الشعار.
Future<({int ink, Color paper})> topMargin(ui.Image img) async {
  final w = img.width;
  final h = img.height;
  final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bd == null) return (ink: 0, paper: Colors.white);
  final px = bd.buffer.asUint8List();
  final limit = (h * 0.45).floor();
  final x0 = (w * 0.05).floor();
  final x1 = (w * 0.95).floor();
  const step = 3;
  var ink = limit;
  for (var y = 0; y < limit; y++) {
    var dark = 0;
    var n = 0;
    for (var x = x0; x < x1; x += step) {
      final i = (y * w + x) * 4;
      final lum = (px[i] * 299 + px[i + 1] * 587 + px[i + 2] * 114) ~/ 1000;
      n++;
      if (lum < 150) dark++;
    }
    if (dark > n * 0.01) {
      ink = y;
      break;
    }
  }
  var paper = Colors.white;
  if (ink > 8) {
    final y = ink ~/ 2;
    var r = 0, g = 0, b = 0, n = 0;
    for (var x = x0; x < x1; x += step) {
      final i = (y * w + x) * 4;
      r += px[i];
      g += px[i + 1];
      b += px[i + 2];
      n++;
    }
    if (n > 0) paper = Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
  }
  return (ink: ink, paper: paper);
}

/// دمج الورقة (الاسم/الوحدة+المبنى/التاريخ) في المساحة البيضا فوق الباتش بخط كبير.
/// لو المساحة البيضا أكبر من اللازم بتتقص، ولو أصغر بتتزود من فوق. مفيش حاجة من الكتابة بتتغطى.
Future<Uint8List> composeBatch(String path, Session s) async {
  final bytes = await _shrink(path, width: 1400, quality: 80);
  final img = await decodeImage(bytes);
  final w = img.width.toDouble();
  final h = img.height.toDouble();
  final tag = await batchTag(w, s);
  final tImg = await decodeImage(tag.png);
  final m = await topMargin(img);
  final gap = w * 0.02; // مسافة بين الورقة وأول سطر في الباتش
  final padTop = w * 0.02; // مسافة فوق الورقة
  final cropTop = (m.ink - gap).clamp(0.0, h * 0.45).toDouble(); // الزيادة البيضا اللي بتتقص
  final band = padTop + tag.h + gap;
  final total = band + (h - cropTop);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, total));
  c.drawRect(Rect.fromLTWH(0, 0, w, total), Paint()..color = m.paper);
  c.drawImageRect(
      img, Rect.fromLTWH(0, cropTop, w, h - cropTop), Rect.fromLTWH(0, band, w, h - cropTop), Paint());
  c.drawImage(tImg, Offset((w - tag.w) / 2, padTop), Paint());
  final out = await rec.endRecording().toImage(w.toInt(), total.ceil());
  final bd = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  tImg.dispose();
  out.dispose();
  final jpg = await FlutterImageCompress.compressWithList(
    bd!.buffer.asUint8List(),
    minWidth: 4000,
    minHeight: 6000,
    quality: 80,
    format: CompressFormat.jpeg,
  );
  return jpg;
}

// ===== ورقة الإيصال (فوق الصورة) =====
const kTagFont = 0.05; // حجم خط الورقة (نسبة من عرض الصورة) - زوّد/قلّل الرقم لو عايز
const kTagTop = 0.03; // بُعد الورقة عن أعلى الصورة (نسبة من عرض الصورة)

class Tag {
  final Uint8List png;
  final double w, h;
  Tag(this.png, this.w, this.h);
}

// ===== ورقة الباتش (في المساحة البيضا فوق الشعار) =====
const kBatchFont = 0.09; // حجم الخط = تقريباً حجم شعار البنك (نسبة من عرض الصورة)

/// 3 أسطر زي الكتابة اليدوي: الاسم / الوحدة - المبنى / التاريخ. الخط بيصغر لوحده لو السطر عريض.
Future<Tag> batchTag(double w, Session s) async {
  final unitLine = s.building == null ? s.unit.name : '${s.unit.name} - ${s.building}';
  final texts = [s.name, unitLine, s.date];
  final dirs = [TextDirection.rtl, TextDirection.rtl, TextDirection.ltr];
  final maxTextW = w * 0.9;
  var fs = w * kBatchFont;
  late List<TextPainter> lines;
  for (var i = 0; i < 6; i++) {
    lines = [for (var k = 0; k < 3; k++) _tp(texts[k], fs, dirs[k])];
    final widest = lines.map((l) => l.width).reduce((a, b) => a > b ? a : b);
    if (widest <= maxTextW) break;
    fs *= maxTextW / widest * 0.98;
  }
  final pad = fs * 0.45;
  final gap = fs * 0.1;
  final textW = lines.map((l) => l.width).reduce((a, b) => a > b ? a : b);
  final cw = (textW + pad * 2).clamp(0.0, w * 0.96).toDouble();
  final ch = lines.fold<double>(0, (a, l) => a + l.height) + gap * 2 + pad * 2;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, cw, ch));
  final rr = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, cw, ch), Radius.circular(fs * 0.4));
  c.drawRRect(rr, Paint()..color = Colors.white);
  c.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.005
        ..color = Colors.black);
  var y = pad;
  for (final l in lines) {
    l.paint(c, Offset((cw - l.width) / 2, y));
    y += l.height + gap;
  }
  final img = await rec.endRecording().toImage(cw.ceil(), ch.ceil());
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return Tag(bd!.buffer.asUint8List(), cw, ch);
}

/// الورقة الصغيرة: سطر (الاسم | الوحدة - المبنى) وسطر (TID | التاريخ)
Future<Tag> receiptTag(double w, Session s) async {
  final fs = w * kTagFont;
  final unitLine = s.building == null ? s.unit.name : '${s.unit.name} - ${s.building}';
  final l1 = _tp('${s.name}  |  $unitLine', fs, TextDirection.rtl);
  final l2 = _tp('${_isoLtr('TID: ${s.unit.tid}')}  |  ${_isoLtr(s.date)}', fs, TextDirection.rtl);
  final pad = fs * 0.6;
  final gap = fs * 0.25;
  final textW = l1.width > l2.width ? l1.width : l2.width;
  final cw = (textW + pad * 2).clamp(0.0, w * 0.96).toDouble();
  final ch = l1.height + l2.height + gap + pad * 2;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, cw, ch));
  final rr = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, cw, ch), Radius.circular(fs * 0.5));
  c.drawRRect(rr, Paint()..color = Colors.white);
  c.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.004
        ..color = Colors.black);
  l1.paint(c, Offset((cw - l1.width) / 2, pad));
  l2.paint(c, Offset((cw - l2.width) / 2, pad + l1.height + gap));
  final img = await rec.endRecording().toImage(cw.ceil(), ch.ceil());
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return Tag(bd!.buffer.asUint8List(), cw, ch);
}

/// صورة الإيصال + الورقة مرسومة فوقها (في النص من فوق).
Future<({Uint8List bytes, double ratio})> composeReceipt(String path, Session s) async {
  final bytes = await _shrink(path, width: 1280, quality: 70);
  final img = await decodeImage(bytes);
  final w = img.width.toDouble();
  final h = img.height.toDouble();
  final tag = await receiptTag(w, s);
  final tImg = await decodeImage(tag.png);
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  c.drawImage(img, Offset.zero, Paint());
  c.drawImage(tImg, Offset((w - tag.w) / 2, w * kTagTop), Paint());
  final out = await rec.endRecording().toImage(w.toInt(), h.toInt());
  final bd = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  tImg.dispose();
  out.dispose();
  final jpg = await FlutterImageCompress.compressWithList(
    bd!.buffer.asUint8List(),
    minWidth: 4000,
    minHeight: 6000,
    quality: 65,
    format: CompressFormat.jpeg,
  );
  return (bytes: jpg, ratio: h / w);
}

/// PDF إيصالات فقط: كل صفحة = صورة الإيصال وعليها الورقة من فوق.
Future<File> buildReceiptsPdf(Session s, List<String> receipts) async {
  final doc = pw.Document();
  const pageW = 595.0;
  // صفحة واحدة في كل مرة عشان الذاكرة (تليفونات ضعيفة)
  for (final path in receipts) {
    final r = await composeReceipt(path, s);
    final pageH = pageW * r.ratio;
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(pageW, pageH),
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Image(pw.MemoryImage(r.bytes), width: pageW, height: pageH),
    ));
  }
  final dir = await Store.dir();
  final file = File('${dir.path}/${s.pdfName}.pdf');
  await file.writeAsBytes(await doc.save());
  return file;
}

// ===== التخزين =====
String _dayKey() {
  final n = DateTime.now();
  return '${n.year}-${n.month}-${n.day}';
}

class SendEntry {
  final DateTime time;
  final String kind; // batch | receipts
  final String file;
  final int pages;
  SendEntry(this.time, this.kind, this.file, this.pages);
}

class Store {
  static const pdfLife = Duration(hours: 24);
  static Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  static Future<Directory> dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/a2r');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<void> del(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // --- صورة الباتش اللي لسه متبعتتش ---
  static Future<String?> batchImg() async {
    final v = (await _p).getString('batchImg');
    if (v == null || !File(v).existsSync()) return null;
    return v;
  }

  static Future<void> setBatchImg(String path) async {
    final p = await _p;
    final old = p.getString('batchImg');
    if (old != null && old != path) await del(old);
    await p.setString('batchImg', path);
  }

  static Future<void> clearBatchImg() async {
    final p = await _p;
    final old = p.getString('batchImg');
    if (old != null) await del(old);
    await p.remove('batchImg');
  }

  static Future<void> afterBatchSent(String fileName) async {
    await clearBatchImg();
    await setFlag('batch');
    await addLog('batch', fileName, 1);
  }

  // --- صور الإيصالات اللي لسه متبعتتش ---
  static Future<void> setDraft(List<String> l) async =>
      (await _p).setStringList('draft', l);

  static Future<List<String>> pdfImgs() async =>
      (await _p).getStringList('pdfImgs') ?? [];

  static Future<List<String>> draft() async {
    final l = (await _p).getStringList('draft') ?? [];
    return l.where((e) => File(e).existsSync()).toList();
  }

  static Future<void> addToDraft(String path) async {
    final l = await draft();
    l.add(path);
    await (await _p).setStringList('draft', l);
  }

  static Future<void> removeFromDraft(String path) async {
    final l = await draft();
    l.remove(path);
    await del(path);
    await (await _p).setStringList('draft', l);
  }

  /// استبدال صورة في المسودة بصورة تانية في نفس المكان.
  static Future<void> replaceInDraft(String old, String neu) async {
    final l = await draft();
    final i = l.indexOf(old);
    if (i >= 0) {
      l[i] = neu;
    } else {
      l.add(neu);
    }
    if (old != neu) await del(old);
    await (await _p).setStringList('draft', l);
  }

  static Future<void> clearDraft() async {
    for (final e in await draft()) {
      await del(e);
    }
    await (await _p).setStringList('draft', []);
  }

  // --- ملف الـ PDF (يفضل 24 ساعة) ---
  static Future<({File file, DateTime time})?> pdf() async {
    final p = await _p;
    final path = p.getString('pdfPath');
    final t = p.getInt('pdfTime');
    if (path == null || t == null) return null;
    final time = DateTime.fromMillisecondsSinceEpoch(t);
    final age = DateTime.now().difference(time);
    if (age > pdfLife || !File(path).existsSync()) {
      await clearPdf();
      return null;
    }
    return (file: File(path), time: time);
  }

  static Future<void> setPdf(File f, List<String> imgs) async {
    final p = await _p;
    final old = p.getString('pdfPath');
    if (old != null && old != f.path) await del(old);
    await p.setString('pdfPath', f.path);
    await p.setInt('pdfTime', DateTime.now().millisecondsSinceEpoch);
    await p.setStringList('pdfImgs', imgs);
  }

  static Future<void> clearPdf() async {
    final p = await _p;
    final old = p.getString('pdfPath');
    if (old != null) await del(old);
    await p.remove('pdfPath');
    await p.remove('pdfTime');
    await p.remove('pdfImgs');
  }

  /// بعد إرسال الـ PDF: تتمسح الصور اللي دخلت فيه، والـ PDF نفسه يفضل لحد 24 ساعة.
  static Future<void> afterPdfSent() async {
    final p = await _p;
    final used = p.getStringList('pdfImgs') ?? [];
    final pdfPath = p.getString('pdfPath');
    await addLog('receipts', pdfPath == null ? 'PDF' : pdfPath.split('/').last, used.length);
    final left = await draft();
    for (final u in used) {
      await del(u);
      left.remove(u);
    }
    await p.setStringList('draft', left);
    await p.remove('pdfImgs');
    await setFlag('receipts');
  }

  // --- سجل الإرسال (آخر 7 أيام) ---
  static const logDays = 7;

  static Future<void> addLog(String kind, String file, int pages) async {
    final p = await _p;
    final l = p.getStringList('sendLog') ?? [];
    l.add(jsonEncode({
      't': DateTime.now().millisecondsSinceEpoch,
      'k': kind,
      'f': file,
      'n': pages,
    }));
    await p.setStringList('sendLog', l);
  }

  /// بيرجّع السجل (الأحدث الأول) وبيمسح اللي أقدم من 7 أيام.
  static Future<List<SendEntry>> log() async {
    final p = await _p;
    final cutoff = DateTime.now().subtract(const Duration(days: logDays)).millisecondsSinceEpoch;
    final keep = <String>[];
    final out = <SendEntry>[];
    for (final raw in p.getStringList('sendLog') ?? const <String>[]) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        final t = m['t'] as int;
        if (t < cutoff) continue;
        keep.add(raw);
        out.add(SendEntry(DateTime.fromMillisecondsSinceEpoch(t), m['k'] as String,
            m['f'] as String, (m['n'] as int?) ?? 1));
      } catch (_) {}
    }
    await p.setStringList('sendLog', keep);
    out.sort((a, b) => b.time.compareTo(a.time));
    return out;
  }

  // --- علامة ✓ (بتتصفّر كل يوم جديد) ---
  static Future<bool> flag(String k) async {
    final p = await _p;
    if (p.getString('flagDay') != _dayKey()) {
      await p.setString('flagDay', _dayKey());
      await p.setBool('f_batch', false);
      await p.setBool('f_receipts', false);
    }
    return p.getBool('f_$k') ?? false;
  }

  static Future<void> setFlag(String k) async {
    await flag(k);
    await (await _p).setBool('f_$k', true);
  }

  /// مسح أي ملفات مؤقتة مش تابعة لصور مسودة أو PDF شغّال.
  static Future<void> cleanup() async {
    final keep = <String>{...await draft()};
    final bi = await batchImg();
    if (bi != null) keep.add(bi);
    final pdfPath = (await pdf())?.file.path;
    if (pdfPath != null) keep.add(pdfPath);
    await for (final e in (await dir()).list()) {
      if (e is File && !keep.contains(e.path)) await del(e.path);
    }
  }
}

/// نسخ الصورة من مكان الماسح المؤقت لمكان ثابت (مضغوطة).
Future<String> persistImage(String src, String name) async {
  final bytes = await _shrink(src, width: 1600, quality: 80);
  final f = File('${(await Store.dir()).path}/$name');
  await f.writeAsBytes(bytes);
  return f.path;
}

// ===== الأذونات والكاميرا والمشاركة =====
/// بيتطلب أول ما التطبيق يفتح عشان الموظف يشوف طلب الإذن.
Future<void> requestAllPermissions() async {
  await Permission.camera.request();
  final ph = await Permission.photos.request();
  if (!ph.isGranted && !ph.isLimited) {
    await Permission.storage.request();
  }
}

Future<bool> askYesNo(BuildContext context, String title, String body,
    {String yes = 'تمام', String no = 'لا'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(no)),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
        ],
      ),
    ),
  );
  return r ?? false;
}

Future<bool> ensureCamera(BuildContext context) async {
  var st = await Permission.camera.status;
  if (st.isGranted) return true;
  st = await Permission.camera.request();
  if (st.isGranted) return true;
  if (!context.mounted) return false;
  final go = await askYesNo(context, 'محتاج إذن الكاميرا',
      'من غير الإذن التطبيق مش هيقدر يصوّر. افتح الإعدادات > الأذونات > الكاميرا واختار "السماح".',
      yes: 'افتح الإعدادات', no: 'إلغاء');
  if (go) await openAppSettings();
  return false;
}

Future<List<String>> simplePick(BuildContext context, {bool multi = false}) async {
  final src = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (c) => SafeArea(
      child: Wrap(children: [
        ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('الكاميرا'),
            onTap: () => Navigator.pop(c, ImageSource.camera)),
        ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('المعرض'),
            onTap: () => Navigator.pop(c, ImageSource.gallery)),
      ]),
    ),
  );
  if (src == null) return [];
  try {
    final picker = ImagePicker();
    if (src == ImageSource.gallery && multi) {
      final xs = await picker.pickMultiImage(maxWidth: 2000, imageQuality: 85);
      return xs.map((e) => e.path).toList();
    }
    final x = await picker.pickImage(source: src, maxWidth: 2000, imageQuality: 85);
    return x == null ? [] : [x.path];
  } catch (_) {
    if (context.mounted) snack(context, 'تعذر فتح الكاميرا أو المعرض');
    return [];
  }
}

/// كل التصوير (كاميرا أو معرض) بيعدي على ماسح المستندات (قص وتحسين).
/// لو الماسح مش شغال على الموبايل بيتحول للكاميرا العادية تلقائياً.
/// داخل الماسح فيه أيقونة المعرض لاستيراد صور (لحد [limit] صورة).
Future<List<String>> scanImages(BuildContext context, int limit) async {
  if (!await ensureCamera(context)) return [];
  if (!context.mounted) return [];
  final scanner = DocumentScanner(
    options: DocumentScannerOptions(
      mode: ScannerMode.full,
      pageLimit: limit,
      isGalleryImport: true,
    ),
  );
  try {
    final r = await scanner.scanDocument();
    return List<String>.from(r.images ?? const []);
  } catch (e) {
    if (e.toString().toLowerCase().contains('cancel')) return [];
    if (!context.mounted) return [];
    snack(context, 'الماسح مش شغال على الموبايل ده، هنفتح الكاميرا العادية');
    return simplePick(context, multi: limit > 1);
  } finally {
    scanner.close();
  }
}

/// بيفتح قايمة المشاركة. لو النظام مرجعش النتيجة بنسأل الموظف.
Future<bool> shareFiles(BuildContext context, List<String> paths) async {
  final r = await Share.shareXFiles(paths.map((p) => XFile(p)).toList());
  if (r.status == ShareResultStatus.success) return true;
  if (r.status == ShareResultStatus.dismissed) return false;
  if (!context.mounted) return false;
  return askYesNo(context, 'تم الإرسال؟', 'لو بعت الملف فعلاً اضغط "تم".',
      yes: 'تم', no: 'لا');
}

/// تجهيز صورة الباتش (مع الشريط) باسم رقم الوحدة وإرسالها.
Future<bool> sendBatchFile(BuildContext context, Session s, String img) async {
  final bytes = await composeBatch(img, s);
  final out = File('${(await Store.dir()).path}/${s.batchName}.jpg');
  await out.writeAsBytes(bytes);
  if (!context.mounted) return false;
  final ok = await shareFiles(context, [out.path]);
  if (ok) await Store.afterBatchSent('${s.batchName}.jpg');
  return ok;
}

/// عرض ملء الشاشة بتكبير بالأصابع.
class ZoomPage extends StatelessWidget {
  final Widget child;
  const ZoomPage({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: InteractiveViewer(
        constrained: false,
        minScale: 0.5,
        maxScale: 6,
        child: SizedBox(width: w, child: child),
      ),
    );
  }
}

/// صورة إيصال والورقة فوقها (نفس شكل الـ PDF).
class ReceiptPreview extends StatelessWidget {
  final String path;
  final Tag? tag;
  final int? cacheWidth;
  final double top; // بُعد الورقة عن أعلى الصورة (نسبة من العرض)
  const ReceiptPreview(
      {super.key, required this.path, this.tag, this.cacheWidth, this.top = kTagTop});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (ctx, cons) {
        final cw = cons.maxWidth;
        return Stack(children: [
          Image.file(File(path), width: double.infinity, fit: BoxFit.fitWidth, cacheWidth: cacheWidth),
          if (tag != null)
            Positioned(
              top: cw * top,
              left: 0,
              right: 0,
              child: Center(child: Image.memory(tag!.png, width: cw * tag!.w / 1000)),
            ),
        ]);
      });
}

void snack(BuildContext context, String m) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

// ===== التطبيق =====
void main() => runApp(const A2RApp());

// ===== الشكل =====
const kBrand = Color(0xFF0B5FA5);
const kBrandDark = Color(0xFF083E70);
const kInk = Color(0xFF1B2733);

/// رقم الإصدار (بيتحط أوتوماتيك من GitHub وقت البناء، مثال: 1.12)
const kVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'تجريبي');
String get kVersionLabel => 'الإصدار $kVersion';

InputDecoration fieldDec(String label, IconData icon) => InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: kBrand),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: Colors.blueGrey.shade100)),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kBrand, width: 2)),
    );

/// شعار A2R بخلفية متدرجة فوق شاشة الدخول.
class BrandHeader extends StatelessWidget {
  const BrandHeader({super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 26),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [kBrand, kBrandDark]),
          borderRadius: BorderRadius.circular(26),
          boxShadow: [BoxShadow(color: kBrand.withAlpha(70), blurRadius: 18, offset: const Offset(0, 8))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: Colors.white.withAlpha(40), shape: BoxShape.circle),
            child: const Icon(Icons.receipt_long, color: Colors.white, size: 34),
          ),
          const SizedBox(height: 10),
          const Text('A2R',
              style: TextStyle(
                  fontSize: 46, fontWeight: FontWeight.w900, letterSpacing: 6, color: Colors.white, height: 1.1)),
          const SizedBox(height: 4),
          Text('تجميع إيصالات الدفع', style: TextStyle(fontSize: 14, color: Colors.white.withAlpha(210))),
        ]),
      );
}

class A2RApp extends StatelessWidget {
  const A2RApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'A2R',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: kBrand),
          scaffoldBackgroundColor: const Color(0xFFF2F6FB),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const LoginScreen(),
      );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  String? name;
  Unit? unit;
  String? building;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final n = p.getString('name');
    final u = p.getString('unit');
    final b = p.getString('building');
    setState(() {
      if (kNames.contains(n)) name = n;
      final found = kUnits.where((x) => x.name == u);
      if (found.isNotEmpty) {
        unit = found.first;
        if (unit!.buildings.length > 1 && unit!.buildings.contains(b)) building = b;
      }
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('name', name ?? '');
    await p.setString('unit', unit?.name ?? '');
    await p.setString('building', building ?? '');
  }

  bool get _needsBuilding => unit != null && unit!.buildings.length > 1;
  bool get _ready => name != null && unit != null && (!_needsBuilding || building != null);

  void _start() {
    // مبنى واحد -> يتاخد أوتوماتيك. مفيش مباني -> null
    final b = _needsBuilding
        ? building
        : (unit!.buildings.length == 1 ? unit!.buildings.first : null);
    _save();
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => MainScreen(session: Session(name!, unit!, b))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const SizedBox(height: 8),
            const BrandHeader(),
            const SizedBox(height: 28),
            DropdownButtonFormField<String>(
              value: name,
              isExpanded: true,
              decoration: fieldDec('الاسم', Icons.person_outline),
              items: kNames.map((n) => DropdownMenuItem(value: n, child: Text(n))).toList(),
              onChanged: (v) => setState(() => name = v),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<Unit>(
              value: unit,
              isExpanded: true,
              decoration: fieldDec('الوحدة', Icons.store_mall_directory_outlined),
              items: kUnits.map((u) => DropdownMenuItem(value: u, child: Text(u.name))).toList(),
              onChanged: (v) => setState(() {
                unit = v;
                building = null;
              }),
            ),
            if (_needsBuilding) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey(unit!.name),
                value: building,
                isExpanded: true,
                decoration: fieldDec('المبنى', Icons.apartment),
                items: unit!.buildings
                    .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                    .toList(),
                onChanged: (v) => setState(() => building = v),
              ),
            ],
            const Spacer(),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                onPressed: _ready ? _start : null,
                child: const Text('ابدأ', style: TextStyle(fontSize: 20)),
              ),
            ),
            const SizedBox(height: 10),
            Text(kVersionLabel,
                style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade400)),
          ]),
        ),
      ),
    );
  }
}

// ===== الشاشة الرئيسية =====
class MainScreen extends StatefulWidget {
  final Session session;
  const MainScreen({super.key, required this.session});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  List<String> draft = [];
  String? batchImg;
  ({File file, DateTime time})? pdf;
  bool batchSent = false;
  bool receiptsSent = false;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _init() async {
    await requestAllPermissions();
    await Store.cleanup();
    await _reload();
  }

  Future<void> _reload() async {
    final d = await Store.draft();
    final f = await Store.pdf();
    final bi = await Store.batchImg();
    final b = await Store.flag('batch');
    final r = await Store.flag('receipts');
    if (!mounted) return;
    setState(() {
      draft = d;
      pdf = f;
      batchImg = bi;
      batchSent = b;
      receiptsSent = r;
    });
  }

  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    _reload();
  }

  Future<void> _sendBatch() async {
    final b = batchImg;
    if (b == null) return;
    setState(() => busy = true);
    try {
      final ok = await sendBatchFile(context, widget.session, b);
      if (ok) await _reload();
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _trashBatch() async {
    if (!await askYesNo(context, 'مسح صورة الباتش؟', 'الصورة هتتمسح من التطبيق.',
        yes: 'امسح', no: 'إلغاء')) {
      return;
    }
    await Store.clearBatchImg();
    await _reload();
  }

  Future<void> _openPdf() async {
    final f = pdf;
    if (f == null) return;
    final r = await OpenFilex.open(f.file.path);
    if (r.type != ResultType.done && mounted) {
      snack(context, 'مفيش تطبيق يفتح ملفات PDF على التليفون');
    }
  }

  Future<void> _sendPdf() async {
    final f = pdf;
    if (f == null) return;
    final ok = await shareFiles(context, [f.file.path]);
    if (ok) {
      await Store.afterPdfSent();
      await _reload();
    }
  }

  Future<void> _trashPdf() async {
    if (!await askYesNo(context, 'مسح ملف الـ PDF؟', 'الملف هيتمسح من التطبيق.',
        yes: 'امسح', no: 'إلغاء')) {
      return;
    }
    await Store.clearPdf();
    await _reload();
  }

  Future<void> _trashDraft() async {
    if (!await askYesNo(context, 'مسح صور الإيصالات؟', 'كل الصور اللي لسه متبعتتش هتتمسح.',
        yes: 'امسح', no: 'إلغاء')) {
      return;
    }
    await Store.clearDraft();
    await _reload();
  }

  Widget _big(IconData icon, String label, bool done, VoidCallback onTap,
          {Color color = kBrand}) =>
      SizedBox(
        height: 150,
        child: Material(
          color: Colors.white,
          elevation: 3,
          shadowColor: color.withAlpha(90),
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onTap,
            child: Stack(children: [
              Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(color: color.withAlpha(30), shape: BoxShape.circle),
                    child: Icon(icon, size: 36, color: color),
                  ),
                  const SizedBox(height: 12),
                  Text(label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kInk)),
                ]),
              ),
              if (done)
                const Positioned(
                  top: 10,
                  left: 10,
                  child: CircleAvatar(
                      radius: 13,
                      backgroundColor: Colors.green,
                      child: Icon(Icons.check, color: Colors.white, size: 18)),
                ),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final unitLine = s.building == null ? s.unit.name : '${s.unit.name} - ${s.building}';
    final pf = pdf;
    final bi = batchImg;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('A2R',
            style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 4, color: kBrandDark)),
        actions: [
          IconButton(
            tooltip: 'سجل الإرسال',
            icon: const Icon(Icons.history, color: kBrandDark),
            onPressed: () => _open(const SendLogScreen()),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (busy) const LinearProgressIndicator(),
        Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [kBrand, kBrandDark]),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [BoxShadow(color: kBrand.withAlpha(70), blurRadius: 16, offset: const Offset(0, 6))],
          ),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white),
            child: IconTheme(
            data: const IconThemeData(color: Colors.white),
            child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.person),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(s.name,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.location_on_outlined),
                const SizedBox(width: 8),
                Expanded(child: Text(unitLine, style: const TextStyle(fontSize: 16))),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.calendar_today),
                const SizedBox(width: 8),
                Text(s.date,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                const Expanded(
                    child: Text('(تاريخ التليفون - اتأكد إنه صح)',
                        style: TextStyle(fontSize: 12, color: Colors.white70))),
              ]),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.switch_account),
                  label: const Text('تغيير الحساب'),
                ),
              ),
            ]),
          ),
          ),
          ),
        ),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(
              child: _big(Icons.receipt_long, 'الباتش', batchSent,
                  () => _open(BatchScreen(session: s)))),
          const SizedBox(width: 12),
          Expanded(
              child: _big(Icons.payments, 'إيصالات الدفع', receiptsSent,
                  () => _open(ReceiptsScreen(session: s)),
                  color: const Color(0xFF00897B))),
        ]),
        if (draft.isNotEmpty || pf != null || bi != null) ...[
          const SizedBox(height: 24),
          const Text('ملفاتي (لسه متبعتتش)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (bi != null)
            Card(
              child: ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(File(bi), width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 150),
                ),
                title: Text('الباتش - ${s.batchName}.jpg'),
                subtitle: const Text('اضغط للمعاينة'),
                onTap: () => _open(BatchScreen(session: s)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      tooltip: 'إرسال',
                      icon: const Icon(Icons.send),
                      onPressed: busy ? null : _sendBatch),
                  IconButton(
                      tooltip: 'مسح',
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: busy ? null : _trashBatch),
                ]),
              ),
            ),
          if (draft.isNotEmpty)
            Card(
              child: ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(File(draft.first), width: 48, height: 48, fit: BoxFit.cover, cacheWidth: 150),
                ),
                title: Text('إيصالات الدفع (${draft.length} صورة)'),
                subtitle: const Text('اضغط للمعاينة أو لتكمل التصوير'),
                onTap: () => _open(ReceiptsScreen(session: s)),
                trailing: IconButton(
                    tooltip: 'مسح',
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: _trashDraft),
              ),
            ),
          if (pf != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.picture_as_pdf, size: 36, color: Colors.red),
                title: Text(pf.file.path.split('/').last, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    'اضغط لفتحه - يتمسح بعد ${(24 - DateTime.now().difference(pf.time).inHours).clamp(1, 24)} ساعة'),
                onTap: _openPdf,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      tooltip: 'إرسال',
                      icon: const Icon(Icons.send),
                      onPressed: _sendPdf),
                  IconButton(
                      tooltip: 'مسح',
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: _trashPdf),
                ]),
              ),
            ),
        ],
        const SizedBox(height: 28),
        Center(
          child: Text('A2R - $kVersionLabel',
              style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade400)),
        ),
        const SizedBox(height: 8),
      ]),
    );
  }
}

// ===== سجل الإرسال =====
String _hm(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'ص' : 'م'}';
}

String _dayTitle(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(t.year, t.month, t.day);
  final diff = today.difference(d).inDays;
  final date = '${t.day}/${t.month}/${t.year}';
  if (diff == 0) return 'النهاردة - $date';
  if (diff == 1) return 'امبارح - $date';
  return date;
}

class SendLogScreen extends StatefulWidget {
  const SendLogScreen({super.key});
  @override
  State<SendLogScreen> createState() => _SendLogScreenState();
}

class _SendLogScreenState extends State<SendLogScreen> {
  List<SendEntry>? items;

  @override
  void initState() {
    super.initState();
    Store.log().then((l) {
      if (mounted) setState(() => items = l);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = items;
    final children = <Widget>[];
    String? lastDay;
    for (final e in l ?? const <SendEntry>[]) {
      final day = _dayTitle(e.time);
      if (day != lastDay) {
        lastDay = day;
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
          child: Text(day, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: kBrandDark)),
        ));
      }
      final isBatch = e.kind == 'batch';
      children.add(Card(
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: (isBatch ? kBrand : const Color(0xFF00897B)).withAlpha(30),
            child: Icon(isBatch ? Icons.receipt_long : Icons.payments,
                color: isBatch ? kBrand : const Color(0xFF00897B)),
          ),
          title: Text(isBatch ? 'الباتش' : 'إيصالات الدفع (${e.pages} صفحة)',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(e.file, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: Text(_hm(e.time), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        ),
      ));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('سجل الإرسال')),
      body: l == null
          ? const Center(child: CircularProgressIndicator())
          : l.isEmpty
              ? const Center(child: Text('مفيش حاجة اتبعتت في آخر 7 أيام', style: TextStyle(fontSize: 16)))
              : ListView(padding: const EdgeInsets.all(12), children: [
                  ...children,
                  const SizedBox(height: 16),
                  Center(
                    child: Text('السجل بيحتفظ بآخر 7 أيام بس',
                        style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade400)),
                  ),
                  const SizedBox(height: 8),
                ]),
    );
  }
}

// ===== شاشة الباتش =====
class BatchScreen extends StatefulWidget {
  final Session session;
  const BatchScreen({super.key, required this.session});
  @override
  State<BatchScreen> createState() => _BatchScreenState();
}

class _BatchScreenState extends State<BatchScreen> {
  String? img;
  Uint8List? composed; // الصورة النهائية زي ما هتتبعت
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// لو فيه صورة باتش محفوظة بنعرضها للمعاينة، وإلا بنفتح الماسح.
  Future<void> _init() async {
    final cur = await Store.batchImg();
    if (!mounted) return;
    if (cur != null) {
      final st = await composeBatch(cur, widget.session);
      if (!mounted) return;
      setState(() {
        img = cur;
        composed = st;
      });
    } else {
      _capture();
    }
  }

  Future<void> _capture() async {
    final r = await scanImages(context, 1);
    if (!mounted) return;
    if (r.isEmpty) {
      if (img == null) Navigator.pop(context);
      return;
    }
    setState(() => busy = true);
    try {
      final path = await persistImage(r.first, 'batch_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await Store.setBatchImg(path); // بتمسح القديمة
      final st = await composeBatch(path, widget.session);
      if (!mounted) return;
      setState(() {
        img = path;
        composed = st;
      });
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _send() async {
    setState(() => busy = true);
    try {
      final ok = await sendBatchFile(context, widget.session, img!);
      if (ok && mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _content({int? cacheWidth}) =>
      Image.memory(composed!, width: double.infinity, fit: BoxFit.fitWidth);

  @override
  Widget build(BuildContext context) {
    final ready = img != null && composed != null;
    return Scaffold(
      appBar: AppBar(title: const Text('الباتش')),
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: GestureDetector(
                    onTap: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => ZoomPage(child: _content()))),
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
                      child: _content(cacheWidth: 1000),
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('اضغط على الصورة لتكبيرها',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: busy ? null : _capture,
                        icon: const Icon(Icons.refresh),
                        label: const Text('إعادة تصوير'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: busy ? null : _send,
                        icon: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.send),
                        label: const Text('إرسال'),
                      ),
                    ),
                  ]),
                ),
              ),
            ]),
    );
  }
}

// ===== شاشة إيصالات الدفع =====
class ReceiptsScreen extends StatefulWidget {
  final Session session;
  const ReceiptsScreen({super.key, required this.session});
  @override
  State<ReceiptsScreen> createState() => _ReceiptsScreenState();
}

class _ReceiptsScreenState extends State<ReceiptsScreen> {
  List<String> imgs = [];
  Tag? tag;
  File? built; // PDF اتعمل من نفس الصور الحالية
  bool busy = false;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await Store.draft();
    final t = await receiptTag(1000, widget.session);
    final f = await Store.pdf();
    final used = await Store.pdfImgs();
    File? b;
    if (f != null && d.isNotEmpty && used.length == d.length) {
      var same = true;
      for (var i = 0; i < d.length; i++) {
        if (d[i] != used[i]) same = false;
      }
      if (same) b = f.file;
    }
    if (!mounted) return;
    setState(() {
      imgs = d;
      tag = t;
      built = b;
      loaded = true;
    });
    if (d.isEmpty) _add();
  }

  /// تصوير صورة واحدة بالماسح.
  Future<void> _add() async {
    final r = await scanImages(context, 1);
    if (r.isEmpty || !mounted) return;
    await _saveAll(r);
  }

  /// صور من المعرض (بالماسح كمان، لحد 100 صورة).
  Future<void> _addGallery() async {
    final r = await scanImages(context, 100);
    if (r.isEmpty || !mounted) return;
    await _saveAll(r);
  }

  Future<void> _saveAll(List<String> r) async {
    setState(() => busy = true);
    try {
      for (final p in r) {
        final saved = await persistImage(p, 'r_${DateTime.now().microsecondsSinceEpoch}.jpg');
        await Store.addToDraft(saved);
        imgs.add(saved);
      }
      built = null;
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _remove(int i) async {
    if (!await askYesNo(context, 'مسح الصورة؟', 'الصورة دي هتتمسح.', yes: 'امسح', no: 'إلغاء')) {
      return;
    }
    await Store.removeFromDraft(imgs[i]);
    if (!mounted) return;
    setState(() {
      imgs.removeAt(i);
      built = null;
    });
  }

  Future<void> _move(int i, int delta) async {
    final j = i + delta;
    if (j < 0 || j >= imgs.length) return;
    setState(() {
      final x = imgs.removeAt(i);
      imgs.insert(j, x);
      built = null;
    });
    await Store.setDraft(imgs);
  }

  /// تدوير الصفحة 90 درجة (في اتجاه عقارب الساعة).
  Future<void> _rotate(int i) async {
    final old = imgs[i];
    setState(() => busy = true);
    try {
      final out = await FlutterImageCompress.compressWithFile(
        old,
        minWidth: 4000,
        minHeight: 4000,
        quality: 80,
        rotate: 90,
        format: CompressFormat.jpeg,
        keepExif: false,
      );
      if (out == null) throw 'تعذر تدوير الصورة';
      // اسم جديد عشان الصورة القديمة متفضلش في الكاش
      final f = File('${(await Store.dir()).path}/r_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await f.writeAsBytes(out);
      await Store.replaceInDraft(old, f.path);
      if (!mounted) return;
      setState(() {
        final k = imgs.indexOf(old);
        if (k >= 0) imgs[k] = f.path;
        built = null;
      });
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// استبدال صفحة واحدة بصورة جديدة (من غير ما تتمسح وتتصور من الأول).
  Future<void> _replace(int i) async {
    final old = imgs[i];
    final r = await scanImages(context, 1);
    if (r.isEmpty || !mounted) return;
    setState(() => busy = true);
    try {
      final saved = await persistImage(r.first, 'r_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await Store.replaceInDraft(old, saved);
      if (!mounted) return;
      setState(() {
        final k = imgs.indexOf(old);
        if (k >= 0) imgs[k] = saved;
        built = null;
      });
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _create() async {
    setState(() => busy = true);
    try {
      final f = await buildReceiptsPdf(widget.session, imgs);
      await Store.setPdf(f, List.of(imgs));
      if (mounted) setState(() => built = f);
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _send() async {
    final ok = await shareFiles(context, [built!.path]);
    if (ok) {
      await Store.afterPdfSent();
      if (mounted) Navigator.pop(context);
    }
  }

  Widget _mini(IconData icon, VoidCallback? onTap, {Color color = Colors.black54}) => GestureDetector(
        onTap: onTap,
        child: CircleAvatar(
            radius: 16, backgroundColor: color, child: Icon(icon, size: 20, color: Colors.white)),
      );

  Widget _pill(IconData icon, String label, VoidCallback? onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
              color: onTap == null ? Colors.black26 : Colors.black54,
              borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 18, color: Colors.white),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ]),
        ),
      );

  Widget _item(int i) => Container(
        decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
        child: Stack(children: [
          GestureDetector(
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => ZoomPage(child: ReceiptPreview(path: imgs[i], tag: tag)))),
            child: ReceiptPreview(path: imgs[i], tag: tag, cacheWidth: 900),
          ),
          Positioned(
              top: 6,
              left: 6,
              child: _mini(Icons.close, busy ? null : () => _remove(i), color: Colors.red)),
          Positioned(
            top: 6,
            right: 6,
            child: Row(children: [
              if (i > 0) _mini(Icons.arrow_upward, busy ? null : () => _move(i, -1)),
              const SizedBox(width: 4),
              if (i < imgs.length - 1) _mini(Icons.arrow_downward, busy ? null : () => _move(i, 1)),
            ]),
          ),
          Positioned(
            bottom: 6,
            right: 6,
            child: Row(children: [
              _pill(Icons.rotate_right, 'تدوير', busy ? null : () => _rotate(i)),
              const SizedBox(width: 6),
              _pill(Icons.camera_alt, 'استبدال', busy ? null : () => _replace(i)),
            ]),
          ),
          Positioned(
            bottom: 6,
            left: 6,
            child: CircleAvatar(
                radius: 14,
                backgroundColor: Colors.black54,
                child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 13))),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('إيصالات الدفع (${imgs.length})')),
      body: Column(children: [
        Expanded(
          child: !loaded
              ? const Center(child: CircularProgressIndicator())
              : imgs.isEmpty
                  ? Center(
                      child: busy
                          ? const CircularProgressIndicator()
                          : const Text('لسه مفيش صور', style: TextStyle(fontSize: 16)))
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: imgs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (_, i) => _item(i),
                    ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : _add,
                    icon: const Icon(Icons.add_a_photo),
                    label: const Text('تصوير'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : _addGallery,
                    icon: const Icon(Icons.photo_library),
                    label: const Text('من المعرض'),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: (busy || imgs.isEmpty) ? null : (built == null ? _create : _send),
                  icon: busy
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(built == null ? Icons.picture_as_pdf : Icons.send),
                  label: Text(built == null ? 'إنشاء PDF' : 'إرسال'),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
