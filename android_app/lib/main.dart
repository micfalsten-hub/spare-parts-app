import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data.dart';

const navy = Color(0xFF142C36);
const teal = Color(0xFF087F75);
const canvas = Color(0xFFF5F4EF);
const muted = Color(0xFF64757B);
const gold = Color(0xFFD8A454);

String price(Object? cents) => cents == null
    ? 'غير محدد'
    : '${NumberFormat('#,##0.##', 'en').format((cents as int) / 100)} ج.م';
String dateLabel(Object? value) {
  if (value == null) return 'تاريخ غير مسجل';
  final date = DateTime.parse(value as String);
  return DateFormat('d MMM y', 'ar').format(date);
}

String textOf(DbRow row, String key) => '${row[key] ?? ''}';
String errorText(Object error) => error is FormatException
    ? error.message
    : error is StateError
    ? error.message
    : 'تعذر إتمام العملية. تحقق من الملف والمساحة المتاحة وحاول مرة أخرى.';
void message(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );

Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String details,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(details),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('نقل للمحذوفات'),
          ),
        ],
      ),
    ) ??
    false;
Future<T?> page<T>(BuildContext context, Widget screen) =>
    Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Store? store;
  var stage = 'فتح مجلد التطبيق';
  try {
    final documents = await getApplicationDocumentsDirectory();
    store = Store(Directory(p.join(documents.path, 'spare_parts')));
    stage = 'فتح قاعدة البيانات المحلية';
    await store.open();
    XFile? recovered;
    try {
      final lost = await ImagePicker().retrieveLostData();
      if (!lost.isEmpty && lost.files != null && lost.files!.isNotEmpty) {
        recovered = lost.files!.first;
      }
    } catch (_) {
      /* Devices without a camera still support the catalog. */
    }
    runApp(SparePartsApp(store: store, recoveredPhoto: recovered?.path));
  } catch (error, stack) {
    try {
      await store?.close();
    } catch (_) {
      // Keep the original failure; retry never removes the database or images.
    }
    runApp(
      StartupFailureApp(
        details: 'Daftar Parts 1.0.2 (3)\nStage: $stage\n$error\n\n$stack',
        retry: main,
      ),
    );
  }
}

class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({super.key, required this.details, required this.retry});
  final String details;
  final Future<void> Function() retry;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('ar')],
    locale: const Locale('ar'),
    theme: ThemeData(
      fontFamily: 'NotoArabic',
      scaffoldBackgroundColor: canvas,
      colorScheme: ColorScheme.fromSeed(seedColor: teal),
    ),
    home: _StartupFailureScreen(details: details, retry: retry),
  );
}

class _StartupFailureScreen extends StatefulWidget {
  const _StartupFailureScreen({required this.details, required this.retry});
  final String details;
  final Future<void> Function() retry;

  @override
  State<_StartupFailureScreen> createState() => _StartupFailureScreenState();
}

class _StartupFailureScreenState extends State<_StartupFailureScreen> {
  bool retrying = false;

  Future<void> retry() async {
    if (retrying) return;
    setState(() => retrying = true);
    try {
      await widget.retry();
    } finally {
      if (mounted) setState(() => retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 60),
          const Icon(Icons.folder_off_outlined, size: 64, color: navy),
          const SizedBox(height: 20),
          const Text(
            'تعذر فتح الدفتر المحلي',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, color: navy),
          ),
          const SizedBox(height: 12),
          const Text(
            'لا تمسح بيانات التطبيق أو تحذفه. حاول فتحه مرة أخرى. إذا استمرت المشكلة، انسخ تفاصيل الخطأ للمساعدة في التشخيص.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 54)),
            onPressed: retrying ? null : retry,
            child: Text(retrying ? 'جارٍ فتح الدفتر…' : 'إعادة المحاولة'),
          ),
          const SizedBox(height: 16),
          ExpansionTile(
            title: const Text('تفاصيل الخطأ'),
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: widget.details));
                  if (context.mounted) message(context, 'تم نسخ تفاصيل الخطأ');
                },
                icon: const Icon(Icons.copy_outlined),
                label: const Text('نسخ التفاصيل'),
              ),
              const SizedBox(height: 12),
              SelectableText(
                widget.details,
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class SparePartsApp extends StatelessWidget {
  const SparePartsApp({super.key, required this.store, this.recoveredPhoto});
  final Store store;
  final String? recoveredPhoto;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'دفتر القطع',
    debugShowCheckedModeBanner: false,
    locale: const Locale('ar'),
    supportedLocales: const [Locale('ar')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: canvas,
      fontFamily: 'NotoArabic',
      colorScheme: ColorScheme.fromSeed(
        seedColor: teal,
        primary: teal,
        secondary: gold,
        surface: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: navy,
        centerTitle: false,
        elevation: 0,
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 15, color: navy),
        bodyLarge: TextStyle(fontSize: 16, color: navy),
        titleLarge: TextStyle(
          fontSize: 23,
          fontWeight: FontWeight.w700,
          color: navy,
        ),
        titleMedium: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: navy,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 18,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFFDDE3E0)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFFDDE3E0)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: teal, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 54),
          textStyle: const TextStyle(
            fontFamily: 'NotoArabic',
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: teal.withValues(alpha: .12),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(
            fontFamily: 'NotoArabic',
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(backgroundColor: navy),
    ),
    home: Home(store: store, recoveredPhoto: recoveredPhoto),
  );
}

class Home extends StatefulWidget {
  const Home({super.key, required this.store, this.recoveredPhoto});
  final Store store;
  final String? recoveredPhoto;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  int filter = 0;
  String query = '';
  bool recoveredShown = false;
  final search = TextEditingController();
  Store get store => widget.store;
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final q = normalize(query);
      final items = tab == 0
          ? store.products
                .where(
                  (r) =>
                      normalize(
                        '${r['name']} ${r['code']} ${r['category']} ${r['country_of_origin']} ${r['notes']} ${r['latest_supplier'] ?? ''}',
                      ).contains(q) &&
                      (filter == 0 ||
                          filter == 1 && r['selling_price'] == null ||
                          filter == 2 && r['image'] != null),
                )
                .toList()
          : tab == 1
          ? store.suppliers
                .where(
                  (r) => normalize(
                    '${r['name']} ${r['phone']} ${r['address']} ${r['notes']}',
                  ).contains(q),
                )
                .toList()
          : store.purchases
                .where(
                  (r) => normalize(
                    '${r['product_name']} ${r['supplier_name']} ${r['notes']}',
                  ).contains(q),
                )
                .toList();
      return Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: navy,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.settings_suggest_outlined,
                  color: gold,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'دفتر القطع',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'ذاكرة تجارتك، في جيبك',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'النسخ الاحتياطي والإعدادات',
              onPressed: () => page(context, Tools(store: store)),
              icon: const Icon(Icons.tune_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                sliver: SliverList.list(
                  children: [
                    if (tab == 0) ...[
                      Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: navy,
                          borderRadius: BorderRadius.circular(26),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.offline_bolt_outlined,
                                  color: gold,
                                  size: 20,
                                ),
                                const SizedBox(width: 6),
                                const Expanded(
                                  child: Text(
                                    'دفترك محفوظ على هذا الهاتف',
                                    style: TextStyle(
                                      color: Color(0xFFCBDAD8),
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            const Text(
                              'القطعة الصح.\nوالسعر في إيدك.',
                              style: TextStyle(
                                fontSize: 26,
                                height: 1.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Row(
                              children: [
                                Expanded(
                                  child: stat(
                                    '${store.products.length}',
                                    'قطعة',
                                  ),
                                ),
                                Expanded(
                                  child: stat(
                                    '${store.suppliers.length}',
                                    'مورد',
                                  ),
                                ),
                                Expanded(
                                  child: stat(
                                    '${store.purchases.length}',
                                    'عملية شراء',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                    ],
                    if (widget.recoveredPhoto != null && !recoveredShown) ...[
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.photo_camera_back_outlined),
                          title: const Text('تم استرجاع صورة الكاميرا'),
                          subtitle: const Text('اضغط لإضافتها إلى قطعة جديدة'),
                          onTap: () async {
                            await page(
                              context,
                              ProductForm(
                                store: store,
                                initialPhoto: widget.recoveredPhoto,
                              ),
                            );
                            if (mounted) setState(() => recoveredShown = true);
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            ['قطع الغيار', 'الموردون', 'سجل المشتريات'][tab],
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        Text(
                          '${items.length}',
                          style: const TextStyle(color: muted, fontSize: 16),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: search,
                      onChanged: (v) => setState(() => query = v),
                      decoration: InputDecoration(
                        hintText: tab == 0
                            ? 'ابحث بالاسم، الكود أو المورد…'
                            : tab == 1
                            ? 'ابحث عن مورد أو رقم هاتف…'
                            : 'ابحث بالقطعة أو المورد…',
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          color: teal,
                        ),
                        suffixIcon: query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'مسح البحث',
                                onPressed: () {
                                  search.clear();
                                  setState(() => query = '');
                                },
                                icon: const Icon(Icons.close),
                              ),
                      ),
                    ),
                    if (tab == 0) ...[
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: List.generate(
                            3,
                            (i) => Padding(
                              padding: const EdgeInsetsDirectional.only(end: 8),
                              child: ChoiceChip(
                                label: Text(
                                  ['كل القطع', 'بدون سعر بيع', 'لها صورة'][i],
                                ),
                                selected: filter == i,
                                onSelected: (_) => setState(() => filter = i),
                                showCheckmark: false,
                                selectedColor: teal.withValues(alpha: .12),
                                labelStyle: TextStyle(
                                  color: filter == i ? teal : muted,
                                  fontWeight: FontWeight.w600,
                                ),
                                side: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (items.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Empty(
                      icon: tab == 1
                          ? Icons.people_outline
                          : Icons.inventory_2_outlined,
                      title: query.isNotEmpty
                          ? 'لا توجد نتائج مطابقة'
                          : tab == 0
                          ? 'ابدأ بأول قطعة'
                          : tab == 1
                          ? 'أضف أول مورد'
                          : 'سجل أول عملية شراء',
                      subtitle: query.isNotEmpty
                          ? 'جرّب اسمًا أقصر أو كود القطعة.'
                          : tab == 0
                          ? 'اسم، سعر وصورة… وكل التفاصيل تفضل معاك.'
                          : tab == 1
                          ? 'احفظ بيانات المورد مرة واحدة وارجع لها بسهولة.'
                          : 'كل عملية تحفظ سعرها وموردها وتاريخها.',
                      action:
                          query.isEmpty &&
                              tab == 0 &&
                              store.products.isEmpty &&
                              store.suppliers.isEmpty
                          ? TextButton(
                              onPressed: () async {
                                try {
                                  await store.loadExamples();
                                } catch (e) {
                                  if (context.mounted) {
                                    message(context, errorText(e));
                                  }
                                }
                              },
                              child: const Text(
                                'جرّب المنتجات الثلاثة من النموذج السابق',
                              ),
                            )
                          : null,
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverList.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: tab == 0
                          ? ProductTile(store: store, row: items[index])
                          : tab == 1
                          ? SupplierTile(store: store, row: items[index])
                          : PurchaseTile(store: store, row: items[index]),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: teal,
          foregroundColor: Colors.white,
          onPressed: () => page(
            context,
            tab == 0
                ? ProductForm(store: store)
                : tab == 1
                ? SupplierForm(store: store)
                : PurchaseForm(store: store),
          ),
          icon: const Icon(Icons.add),
          label: Text(
            ['قطعة جديدة', 'مورد جديد', 'تسجيل شراء'][tab],
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (v) => setState(() {
            tab = v;
            query = '';
            search.clear();
          }),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.grid_view_outlined),
              selectedIcon: Icon(Icons.grid_view_rounded),
              label: 'القطع',
            ),
            NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people),
              label: 'الموردون',
            ),
            NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long),
              label: 'المشتريات',
            ),
          ],
        ),
      );
    },
  );
  Widget stat(String value, String label) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 25,
          fontWeight: FontWeight.w700,
        ),
      ),
      Text(
        label,
        style: const TextStyle(color: Color(0xFFCBDAD8), fontSize: 12),
      ),
    ],
  );
}

class Empty extends StatelessWidget {
  const Empty({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });
  final IconData icon;
  final String title, subtitle;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: teal.withValues(alpha: .07),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: teal, size: 42),
      ),
      const SizedBox(height: 18),
      Text(
        title,
        style: Theme.of(context).textTheme.titleMedium,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 8),
      Text(
        subtitle,
        style: const TextStyle(color: muted, height: 1.7),
        textAlign: TextAlign.center,
      ),
      if (action != null) ...[const SizedBox(height: 8), action!],
    ],
  );
}

class Photo extends StatelessWidget {
  const Photo({super.key, required this.store, this.name, this.size = 70});
  final Store store;
  final String? name;
  final double size;
  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: const Color(0xFFEAF0EC),
      child: Center(
        child: Icon(Icons.settings_outlined, color: teal, size: size * .43),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(17),
      child: SizedBox(
        width: size,
        height: size,
        child: name == null
            ? placeholder
            : Image.file(
                File(store.imagePath(name!)),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

class Surface extends StatelessWidget {
  const Surface({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: const BorderSide(color: Color(0xFFE5E8E2)),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(padding: padding, child: child),
    ),
  );
}

class ProductTile extends StatelessWidget {
  const ProductTile({super.key, required this.store, required this.row});
  final Store store;
  final DbRow row;
  @override
  Widget build(BuildContext context) => Surface(
    onTap: () =>
        page(context, ProductDetail(store: store, id: row['id'] as String)),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Photo(store: store, name: row['image'] as String?),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                textOf(row, 'name'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (textOf(row, 'code').isNotEmpty)
                Text(
                  textOf(row, 'code'),
                  style: const TextStyle(fontSize: 12, color: muted),
                ),
              const SizedBox(height: 5),
              Text(
                price(row['selling_price']),
                style: const TextStyle(
                  color: teal,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                row['latest_supplier'] == null
                    ? 'لا توجد مشتريات مسجلة'
                    : 'آخر مورد: ${row['latest_supplier']}',
                style: const TextStyle(fontSize: 12, color: muted),
              ),
            ],
          ),
        ),
        const Icon(Icons.chevron_left, color: muted, size: 20),
      ],
    ),
  );
}

class SupplierTile extends StatelessWidget {
  const SupplierTile({super.key, required this.store, required this.row});
  final Store store;
  final DbRow row;
  @override
  Widget build(BuildContext context) => Surface(
    onTap: () =>
        page(context, SupplierDetail(store: store, id: row['id'] as String)),
    child: Row(
      children: [
        CircleAvatar(
          radius: 26,
          backgroundColor: const Color(0xFFEAF0EC),
          foregroundColor: teal,
          child: Text(
            textOf(row, 'name').substring(0, 1),
            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                textOf(row, 'name'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                textOf(row, 'phone').isEmpty
                    ? 'رقم الهاتف غير مسجل'
                    : textOf(row, 'phone'),
                style: const TextStyle(color: muted, fontSize: 13),
              ),
              Text(
                '${row['purchase_count']} عملية شراء',
                style: const TextStyle(color: teal, fontSize: 12),
              ),
            ],
          ),
        ),
        const Icon(Icons.chevron_left, color: muted),
      ],
    ),
  );
}

class PurchaseTile extends StatelessWidget {
  const PurchaseTile({
    super.key,
    required this.store,
    required this.row,
    this.showProduct = true,
  });
  final Store store;
  final DbRow row;
  final bool showProduct;
  Future<void> remove(BuildContext context) async {
    if (!await confirmDelete(
      context,
      title: 'حذف عملية الشراء؟',
      details: 'ستُنقل العملية إلى سلة المحذوفات لمدة 30 يومًا ويمكن استعادتها خلال هذه المدة.',
    )) {
      return;
    }
    await store.deletePurchase(row['id'] as String);
    if (context.mounted) {
      message(context, 'تم نقل عملية الشراء إلى المحذوفات');
    }
  }
  @override
  Widget build(BuildContext context) => Surface(
    onTap: () => page(context, PurchaseForm(store: store, row: row)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                showProduct
                    ? textOf(row, 'product_name')
                    : textOf(row, 'supplier_name'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              price(row['price']),
              style: const TextStyle(color: teal, fontWeight: FontWeight.w700),
            ),
            IconButton(
              tooltip: 'حذف عملية الشراء',
              onPressed: () => remove(context),
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '${showProduct ? '${row['supplier_name']} · ' : ''}${dateLabel(row['date'])}',
          style: const TextStyle(color: muted, fontSize: 12),
        ),
        if (textOf(row, 'notes').isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            textOf(row, 'notes'),
            style: const TextStyle(color: muted, fontSize: 13),
          ),
        ],
      ],
    ),
  );
}

class ProductDetail extends StatelessWidget {
  const ProductDetail({super.key, required this.store, required this.id});
  final Store store;
  final String id;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final row = store.products.firstWhere((r) => r['id'] == id);
      final history = store.purchases
          .where((r) => r['product_id'] == id)
          .toList();
      final previous = <String, DbRow>{};
      for (final item in history) {
        previous.putIfAbsent(item['supplier_id'] as String, () => item);
      }
      final sell = row['selling_price'] as int?;
      final buy = row['latest_price'] as int?;
      return Scaffold(
        appBar: AppBar(
          title: const Text('تفاصيل القطعة'),
          actions: [
            IconButton(
              tooltip: 'حذف القطعة',
              onPressed: () async {
                final count = history.length;
                if (!await confirmDelete(
                  context,
                  title: 'حذف القطعة؟',
                  details: count == 0
                      ? 'ستُنقل القطعة إلى سلة المحذوفات لمدة 30 يومًا.'
                      : 'ستُنقل القطعة وعمليات الشراء المرتبطة بها ($count) إلى سلة المحذوفات لمدة 30 يومًا.',
                )) {
                  return;
                }
                await store.deleteProduct(id);
                if (context.mounted) {
                  Navigator.of(context).pop();
                  message(context, 'تم نقل القطعة وسجلها إلى المحذوفات');
                }
              },
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            ),
            IconButton(
              tooltip: 'تعديل القطعة',
              onPressed: () =>
                  page(context, ProductForm(store: store, row: row)),
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: Photo(
                  store: store,
                  name: row['image'] as String?,
                  size: 190,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                textOf(row, 'name'),
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              if (textOf(row, 'code').isNotEmpty ||
                  textOf(row, 'category').isNotEmpty)
                Text(
                  [
                    row['code'],
                    row['category'],
                  ].where((v) => v != null && v != '').join(' · '),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: muted),
                ),
              if (textOf(row, 'country_of_origin').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'بلد المنشأ: ${textOf(row, 'country_of_origin')}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: muted),
                  ),
                ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: navy,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'سعر البيع الحالي',
                      style: TextStyle(color: Color(0xFFCBDAD8)),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      price(sell),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (sell != null && buy != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        'فرق السعر عن آخر شراء: ${price(sell - buy)}',
                        style: const TextStyle(
                          color: Color(0xFFE2BD7F),
                          fontSize: 13,
                        ),
                      ),
                      const Text(
                        'فرق تقديري، قبل أي مصاريف',
                        style: TextStyle(
                          color: Color(0xFFCBDAD8),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Surface(
                onTap: row['latest_supplier_id'] == null
                    ? null
                    : () => page(
                        context,
                        SupplierDetail(
                          store: store,
                          id: row['latest_supplier_id'] as String,
                        ),
                      ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'آخر شراء',
                      style: TextStyle(color: muted, fontSize: 13),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      price(buy),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            row['latest_supplier'] == null
                                ? 'لم تسجل عملية شراء بعد'
                                : '${row['latest_supplier']}',
                            style: const TextStyle(
                              color: teal,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (row['latest_supplier'] != null)
                          const Icon(Icons.chevron_left, color: teal),
                      ],
                    ),
                    if (history.isNotEmpty)
                      Text(
                        dateLabel(row['latest_date']),
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                  ],
                ),
              ),
              if (textOf(row, 'notes').isNotEmpty) ...[
                const SizedBox(height: 16),
                Surface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'ملاحظات',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(textOf(row, 'notes')),
                    ],
                  ),
                ),
              ],
              if (previous.isNotEmpty) ...[
                const SizedBox(height: 26),
                section(context, 'الموردون السابقون', 'آخر سعر لكل مورد'),
                const SizedBox(height: 12),
                ...previous.values.map(
                  (r) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Surface(
                      onTap: () => page(
                        context,
                        SupplierDetail(
                          store: store,
                          id: r['supplier_id'] as String,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            textOf(r, 'supplier_name'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${price(r['price'])} · ${dateLabel(r['date'])}',
                            style: const TextStyle(color: teal, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 26),
              section(
                context,
                'سجل الشراء',
                '${history.length} عملية · اضغط لتصحيح التفاصيل',
              ),
              const SizedBox(height: 12),
              if (history.isEmpty)
                const Empty(
                  icon: Icons.receipt_long_outlined,
                  title: 'لا يوجد سجل شراء',
                  subtitle: 'سجل شراء لحفظ السعر والمورد والتاريخ.',
                ),
              ...history.map(
                (r) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: PurchaseTile(store: store, row: r, showProduct: false),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
        bottomNavigationBar: bottomAction(
          context,
          'تسجيل شراء لهذه القطعة',
          Icons.add_shopping_cart,
          () => page(context, PurchaseForm(store: store, productId: id)),
        ),
      );
    },
  );
}

Widget section(BuildContext context, String title, String subtitle) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(title, style: Theme.of(context).textTheme.titleMedium),
    Text(subtitle, style: const TextStyle(color: muted, fontSize: 12)),
  ],
);
Widget bottomAction(
  BuildContext context,
  String label,
  IconData icon,
  VoidCallback? action,
) => SafeArea(
  child: Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
    child: FilledButton.icon(
      onPressed: action,
      icon: Icon(icon),
      label: Text(label),
    ),
  ),
);

class SupplierDetail extends StatelessWidget {
  const SupplierDetail({super.key, required this.store, required this.id});
  final Store store;
  final String id;
  Future<void> callPhone(BuildContext context, String number) async {
    try {
      if (!await launchUrl(Uri(scheme: 'tel', path: number), mode: LaunchMode.externalApplication) &&
          context.mounted) {
        message(context, 'لا يوجد تطبيق مناسب للاتصال بهذا الرقم.');
      }
    } catch (_) {
      if (context.mounted) message(context, 'تعذر الاتصال. تحقق من رقم الهاتف.');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final row = store.suppliers.firstWhere((r) => r['id'] == id);
      final history = store.purchases
          .where((r) => r['supplier_id'] == id)
          .toList();
      final latest = <String, DbRow>{};
      for (final r in history) {
        latest.putIfAbsent(r['product_id'] as String, () => r);
      }
      final phone = textOf(row, 'phone');
      return Scaffold(
        appBar: AppBar(
          title: const Text('ملف المورد'),
          actions: [
            IconButton(
              tooltip: 'حذف المورد',
              onPressed: () async {
                final count = history.length;
                if (!await confirmDelete(
                  context,
                  title: 'حذف المورد؟',
                  details: count == 0
                      ? 'سينتقل المورد إلى سلة المحذوفات لمدة 30 يومًا.'
                      : 'سينتقل المورد وعمليات الشراء المرتبطة به ($count) إلى سلة المحذوفات لمدة 30 يومًا.',
                )) {
                  return;
                }
                await store.deleteSupplier(id);
                if (context.mounted) {
                  Navigator.of(context).pop();
                  message(context, 'تم نقل المورد وسجل مشترياته إلى المحذوفات');
                }
              },
              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            ),
            IconButton(
              tooltip: 'تعديل المورد',
              onPressed: () =>
                  page(context, SupplierForm(store: store, row: row)),
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Container(
                padding: const EdgeInsets.all(26),
                decoration: BoxDecoration(
                  color: navy,
                  borderRadius: BorderRadius.circular(26),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.storefront_outlined,
                      color: gold,
                      size: 40,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      textOf(row, 'name'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 25,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${history.length} عملية شراء · ${latest.length} قطعة مختلفة',
                      style: const TextStyle(
                        color: Color(0xFFCBDAD8),
                        fontSize: 13,
                      ),
                    ),
                    if (history.isNotEmpty)
                      Text(
                        'آخر تعامل: ${dateLabel(history.first['date'])}',
                        style: const TextStyle(
                          color: Color(0xFFCBDAD8),
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  if (phone.isNotEmpty)
                    FilledButton.icon(
                      onPressed: () => callPhone(context, phone),
                      icon: const Icon(Icons.call_outlined),
                      label: const Text('اتصال'),
                    ),
                ],
              ),
              if (phone.isEmpty)
                const Text(
                  'أضف رقم الهاتف من تعديل المورد للتواصل بسرعة.',
                  style: TextStyle(color: muted),
                ),
              const SizedBox(height: 18),
              Surface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    info(
                      Icons.phone_outlined,
                      'الهاتف',
                      phone.isEmpty ? 'غير مسجل' : phone,
                    ),
                    info(
                      Icons.location_on_outlined,
                      'العنوان',
                      textOf(row, 'address').isEmpty
                          ? 'غير مسجل'
                          : textOf(row, 'address'),
                    ),
                    if (textOf(row, 'notes').isNotEmpty)
                      info(
                        Icons.notes_rounded,
                        'ملاحظات',
                        textOf(row, 'notes'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              section(context, 'آخر القطع الموردة', 'آخر توريد لكل قطعة'),
              const SizedBox(height: 12),
              if (latest.isEmpty)
                const Empty(
                  icon: Icons.local_shipping_outlined,
                  title: 'لا توجد قطع موردة بعد',
                  subtitle: 'ستظهر هنا القطع التي تسجل شراءها من هذا المورد.',
                ),
              ...latest.values.map(
                (r) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Surface(
                    onTap: () => page(
                      context,
                      ProductDetail(
                        store: store,
                        id: r['product_id'] as String,
                      ),
                    ),
                    child: Row(
                      children: [
                        Photo(
                          store: store,
                          name: r['product_image'] as String?,
                          size: 56,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                textOf(r, 'product_name'),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                '${price(r['price'])} · ${dateLabel(r['date'])}',
                                style: const TextStyle(
                                  color: teal,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (history.isNotEmpty) ...[
                const SizedBox(height: 18),
                section(context, 'كل التعاملات', 'اضغط على عملية لتعديلها'),
                const SizedBox(height: 12),
                ...history.map(
                  (r) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: PurchaseTile(store: store, row: r),
                  ),
                ),
              ],
              const SizedBox(height: 20),
            ],
          ),
        ),
        bottomNavigationBar: bottomAction(
          context,
          'تسجيل شراء من هذا المورد',
          Icons.add_shopping_cart,
          () => page(context, PurchaseForm(store: store, supplierId: id)),
        ),
      );
    },
  );
  Widget info(IconData icon, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: teal, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: muted, fontSize: 12)),
              const SizedBox(height: 4),
              Text(value),
            ],
          ),
        ),
      ],
    ),
  );
}

class ProductForm extends StatefulWidget {
  const ProductForm({
    super.key,
    required this.store,
    this.row,
    this.initialPhoto,
  });
  final Store store;
  final DbRow? row;
  final String? initialPhoto;
  @override
  State<ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<ProductForm> {
  final form = GlobalKey<FormState>();
  late final TextEditingController name, code, category, origin, sell, notes;
  String? photo;
  bool removePhoto = false, busy = false;
  @override
  void initState() {
    super.initState();
    final r = widget.row ?? {};
    name = TextEditingController(text: textOf(r, 'name'));
    code = TextEditingController(text: textOf(r, 'code'));
    category = TextEditingController(text: textOf(r, 'category'));
    origin = TextEditingController(text: textOf(r, 'country_of_origin'));
    sell = TextEditingController(text: moneyInput(r['selling_price']));
    notes = TextEditingController(text: textOf(r, 'notes'));
    photo = widget.initialPhoto;
  }

  @override
  void dispose() {
    for (final c in [name, code, category, origin, sell, notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> pick(ImageSource source) async {
    try {
      final image = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (image != null && mounted) {
        setState(() {
          photo = image.path;
          removePhoto = false;
        });
      }
    } catch (_) {
      if (mounted) {
        message(context, 'تعذر فتح الكاميرا أو الصور. جرّب الاختيار من الصور.');
      }
    }
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      final id = await widget.store.saveProduct({
        'id': widget.row?['id'],
        'name': name.text.trim(),
        'code': code.text.trim(),
        'category': category.text.trim(),
        'country_of_origin': origin.text.trim(),
        'selling_price': money(sell.text),
        'notes': notes.text.trim(),
        'image': removePhoto ? null : widget.row?['image'],
      }, photoSource: photo);
      if (mounted) {
        Navigator.pop(context, id);
        message(context, 'تم حفظ القطعة على الهاتف');
      }
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        message(context, errorText(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = removePhoto ? null : widget.row?['image'] as String?;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.row == null ? 'قطعة جديدة' : 'تعديل القطعة'),
      ),
      body: SafeArea(
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'تفاصيل بسيطة، ترجع لها بسرعة',
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 22),
              Center(
                child: photo != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: Image.file(
                          File(photo!),
                          width: 160,
                          height: 160,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.broken_image_outlined,
                            size: 100,
                          ),
                        ),
                      )
                    : Photo(store: widget.store, name: existing, size: 160),
              ),
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => pick(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('التقاط صورة'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => pick(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('من الصور'),
                  ),
                ],
              ),
              if (photo != null || existing != null)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          photo = null;
                          removePhoto = true;
                        }),
                  child: const Text('إزالة الصورة'),
                ),
              const SizedBox(height: 22),
              field(name, 'اسم القطعة *', required: true),
              field(code, 'كود القطعة / رقمها'),
              field(category, 'الفئة أو السيارة'),
              field(origin, 'بلد المنشأ'),
              field(sell, 'سعر البيع الحالي (ج.م)', amount: true),
              field(notes, 'ملاحظات', lines: 3),
              const SizedBox(height: 12),
              const Text(
                'الصور والبيانات تحفظ داخل الهاتف فور الضغط على حفظ.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
      bottomNavigationBar: bottomAction(
        context,
        busy ? 'جارٍ الحفظ…' : 'حفظ القطعة',
        Icons.check,
        busy ? null : save,
      ),
    );
  }
}

Widget field(
  TextEditingController controller,
  String label, {
  bool required = false,
  bool amount = false,
  int lines = 1,
  TextInputType? keyboard,
  String? helper,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 16),
  child: TextFormField(
    controller: controller,
    maxLines: lines,
    keyboardType: amount
        ? const TextInputType.numberWithOptions(decimal: true)
        : keyboard ??
              (lines > 1 ? TextInputType.multiline : TextInputType.text),
    textDirection: amount || keyboard == TextInputType.phone
        ? TextDirection.ltr
        : null,
    decoration: InputDecoration(
      labelText: label,
      helperText: helper,
      helperMaxLines: 3,
    ),
    validator: (v) {
      if (required && (v ?? '').trim().isEmpty) return 'هذا الحقل مطلوب';
      if (amount) {
        try {
          money(v ?? '');
        } catch (e) {
          return errorText(e);
        }
      }
      return null;
    },
  ),
);

class SupplierForm extends StatefulWidget {
  const SupplierForm({super.key, required this.store, this.row});
  final Store store;
  final DbRow? row;
  @override
  State<SupplierForm> createState() => _SupplierFormState();
}

class _SupplierFormState extends State<SupplierForm> {
  final form = GlobalKey<FormState>();
  late final List<TextEditingController> fields;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    fields = [
      for (final k in ['name', 'phone', 'address', 'notes'])
        TextEditingController(text: textOf(widget.row ?? {}, k)),
    ];
  }

  @override
  void dispose() {
    for (final f in fields) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      final id = await widget.store.saveSupplier({
        'id': widget.row?['id'],
        'name': fields[0].text.trim(),
        'phone': fields[1].text.trim(),
        'whatsapp': '',
        'address': fields[2].text.trim(),
        'notes': fields[3].text.trim(),
      });
      if (mounted) {
        Navigator.pop(context, id);
        message(context, 'تم حفظ المورد على الهاتف');
      }
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        message(context, errorText(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.row == null ? 'مورد جديد' : 'تعديل المورد'),
    ),
    body: SafeArea(
      child: Form(
        key: form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'كل وسائل التواصل، في مكان واحد',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 24),
            field(fields[0], 'اسم المورد *', required: true),
            field(fields[1], 'رقم الهاتف', keyboard: TextInputType.phone),
            field(fields[2], 'العنوان', lines: 2),
            field(fields[3], 'ملاحظات', lines: 3),
          ],
        ),
      ),
    ),
    bottomNavigationBar: bottomAction(
      context,
      busy ? 'جارٍ الحفظ…' : 'حفظ المورد',
      Icons.check,
      busy ? null : save,
    ),
  );
}

class PurchaseForm extends StatefulWidget {
  const PurchaseForm({
    super.key,
    required this.store,
    this.productId,
    this.supplierId,
    this.row,
  });
  final Store store;
  final String? productId, supplierId;
  final DbRow? row;
  @override
  State<PurchaseForm> createState() => _PurchaseFormState();
}

class _PurchaseFormState extends State<PurchaseForm> {
  final form = GlobalKey<FormState>();
  final buy = TextEditingController(),
      sell = TextEditingController(),
      notes = TextEditingController();
  String? productId, supplierId, date;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    productId = widget.row?['product_id'] as String? ?? widget.productId;
    supplierId = widget.row?['supplier_id'] as String? ?? widget.supplierId;
    date = widget.row == null
        ? DateTime.now().toIso8601String().substring(0, 10)
        : widget.row!['date'] as String?;
    buy.text = moneyInput(widget.row?['price']);
    notes.text = textOf(widget.row ?? {}, 'notes');
  }

  @override
  void dispose() {
    buy.dispose();
    sell.dispose();
    notes.dispose();
    super.dispose();
  }

  Future<void> choose(bool product) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: canvas,
      builder: (context) => Chooser(store: widget.store, product: product),
    );
    if (id != null && mounted) {
      setState(() {
        if (product) {
          productId = id;
        } else {
          supplierId = id;
        }
      });
    }
  }

  Future<void> pickDate() async {
    final current = date == null ? DateTime.now() : DateTime.parse(date!);
    final result = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (result != null && mounted) {
      setState(() => date = result.toIso8601String().substring(0, 10));
    }
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    if (productId == null || supplierId == null) {
      message(context, 'اختر القطعة والمورد أولًا');
      return;
    }
    setState(() => busy = true);
    try {
      await widget.store.savePurchase({
        'id': widget.row?['id'],
        'product_id': productId,
        'supplier_id': supplierId,
        'date': date,
        'price': money(buy.text),
        'notes': notes.text.trim(),
      }, sellingPrice: money(sell.text));
      if (mounted) {
        Navigator.pop(context);
        message(context, 'تم حفظ عملية الشراء');
      }
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        message(context, errorText(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final products = widget.store.products.where((r) => r['id'] == productId),
          suppliers = widget.store.suppliers.where(
            (r) => r['id'] == supplierId,
          );
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.row == null ? 'تسجيل شراء' : 'تصحيح عملية شراء'),
        ),
        body: SafeArea(
          child: Form(
            key: form,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: teal.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.lock_outline, color: teal),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'عملية واحدة تحفظ السعر والمورد والتاريخ، وتحدّث سجل القطعة.',
                          style: TextStyle(color: teal, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                selection(
                  context,
                  'القطعة *',
                  products.isEmpty
                      ? 'اختر قطعة أو أضف جديدة'
                      : textOf(products.first, 'name'),
                  Icons.settings_outlined,
                  busy ? null : () => choose(true),
                ),
                const SizedBox(height: 16),
                selection(
                  context,
                  'المورد *',
                  suppliers.isEmpty
                      ? 'اختر موردًا أو أضف جديدًا'
                      : textOf(suppliers.first, 'name'),
                  Icons.storefront_outlined,
                  busy ? null : () => choose(false),
                ),
                const SizedBox(height: 20),
                field(buy, 'سعر الشراء (ج.م) *', required: true, amount: true),
                field(
                  sell,
                  'تحديث سعر البيع الحالي (اختياري)',
                  amount: true,
                  helper:
                      'اتركه فارغًا للاحتفاظ بسعر البيع الحالي، حتى عند تسجيل شراء قديم.',
                ),
                selection(
                  context,
                  'تاريخ الشراء',
                  dateLabel(date),
                  Icons.calendar_today_outlined,
                  busy ? null : pickDate,
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: busy ? null : () => setState(() => date = null),
                    child: const Text('التاريخ غير معروف'),
                  ),
                ),
                const SizedBox(height: 8),
                field(notes, 'ملاحظات العملية', lines: 3),
                const Text(
                  'آخر شراء يُحسب حسب تاريخ الشراء. العمليات غير المؤرخة تظهر في آخر السجل.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
        bottomNavigationBar: bottomAction(
          context,
          busy ? 'جارٍ الحفظ…' : 'حفظ عملية الشراء',
          Icons.check,
          busy ? null : save,
        ),
      );
    },
  );
}

Widget selection(
  BuildContext context,
  String label,
  String value,
  IconData icon,
  VoidCallback? action,
) => Surface(
  onTap: action,
  child: Row(
    children: [
      Icon(icon, color: teal),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: muted, fontSize: 12)),
            const SizedBox(height: 6),
            Text(value, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
      const Icon(Icons.expand_more, color: muted),
    ],
  ),
);

class Chooser extends StatefulWidget {
  const Chooser({super.key, required this.store, required this.product});
  final Store store;
  final bool product;
  @override
  State<Chooser> createState() => _ChooserState();
}

class _ChooserState extends State<Chooser> {
  String query = '';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final rows =
          (widget.product ? widget.store.products : widget.store.suppliers)
              .where(
                (r) => normalize(
                  '${r['name']} ${r['code'] ?? ''}',
                ).contains(normalize(query)),
              )
              .toList();
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .75,
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: muted.withValues(alpha: .25),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(
                      widget.product ? 'اختيار قطعة' : 'اختيار مورد',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      onChanged: (v) => setState(() => query = v),
                      decoration: const InputDecoration(
                        hintText: 'بحث سريع…',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final id = await page<String>(
                          context,
                          widget.product
                              ? ProductForm(store: widget.store)
                              : SupplierForm(store: widget.store),
                        );
                        if (id != null && context.mounted) {
                          Navigator.pop(context, id);
                        }
                      },
                      icon: const Icon(Icons.add),
                      label: Text(
                        widget.product ? 'إضافة قطعة جديدة' : 'إضافة مورد جديد',
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) => ListTile(
                    minVerticalPadding: 16,
                    title: Text(textOf(rows[i], 'name')),
                    subtitle: widget.product
                        ? Text(price(rows[i]['selling_price']))
                        : null,
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () => Navigator.pop(context, rows[i]['id']),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class TrashScreen extends StatelessWidget {
  const TrashScreen({super.key, required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('سلة المحذوفات'),
          actions: [
            if (store.trashEntries.isNotEmpty)
              IconButton(
                tooltip: 'إفراغ السلة',
                onPressed: () async {
                  final accepted = await confirmDelete(
                    context,
                    title: 'إفراغ سلة المحذوفات؟',
                    details: 'لن يمكن استعادة العناصر بعد إفراغ السلة.',
                  );
                  if (!accepted) return;
                  await store.emptyTrash();
                  if (context.mounted) {
                    message(context, 'تم إفراغ السلة');
                  }
                },
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
          ],
        ),
        body: SafeArea(
          child: store.trashEntries.isEmpty
              ? const Empty(
                  icon: Icons.delete_outline,
                  title: 'سلة المحذوفات فارغة',
                  subtitle: 'العناصر التي تحذفها ستبقى هنا 30 يومًا قبل حذفها نهائيًا.',
                )
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    const Text(
                      'يمكنك استعادة العناصر خلال 30 يومًا. تُحذف بعدها تلقائيًا.',
                      style: TextStyle(color: muted, height: 1.7),
                    ),
                    const SizedBox(height: 16),
                    for (final entry in store.trashEntries)
                      _TrashTile(store: store, entry: entry),
                  ],
                ),
        ),
      );
    },
  );
}

class _TrashTile extends StatelessWidget {
  const _TrashTile({required this.store, required this.entry});
  final Store store;
  final DbRow entry;

  @override
  Widget build(BuildContext context) {
    final payload = jsonDecode(entry['payload'] as String) as Map<String, dynamic>;
    final entity = Map<String, Object?>.from(payload['entity'] as Map);
    final linkedCount = (payload['purchases'] as List).length;
    final type = entry['entity_type'] as String;
    final title = switch (type) {
      'product' => 'قطعة: ${textOf(entity, 'name')}',
      'supplier' => 'مورد: ${textOf(entity, 'name')}',
      _ => 'عملية شراء',
    };
    final day = (entry['deleted_at'] as String).substring(0, 10);
    final linked = linkedCount == 0
        ? ''
        : ' · $linkedCount عملية شراء مرتبطة';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Surface(
        child: Row(
          children: [
            const Icon(Icons.delete_outline, color: muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'حُذف في ${dateLabel(day)}$linked',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'استعادة',
              onPressed: () async {
                try {
                  await store.restoreTrashEntry(entry['id'] as String);
                  if (context.mounted) {
                    message(context, 'تمت استعادة العنصر');
                  }
                } catch (error) {
                  if (context.mounted) {
                    message(context, errorText(error));
                  }
                }
              },
              icon: const Icon(Icons.restore_outlined, color: teal),
            ),
          ],
        ),
      ),
    );
  }
}

class Tools extends StatefulWidget {
  const Tools({super.key, required this.store});
  final Store store;
  @override
  State<Tools> createState() => _ToolsState();
}

class _ToolsState extends State<Tools> {
  bool busy = false;
  String status = '';
  Future<bool> confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> perform(String label, Future<void> Function() action) async {
    setState(() {
      busy = true;
      status = label;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) message(context, errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<({Uint8List bytes, String name})?> pickFile(
    List<String> extensions,
  ) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
      withData: false,
      allowMultiple: false,
    );
    if (result == null) return null;
    final picked = result.files.single;
    if (picked.size > 100 * 1024 * 1024) {
      throw const FormatException('الملف أكبر من 100 ميجابايت');
    }
    final bytes =
        picked.bytes ??
        (picked.path != null ? await File(picked.path!).readAsBytes() : null);
    if (bytes == null) throw const FormatException('تعذر قراءة الملف المختار');
    return (bytes: bytes, name: picked.name);
  }

  Future<void> saveFile(Uint8List bytes, String prefix) async {
    final date = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'حفظ الملف على الهاتف',
      fileName: '${prefix}_$date.zip',
      type: FileType.custom,
      allowedExtensions: ['zip'],
      bytes: bytes,
    );
    if (path != null && mounted) {
      message(context, 'تم حفظ الملف في المكان الذي اخترته');
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('دفترك ونسخك الاحتياطية')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: navy,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined, color: gold, size: 36),
                  SizedBox(height: 14),
                  Text(
                    'ملكك. وعلى هاتفك.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 25,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 10),
                  Text(
                    'بدون حساب أو اشتراك. كل القطع والصور والمشتريات محفوظة محليًا.',
                    style: TextStyle(color: Color(0xFFCBDAD8), height: 1.8),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'احفظ نسخة خارج الهاتف بانتظام. حذف التطبيق أو فقد الهاتف قد يفقدك البيانات.',
              style: TextStyle(color: muted, height: 1.8),
            ),
            const SizedBox(height: 20),
            tool(
              Icons.delete_sweep_outlined,
              'سلة المحذوفات',
              'استعد ما حذفته خلال 30 يومًا قبل حذفه تلقائيًا.',
              () => page(context, TrashScreen(store: widget.store)),
            ),
            tool(
              Icons.backup_outlined,
              'حفظ نسخة احتياطية',
              'ملف ZIP واحد يشمل قاعدة البيانات وكل الصور.',
              () => perform(
                'تجهيز النسخة الاحتياطية…',
                () async =>
                    saveFile(await widget.store.backup(), 'Daftar_Backup'),
              ),
            ),
            tool(
              Icons.restore_outlined,
              'استعادة نسخة احتياطية',
              'استبدال الدفتر الحالي بنسخة محفوظة.',
              () async {
                if (!await confirm(
                  'استعادة الدفتر؟',
                  'ستُستبدل البيانات الحالية بالنسخة المختارة. احفظ نسخة من دفترك الحالي أولًا إذا كنت تحتاجه. سيتم فحص الملف قبل الاستبدال.',
                  'اختيار نسخة',
                )) {
                  return;
                }
                await perform('فحص النسخة واستعادتها…', () async {
                  final picked = await pickFile(['zip']);
                  if (picked == null) return;
                  await widget.store.restore(picked.bytes);
                  if (context.mounted) {
                    message(context, 'تمت استعادة الدفتر والصور بنجاح');
                  }
                });
              },
            ),
            const SizedBox(height: 14),
            section(
              context,
              'الجداول والملفات',
              'متوافق مع Excel باستخدام CSV',
            ),
            const SizedBox(height: 12),
            tool(
              Icons.table_chart_outlined,
              'تصدير الجداول',
              'ZIP يحتوي على CSV للقطع والموردين والمشتريات، بدون صور.',
              () => perform(
                'تجهيز الجداول…',
                () async =>
                    saveFile(await widget.store.exportCsv(), 'Daftar_CSV'),
              ),
            ),
            tool(
              Icons.upload_file_outlined,
              'استيراد جداول CSV',
              'ملف من قالب التصدير، أو ZIP يحتوي على الجداول الثلاثة.',
              () => perform('قراءة الجداول…', () async {
                final picked = await pickFile(['csv', 'zip']);
                if (picked == null) return;
                final plan = parseCsvImport(picked.bytes, picked.name);
                if (!mounted) return;
                final counts = csvSpecs
                    .where((s) => plan.tables.containsKey(s.table))
                    .map(
                      (s) =>
                          '${{'products': 'قطع', 'suppliers': 'موردون', 'purchases': 'مشتريات'}[s.table]}: ${plan.tables[s.table]!.length}',
                    )
                    .join('\n');
                if (!await confirm(
                  'استيراد ${plan.count} صف؟',
                  '$counts\n\nتُضاف المعرفات الجديدة وتُحدّث المعرفات الموجودة. لا تُحذف بيانات أو صور. يجب أن تشير المشتريات إلى قطع وموردين موجودين.',
                  'استيراد',
                )) {
                  return;
                }
                await widget.store.importCsv(plan);
                if (context.mounted) {
                  message(context, 'تم استيراد الجداول بنجاح');
                }
              }),
            ),
            const SizedBox(height: 20),
            Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  section(
                    context,
                    'معلومات الدفتر',
                    'الإصدار 1.0.1 · العملة: الجنيه المصري',
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'سعر البيع هو السعر الحالي الذي تحدده. آخر شراء يعتمد على تاريخ العملية، مع إبقاء التواريخ المجهولة غير مسجلة. الاتصال الهاتفي اختياري. لا توجد مزامنة سحابية في هذا الإصدار.',
                    style: TextStyle(color: muted, fontSize: 13, height: 1.8),
                  ),
                ],
              ),
            ),
            if (busy) ...[
              const SizedBox(height: 24),
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(status, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    ),
  );
  Widget tool(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Surface(
      onTap: busy ? null : onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: teal, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: muted,
                    fontSize: 12,
                    height: 1.7,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_left, color: muted),
        ],
      ),
    ),
  );
}
