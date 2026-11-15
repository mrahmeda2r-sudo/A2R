import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:image_picker/image_picker.dart';
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

/// دمج الشريط (الاسم/الوحدة/المبنى/التاريخ) فوق صورة الباتش في صورة JPEG واحدة.
Future<Uint8List> composeBatch(String path, Session s) async {
  final bytes = await _shrink(path, width: 1400, quality: 80);
  final img = await decodeImage(bytes);
  final w = img.width.toDouble();
  final h = img.height.toDouble();
  final strip = await batchStrip(w, s);
  final sImg = await decodeImage(strip.png);
  final total = sImg.height.toDouble() + h;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, total));
  c.drawImage(sImg, Offset.zero, Paint());
  c.drawImage(img, Offset(0, sImg.height.toDouble()), Paint());
  final out = await rec.endRecording().toImage(w.toInt(), total.ceil());
  final bd = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  sImg.dispose();
  out.dispose();
  final png = bd!.buffer.asUint8List();
  final jpg = await FlutterImageCompress.compressWithList(
    png,
    minWidth: 4000,
    minHeight: 6000,
    quality: 80,
    format: CompressFormat.jpeg,
  );
  return jpg;
}

/// PDF إيصالات فقط: كل صفحة = الورقة الصغيرة + صورة الإيصال.
Future<File> buildReceiptsPdf(Session s, List<String> receipts) async {
  final doc = pw.Document();
  const pageW = 595.0;
  // صفحة واحدة في كل مرة عشان الذاكرة (تليفونات ضعيفة)
  for (final path in receipts) {
    final bytes = await _shrink(path, quality: 60);
    final img = await decodeImage(bytes);
    final w = img.width.toDouble();
    final h = img.height.toDouble();
    img.dispose();
    final label = await receiptLabel(w, s);
    final labelH = pageW * label.ratio;
    final imgH = pageW * h / w;
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(pageW, labelH + imgH),
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Column(children: [
        pw.Image(pw.MemoryImage(label.png), width: pageW, height: labelH),
        pw.Image(pw.MemoryImage(bytes), width: pageW, height: imgH),
      ]),
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

  // --- صور الإيصالات اللي لسه متبعتتش ---
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
    final left = await draft();
    for (final u in used) {
      await del(u);
      left.remove(u);
    }
    await p.setStringList('draft', left);
    await p.remove('pdfImgs');
    await setFlag('receipts');
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

Future<List<String>> simplePick(BuildContext context) async {
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
    final x = await ImagePicker().pickImage(source: src, maxWidth: 2000, imageQuality: 85);
    return x == null ? [] : [x.path];
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('تعذر فتح الكاميرا أو المعرض')));
    }
    return [];
  }
}

/// تصوير صورة واحدة (ماسح مستندات بقص وتحسين، ولو مش شغال على الموبايل بيتحول للكاميرا العادية تلقائياً).
Future<List<String>> scanImages(BuildContext context, int limit) async {
  if (!await ensureCamera(context)) return [];
  if (!context.mounted) return [];
  final p = await SharedPreferences.getInstance();
  if (p.getBool('simple') ?? false) return simplePick(context);
  final scanner = DocumentScanner(
    options: DocumentScannerOptions(
      mode: ScannerMode.full,
      pageLimit: limit,
      isGalleryImport: true, // الصور من المعرض بتعدي على الماسح زي الكاميرا
    ),
  );
  try {
    final r = await scanner.scanDocument();
    return List<String>.from(r.images ?? const []);
  } catch (e) {
    if (e.toString().toLowerCase().contains('cancel')) return [];
    if (!context.mounted) return [];
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الماسح مش شغال على الموبايل ده، هنفتح الكاميرا العادية')));
    return simplePick(context);
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

void snack(BuildContext context, String m) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

// ===== التطبيق =====
void main() => runApp(const A2RApp());

class A2RApp extends StatelessWidget {
  const A2RApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'A2R',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF0B5FA5), useMaterial3: true),
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
            const SizedBox(height: 16),
            const Text('A2R',
                style: TextStyle(fontSize: 56, fontWeight: FontWeight.w900, letterSpacing: 4)),
            const SizedBox(height: 48),
            DropdownButtonFormField<String>(
              value: name,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'الاسم', border: OutlineInputBorder()),
              items: kNames.map((n) => DropdownMenuItem(value: n, child: Text(n))).toList(),
              onChanged: (v) => setState(() => name = v),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<Unit>(
              value: unit,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'الوحدة', border: OutlineInputBorder()),
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
                decoration: const InputDecoration(labelText: 'المبنى', border: OutlineInputBorder()),
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
  ({File file, DateTime time})? pdf;
  bool batchSent = false;
  bool receiptsSent = false;
  bool simple = false;

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
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() => simple = p.getBool('simple') ?? false);
    await requestAllPermissions();
    await Store.cleanup();
    await _reload();
  }

  Future<void> _reload() async {
    final d = await Store.draft();
    final f = await Store.pdf();
    final b = await Store.flag('batch');
    final r = await Store.flag('receipts');
    if (!mounted) return;
    setState(() {
      draft = d;
      pdf = f;
      batchSent = b;
      receiptsSent = r;
    });
  }

  Future<void> _toggleSimple() async {
    setState(() => simple = !simple);
    final p = await SharedPreferences.getInstance();
    await p.setBool('simple', simple);
    if (!mounted) return;
    snack(context, simple ? 'الوضع البسيط: كاميرا أو معرض عادي بدون قص' : 'وضع الماسح: قص وتحسين تلقائي');
  }

  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    _reload();
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

  Widget _big(IconData icon, String label, bool done, VoidCallback onTap) => SizedBox(
        height: 150,
        child: FilledButton(
          style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              padding: const EdgeInsets.all(8)),
          onPressed: onTap,
          child: SizedBox.expand(
            child: Stack(children: [
              Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 46),
                  const SizedBox(height: 8),
                  Text(label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ]),
              ),
              if (done)
                const Positioned(
                  top: 2,
                  left: 2,
                  child: CircleAvatar(
                      radius: 14,
                      backgroundColor: Colors.green,
                      child: Icon(Icons.check, color: Colors.white, size: 20)),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('A2R', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2)),
        actions: [
          IconButton(
            tooltip: simple ? 'الوضع البسيط (اضغط للماسح)' : 'وضع الماسح (اضغط للوضع البسيط)',
            icon: Icon(simple ? Icons.photo_camera : Icons.document_scanner),
            onPressed: _toggleSimple,
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
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
                        style: TextStyle(fontSize: 12, color: Colors.grey))),
              ]),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.switch_account),
                  label: const Text('تغيير الحساب'),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
              child: _big(Icons.receipt_long, 'الباتش', batchSent,
                  () => _open(BatchScreen(session: s)))),
          const SizedBox(width: 12),
          Expanded(
              child: _big(Icons.payments, 'إيصالات الدفع', receiptsSent,
                  () => _open(ReceiptsScreen(session: s)))),
        ]),
        if (draft.isNotEmpty || pf != null) ...[
          const SizedBox(height: 24),
          const Text('ملفات إيصالات الدفع',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (draft.isNotEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.photo_library, size: 32),
                title: Text('صور قيد التصوير (${draft.length})'),
                subtitle: const Text('اضغط عشان تكمل التصوير'),
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
                leading: const Icon(Icons.picture_as_pdf, size: 32, color: Colors.red),
                title: Text(pf.file.path.split('/').last, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    'يتمسح بعد ${(24 - DateTime.now().difference(pf.time).inHours).clamp(1, 24)} ساعة'),
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
  Rendered? strip;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
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
      final st = await batchStrip(1000, widget.session);
      if (img != null) await Store.del(img!);
      if (!mounted) return;
      setState(() {
        img = path;
        strip = st;
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
      final bytes = await composeBatch(img!, widget.session);
      final out = File('${(await Store.dir()).path}/${widget.session.batchName}.jpg');
      await out.writeAsBytes(bytes);
      if (!mounted) return;
      final ok = await shareFiles(context, [out.path]);
      if (ok) {
        await Store.setFlag('batch');
        await Store.del(out.path);
        await Store.del(img!);
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) snack(context, 'حصل خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = img != null && strip != null;
    return Scaffold(
      appBar: AppBar(title: const Text('الباتش')),
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Container(
                    decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
                    child: Column(children: [
                      Image.memory(strip!.png, width: double.infinity, fit: BoxFit.fitWidth),
                      Image.file(File(img!),
                          width: double.infinity, fit: BoxFit.fitWidth, cacheWidth: 1000),
                    ]),
                  ),
                ),
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
  Rendered? label;
  File? built; // PDF اتعمل من الصور الحالية
  bool busy = false;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await Store.draft();
    final l = await receiptLabel(1000, widget.session);
    if (!mounted) return;
    setState(() {
      imgs = d;
      label = l;
      loaded = true;
    });
    if (d.isEmpty) _add();
  }

  Future<void> _add() async {
    final r = await scanImages(context, 1);
    if (r.isEmpty || !mounted) return;
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
                      itemBuilder: (_, i) => Container(
                        decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
                        child: Stack(children: [
                          Column(children: [
                            if (label != null)
                              Image.memory(label!.png, width: double.infinity, fit: BoxFit.fitWidth),
                            Image.file(File(imgs[i]),
                                width: double.infinity, fit: BoxFit.fitWidth, cacheWidth: 900),
                          ]),
                          Positioned(
                            top: 6,
                            left: 6,
                            child: GestureDetector(
                              onTap: busy ? null : () => _remove(i),
                              child: const CircleAvatar(
                                  radius: 16,
                                  backgroundColor: Colors.red,
                                  child: Icon(Icons.close, size: 20, color: Colors.white)),
                            ),
                          ),
                        ]),
                      ),
                    ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : _add,
                  icon: const Icon(Icons.add_a_photo),
                  label: const Text('إضافة صورة'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
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
