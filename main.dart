import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:path_provider/path_provider.dart';
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
/// صور الإيصالات (كل صورة بورقتها الصغيرة) ثم صورة الباتش في الآخر بالشريط.
Future<({File pdf, File batchImage})> buildPdf({
  required Session s,
  required List<String> receipts,
  required String batch,
}) async {
  final doc = pw.Document();
  const pageW = 595.0;

  Future<void> addPage(String path, bool isBatch) async {
    final bytes = await File(path).readAsBytes();
    final img = await decodeImage(bytes);
    final w = img.width.toDouble();
    final h = img.height.toDouble();
    img.dispose();
    final label = isBatch ? await batchStrip(w, s) : await receiptLabel(w, s);
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

  for (final p in receipts) {
    await addPage(p, false);
  }
  await addPage(batch, true);

  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/${s.pdfName}.pdf');
  await file.writeAsBytes(await doc.save());
  // صورة الباتش الأصلية باسم رقم الوحدة (مثلا 2.jpg)
  final batchImg = await File(batch).copy('${dir.path}/${s.batchName}.jpg');
  return (pdf: file, batchImage: batchImg);
}

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
        home: const HomeScreen(),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
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
        MaterialPageRoute(builder: (_) => ScanScreen(session: Session(name!, unit!, b))));
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

class ScanScreen extends StatefulWidget {
  final Session session;
  const ScanScreen({super.key, required this.session});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final List<String> receipts = [];
  String? batch;
  bool busy = false;

  Future<List<String>> _scan(int limit) async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormat: DocumentFormat.jpeg,
        mode: ScannerMode.full,
        pageLimit: limit,
        isGalleryImport: false,
      ),
    );
    try {
      final r = await scanner.scanDocument();
      return List<String>.from(r.images ?? const []);
    } catch (_) {
      return [];
    } finally {
      scanner.close();
    }
  }

  Future<void> _scanReceipts() async {
    final imgs = await _scan(100);
    if (imgs.isNotEmpty) setState(() => receipts.addAll(imgs));
  }

  Future<void> _scanBatch() async {
    final imgs = await _scan(1);
    if (imgs.isNotEmpty) setState(() => batch = imgs.first);
  }

  Future<void> _export() async {
    setState(() => busy = true);
    try {
      final f = await buildPdf(session: widget.session, receipts: receipts, batch: batch!);
      await Share.shareXFiles([XFile(f.pdf.path), XFile(f.batchImage.path)]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('حصل خطأ: $e')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _thumb(String path, VoidCallback onRemove) => Stack(children: [
        Positioned.fill(
            child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(File(path), fit: BoxFit.cover, cacheWidth: 300))),
        Positioned(
          top: 0,
          left: 0,
          child: GestureDetector(
            onTap: onRemove,
            child: const CircleAvatar(
                radius: 12, backgroundColor: Colors.red, child: Icon(Icons.close, size: 16, color: Colors.white)),
          ),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final canExport = receipts.isNotEmpty && batch != null && !busy;
    return Scaffold(
      appBar: AppBar(title: Text('${s.name} - ${s.unit.name}')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : _scanReceipts,
                icon: const Icon(Icons.document_scanner),
                label: Text('تصوير الإيصالات (${receipts.length})'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: busy ? null : _scanBatch,
                icon: Icon(batch == null ? Icons.receipt_long : Icons.check_circle),
                label: Text(batch == null ? 'تصوير الباتش' : 'إعادة تصوير الباتش'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: GridView.count(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.75,
              children: [
                for (var i = 0; i < receipts.length; i++)
                  _thumb(receipts[i], () => setState(() => receipts.removeAt(i))),
                if (batch != null) _thumb(batch!, () => setState(() => batch = null)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton.icon(
              onPressed: canExport ? _export : null,
              icon: busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.picture_as_pdf),
              label: Text(busy ? 'جاري إنشاء الملف...' : 'إنشاء الملفات وإرسالها'),
            ),
          ),
        ]),
      ),
    );
  }
}
