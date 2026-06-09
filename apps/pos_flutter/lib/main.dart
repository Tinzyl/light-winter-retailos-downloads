import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

const defaultBackendUrl = String.fromEnvironment(
  'LIGHT_WINTER_API_URL',
  defaultValue: 'http://192.168.1.233:8000',
);
const defaultSupabaseUrl = String.fromEnvironment(
  'LIGHT_WINTER_SUPABASE_URL',
  defaultValue: 'https://rsnsjfuorfcdpacizsiz.supabase.co',
);
const defaultSupabaseAnonKey = String.fromEnvironment(
  'LIGHT_WINTER_SUPABASE_ANON_KEY',
  defaultValue: 'sb_publishable_y6aXEvjSEoZSk1QtSNYRoA_VfUbo79h',
);
String runtimeSupabaseAnonKey = defaultSupabaseAnonKey;

bool isSupabaseUrl(String value) =>
    value.contains('.supabase.co') || value.contains('.supabase.in');

void main() {
  runApp(const LightWinterPosApp());
}

class LightWinterPosApp extends StatefulWidget {
  const LightWinterPosApp({super.key});

  @override
  State<LightWinterPosApp> createState() => _LightWinterPosAppState();
}

class _LightWinterPosAppState extends State<LightWinterPosApp>
    with WidgetsBindingObserver {
  final AppStore store = AppStore();
  bool loaded = false;
  Timer? licenseTimer;
  Timer? syncTimer;
  String _lastLicenseTickerLabel = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    store.load().then((_) {
      if (!mounted) return;
      setState(() => loaded = true);
      store.refreshStartupCloudInBackground();
    });
    licenseTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && loaded && store.licenseExpiresAt != null) {
        final nextLabel = store.licenseCountdownLabel;
        if (nextLabel != _lastLicenseTickerLabel) {
          _lastLicenseTickerLabel = nextLabel;
          store.notifyListeners();
        }
      }
    });
    final syncInterval = Platform.isWindows
        ? const Duration(minutes: 30)
        : const Duration(minutes: 15);
    syncTimer = Timer.periodic(syncInterval, (_) {
      if (mounted && loaded) store.syncSilently();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    licenseTimer?.cancel();
    syncTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!loaded) return;
    if (Platform.isWindows) {
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      store.markSessionBackgrounded();
    }
    if (state == AppLifecycleState.resumed) {
      store.restoreOrExpireSession();
    }
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF147D72);
    return MaterialApp(
      title: 'Light Winter RetailOS',
      debugShowCheckedModeBanner: false,
      builder: (context, child) => AnimatedBuilder(
        animation: store,
        builder: (context, _) =>
            BusyOverlay(store: store, child: child ?? const SizedBox.shrink()),
      ),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        scaffoldBackgroundColor: const Color(0xFFF6F7F4),
        useMaterial3: true,
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      home: !loaded
          ? const LoadingScreen()
          : AnimatedBuilder(
              animation: store,
              builder: (context, _) {
                if (!store.isProvisioned) {
                  return StartScreen(store: store);
                }
                if (store.currentUser == null) {
                  return LoginScreen(store: store);
                }
                return RetailShell(store: store);
              },
            ),
    );
  }
}

class AppStore extends ChangeNotifier {
  static const storageFileName = 'light_winter_retailos_state_v2.json';
  static const sessionGracePeriod = Duration(minutes: 5);
  String deviceUid = '';

  String backendUrl =
      defaultSupabaseUrl == '' ? defaultBackendUrl : defaultSupabaseUrl;
  String supabaseAnonKey = defaultSupabaseAnonKey;
  String? organizationId;
  String? backendDeviceId;
  String recoveryCode = '';
  String syncStatus = 'Local only';
  Company? company;
  List<BranchProfile> branches = [];
  Map<String, String> activationCodesByBranch = {};
  String? assignedBranchId;
  List<AppUser> users = [];
  List<Product> products = [];
  Map<String, Map<String, int>> branchStockSnapshots = {};
  Map<String, List<SaleRecord>> branchSaleSnapshots = {};
  Set<String> branchStockInitialized = {};
  List<StockTransferRecord> stockTransfers = [];
  List<SaleVoidRecord> saleVoids = [];
  List<AccountingEntry> accountingEntries = [];
  Set<String> pendingSaleSyncIds = {};
  List<Supplier> suppliers = [];
  List<Customer> customers = [];
  List<CartItem> cart = [];
  String activeCartName = 'Customer 1';
  Map<String, List<CartItem>> openCarts = {'Customer 1': []};
  String customerCounterDate = localDateKey(DateTime.now());
  int nextCustomerNumber = 2;
  List<SaleRecord> sales = [];
  String displayCurrency = 'USD';
  String posCurrency = 'USD';
  bool allCatalogueProductsVisible = false;
  Map<String, double> exchangeRates = {
    'USD': 1,
    'ZWL': 25000,
    'ZAR': 18.5,
    'BWP': 13.6,
  };
  AppUser? currentUser;
  String? sessionUsername;
  DateTime? sessionLastSeenAt;
  int fiscalDayNo = 0;
  bool fiscalDayOpen = false;
  DateTime? fiscalDayOpenedAt;
  bool _manualSyncInProgress = false;
  String licenseLabel = 'Not licensed';
  DateTime? licenseExpiresAt;
  DateTime? trustedServerNowAtSync;
  final Stopwatch _trustedClock = Stopwatch()..start();
  bool deviceActive = true;
  String deviceLockMessage = '';
  String lastLoginError = 'Username or PIN is incorrect.';
  bool _syncInProgress = false;
  DateTime? _lastSilentSyncAt;
  int _busyDepth = 0;
  String? busyMessage;

  bool get isProvisioned => company != null;
  bool get fiscalMode => company?.fiscalMode ?? false;
  DateTime get trustedNowUtc =>
      trustedServerNowAtSync?.add(_trustedClock.elapsed).toUtc() ??
      DateTime.now().toUtc();
  bool get isLicensed =>
      deviceActive &&
      licenseExpiresAt != null &&
      licenseExpiresAt!.isAfter(trustedNowUtc);
  String get licenseCountdownLabel =>
      formatLicenseCountdown(licenseExpiresAt, nowUtc: trustedNowUtc);
  bool get isBusy => _busyDepth > 0;

  bool isCustomDatePeriod(String period) => period.startsWith('date:');

  DateTime? customPeriodDate(String period) {
    if (!isCustomDatePeriod(period)) return null;
    return DateTime.tryParse(period.substring(5));
  }

  String customDatePeriod(DateTime date) =>
      'date:${DateTime(date.year, date.month, date.day).toIso8601String().substring(0, 10)}';

  String periodLabel(String period) {
    final custom = customPeriodDate(period);
    if (custom != null) return shortDate(custom);
    return switch (period) {
      'yearly' => 'Yearly',
      'weekly' => 'Weekly',
      'monthly' => 'Monthly',
      _ => 'Daily',
    };
  }

  DateTime periodStart(String period) {
    final custom = customPeriodDate(period);
    if (custom != null) {
      return DateTime(custom.year, custom.month, custom.day);
    }
    final now = DateTime.now();
    return switch (period) {
      'yearly' => DateTime(now.year),
      'weekly' => DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: now.weekday - 1)),
      'monthly' => DateTime(now.year, now.month),
      _ => DateTime(now.year, now.month, now.day),
    };
  }

  bool saleIsInPeriod(SaleRecord sale, String period) {
    final custom = customPeriodDate(period);
    if (custom != null) {
      return businessDate(sale.createdAt) ==
          DateTime(custom.year, custom.month, custom.day);
    }
    final saleDay = businessDate(sale.createdAt);
    final today = businessDate(DateTime.now());
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final weekEnd = weekStart.add(const Duration(days: 6));
    return switch (period) {
      'yearly' => saleDay.year == today.year,
      'monthly' => saleDay.year == today.year && saleDay.month == today.month,
      'weekly' => !saleDay.isBefore(weekStart) && !saleDay.isAfter(weekEnd),
      _ => sameBusinessDay(sale.createdAt, DateTime.now()),
    };
  }

  Future<T> runBusy<T>(String message, Future<T> Function() operation) async {
    _busyDepth += 1;
    busyMessage = message;
    notifyListeners();
    try {
      return await operation();
    } finally {
      _busyDepth = max(0, _busyDepth - 1);
      if (_busyDepth == 0) busyMessage = null;
      notifyListeners();
    }
  }

  BranchProfile? get currentBranch =>
      branches.where((branch) => branch.id == assignedBranchId).firstOrNull ??
      branches.firstOrNull;
  List<BranchProfile> get accessibleBranches {
    final user = currentUser;
    if (user == null) return currentBranch == null ? [] : [currentBranch!];
    if (user.isOwner || user.hasAllPrivileges) return [...branches];
    final allowed = user.branchIds.toSet();
    return branches.where((branch) => allowed.contains(branch.id)).toList();
  }

  bool get hasOpenCartItems =>
      cart.isNotEmpty || openCarts.values.any((items) => items.isNotEmpty);
  int get cartTotalCents => cart.fold(
      0, (sum, item) => sum + item.product.priceCents * item.quantity);
  List<String> get openCartNames => openCarts.keys.toList();
  int get salesTodayCents =>
      sales.fold(0, (sum, sale) => sum + sale.totalCents);
  int get debtCents => sales
      .where((sale) =>
          sale.paymentMethod.toLowerCase() == 'debt' || sale.debtCents > 0)
      .fold(0, (sum, sale) => sum + debtBalanceForSale(sale));
  List<SaleRecord> get debtSales => sales
      .where((sale) =>
          sale.paymentMethod.toLowerCase() == 'debt' || sale.debtCents > 0)
      .toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  List<SaleRecord> get allKnownDebtSales => allKnownSales
      .where((sale) =>
          sale.paymentMethod.toLowerCase() == 'debt' || sale.debtCents > 0)
      .toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  int voidedCentsForSale(String saleId) => saleVoids
      .where((voidRecord) => voidRecord.saleId == saleId)
      .fold(0, (sum, voidRecord) => sum + voidRecord.totalCents);
  int debtBalanceForSale(SaleRecord sale) =>
      max(0, sale.debtCents - voidedCentsForSale(sale.id));
  String debtStatusForSale(SaleRecord sale) {
    final balance = debtBalanceForSale(sale);
    if (balance <= 0) return 'Fully paid';
    if (sale.paidCents > 0) return 'Partially paid';
    return 'Unpaid';
  }

  int voidedQuantityForLine(String saleId, ReceiptLineSnapshot line) =>
      saleVoids
          .where((voidRecord) => voidRecord.saleId == saleId)
          .expand((voidRecord) => voidRecord.lines)
          .where((voidLine) => voidLine.matches(line))
          .fold(0, (sum, voidLine) => sum + voidLine.quantity);
  List<SaleRecord> get allKnownSales {
    final byId = <String, SaleRecord>{};
    for (final sale in sales) {
      byId[sale.id] = sale;
    }
    for (final branchSales in branchSaleSnapshots.values) {
      for (final sale in branchSales) {
        byId[sale.id] = sale;
      }
    }
    return byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  ReportSnapshot reportSnapshot(String period, {required bool allBranches}) {
    final custom = customPeriodDate(period);
    final title = custom != null
        ? 'Report for ${shortDate(custom)}'
        : switch (period) {
            'yearly' => 'Yearly Report',
            'weekly' => 'Weekly Report',
            'monthly' => 'Monthly Report',
            _ => 'Daily Report',
          };
    final source = allBranches ? allKnownSales : sales;
    final scoped = source
        .where((sale) =>
            saleIsInPeriod(sale, period) &&
            (allBranches ||
                sale.branchId.isEmpty ||
                sale.branchId == assignedBranchId))
        .toList();
    final total = scoped.fold(0, (sum, sale) => sum + sale.totalCents);
    final discounts = scoped.fold(0, (sum, sale) => sum + sale.discountCents);
    final debt = scoped.fold(0, (sum, sale) => sum + sale.debtCents);
    final paid = scoped.fold(0, (sum, sale) => sum + sale.paidCents);
    final saleIds = scoped.map((sale) => sale.id).toSet();
    final scopedVoids = saleVoids
        .where((voidRecord) => saleIds.contains(voidRecord.saleId))
        .toList();
    final voided =
        scopedVoids.fold(0, (sum, voidRecord) => sum + voidRecord.totalCents);
    final netTotal = max(0, total - voided);
    final paymentTotal = (String label) => scoped
        .where((sale) => sale.paymentMethod.toLowerCase() == label)
        .fold(0, (sum, sale) => sum + sale.totalCents);
    final productCostById = {
      for (final product in products) product.id: product.costCents
    };
    int costForLine(ReceiptLineSnapshot line) {
      if (line.lineCostCents > 0) return line.lineCostCents;
      final unitCost = productCostById[line.productId] ?? 0;
      return unitCost * line.quantity;
    }

    int netRevenueForLine(SaleRecord sale, ReceiptLineSnapshot line) {
      final subtotal = max(1, sale.subtotalCents);
      final discountShare =
          ((sale.discountCents * line.lineTotalCents) / subtotal).round();
      return max(0, line.lineTotalCents - discountShare);
    }

    final grossCost = scoped.fold(
        0,
        (sum, sale) =>
            sum +
            sale.lines.fold(0, (lineSum, line) => lineSum + costForLine(line)));
    final voidedCost = scopedVoids.fold(
        0,
        (sum, voidRecord) =>
            sum +
            voidRecord.lines
                .fold(0, (lineSum, line) => lineSum + costForLine(line)));
    final netCost = max(0, grossCost - voidedCost);
    final grossProfit = netTotal - netCost;
    final margin = netTotal <= 0 ? 0.0 : (grossProfit / netTotal) * 100;
    int stockQuantityForReport(Product product) {
      if (!allBranches) return max(0, product.stock);
      var totalQty = 0;
      for (final snapshot in branchStockSnapshots.values) {
        totalQty += max(0, snapshot[product.id] ?? 0);
      }
      return totalQty;
    }

    final stockValueAtCost = products.fold(
        0,
        (sum, product) =>
            sum + stockQuantityForReport(product) * product.costCents);
    final stockValueAtRetail = products.fold(
        0,
        (sum, product) =>
            sum + stockQuantityForReport(product) * product.priceCents);
    final sold = <String, ReportProductPerformance>{};
    final performance = <String, UserPerformanceReport>{};
    for (final sale in scoped) {
      final saleBranchName = branchNameForId(sale.branchId);
      final cashier =
          sale.cashier.trim().isEmpty ? 'Unknown user' : sale.cashier;
      final current = performance[cashier] ??
          UserPerformanceReport(
              userName: cashier,
              transactionCount: 0,
              grossCents: 0,
              voidedCents: 0,
              netCents: 0,
              costCents: 0,
              profitCents: 0,
              debtCents: 0);
      final saleVoided = saleVoids
          .where((voidRecord) => voidRecord.saleId == sale.id)
          .fold(0, (sum, voidRecord) => sum + voidRecord.totalCents);
      final saleCost =
          sale.lines.fold(0, (sum, line) => sum + costForLine(line));
      final saleNet = max(0, sale.totalCents - saleVoided);
      performance[cashier] = UserPerformanceReport(
          userName: cashier,
          transactionCount: current.transactionCount + 1,
          grossCents: current.grossCents + sale.totalCents,
          voidedCents: current.voidedCents + saleVoided,
          netCents: current.netCents + saleNet,
          costCents: current.costCents + saleCost,
          profitCents: current.profitCents + (saleNet - saleCost),
          debtCents: current.debtCents + sale.debtCents);
      for (final line in sale.lines) {
        final lineName = saleLineDisplayName(line);
        final revenue = netRevenueForLine(sale, line);
        final cost = costForLine(line);
        final soldKey = allBranches ? '${sale.branchId}|$lineName' : lineName;
        final current = sold[soldKey] ??
            ReportProductPerformance(
                name: lineName,
                branchName: allBranches ? saleBranchName : '',
                quantity: 0,
                revenueCents: 0);
        sold[soldKey] = ReportProductPerformance(
            name: lineName,
            branchName: allBranches ? saleBranchName : '',
            quantity: current.quantity + line.quantity,
            revenueCents: current.revenueCents + revenue,
            costCents: current.costCents + cost,
            profitCents: current.profitCents + (revenue - cost));
      }
    }
    final top = sold.values.toList()
      ..sort((a, b) => b.revenueCents.compareTo(a.revenueCents));
    final slow = products
        .where((product) => !sold.containsKey(product.name))
        .take(8)
        .map((product) => ReportProductPerformance(
            name: product.name, quantity: 0, revenueCents: 0))
        .toList();
    return ReportSnapshot(
      title: title,
      sales: scoped,
      totalSalesCents: netTotal,
      grossSalesCents: total,
      voidedCents: voided,
      discountCents: discounts,
      costOfGoodsCents: netCost,
      grossProfitCents: grossProfit,
      grossMarginPercent: margin,
      stockValueAtCostCents: stockValueAtCost,
      stockValueAtRetailCents: stockValueAtRetail,
      potentialStockProfitCents: stockValueAtRetail - stockValueAtCost,
      debtCents: debt,
      paidCents: paid,
      transactionCount: scoped.length,
      averageSaleCents: scoped.isEmpty ? 0 : (total / scoped.length).round(),
      cashCents: paymentTotal('cash'),
      cardCents: paymentTotal('card'),
      mobileMoneyCents: paymentTotal('mobile money'),
      topProducts: top.take(8).toList(),
      slowProducts: slow,
      userPerformance: performance.values.toList()
        ..sort((a, b) => b.netCents.compareTo(a.netCents)),
    );
  }

  String branchNameForId(String branchId) {
    if (branchId.trim().isEmpty) {
      return currentBranch?.name ?? company?.branchName ?? 'Unknown branch';
    }
    return branches
            .where((branch) => branch.id == branchId)
            .firstOrNull
            ?.name ??
        branchId;
  }

  String saleLineDisplayName(ReceiptLineSnapshot line) {
    final savedName = line.name.trim();
    if (savedName.isNotEmpty && savedName.toLowerCase() != 'product') {
      return savedName;
    }
    if (line.productId.trim().isNotEmpty) {
      final product =
          products.where((item) => item.id == line.productId).firstOrNull;
      if (product != null && product.name.trim().isNotEmpty) {
        return product.name.trim();
      }
    }
    return 'Unknown product';
  }

  List<SaleRecord> salesForCustomer(Customer customer) {
    final name = customer.name.trim().toLowerCase();
    return allKnownSales
        .where((sale) =>
            name.isNotEmpty && sale.customerName.trim().toLowerCase() == name)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  List<SaleRecord> salesForCustomerName(String customerName) {
    final name = customerName.trim().toLowerCase();
    if (name.isEmpty) return [];
    return allKnownSales
        .where((sale) => sale.customerName.trim().toLowerCase() == name)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  SaleRecord? saleById(String saleId) =>
      allKnownSales.where((sale) => sale.id == saleId).firstOrNull;

  bool discountExceedsCashierLimit(int discountCents) {
    final user = currentUser;
    if (discountCents <= 0) return false;
    if (user == null || user.isOwner || user.hasAllPrivileges) return false;
    return discountCents > (cartTotalCents * 0.1).round();
  }

  Map<String, int> get currentBranchStockSnapshot => assignedBranchId == null
      ? {}
      : branchStockSnapshots[assignedBranchId] ?? {};
  List<Product> get currentBranchAssignedProducts {
    final branchId = assignedBranchId;
    if (branchId == null) {
      return [];
    }
    final snapshot = currentBranchStockSnapshot;
    return products
        .where((product) => snapshot.containsKey(product.id))
        .toList();
  }

  bool productAssignedToAnyBranch(Product product) =>
      branchStockSnapshots.values
          .any((snapshot) => snapshot.containsKey(product.id));

  List<Product> get activeCatalogueProducts => products
      .where((product) =>
          productAssignedToAnyBranch(product) ||
          (branchStockInitialized.isEmpty && product.stock > 0))
      .toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  int catalogueStockFor(Product product) {
    if (branchStockInitialized.isEmpty) return product.stock;
    var total = 0;
    var seen = false;
    for (final branchId in branchStockInitialized) {
      final snapshot = branchStockSnapshots[branchId];
      if (snapshot == null || !snapshot.containsKey(product.id)) continue;
      total += snapshot[product.id] ?? 0;
      seen = true;
    }
    return seen ? total : 0;
  }

  int stockViewQuantityFor(Product product) {
    if (catalogueWideViewEnabled) return catalogueStockFor(product);
    final branchId = assignedBranchId;
    if (branchId == null) return 0;
    return branchStockSnapshots[branchId]?[product.id] ?? 0;
  }

  int branchQuantityForPurchase(Product product) {
    final branchId = assignedBranchId;
    if (branchId != null) {
      return max(0, branchStockSnapshots[branchId]?[product.id] ?? 0);
    }
    return 0;
  }

  int sellableQuantityFor(Product product) => allowCatalogueWideSale
      ? catalogueStockFor(product)
      : stockViewQuantityFor(product);
  int branchStockQuantity(String branchId, Product product) {
    return branchStockSnapshots[branchId]?[product.id] ?? 0;
  }

  int branchAssignedProductCount(String branchId) {
    if (branchId == assignedBranchId) return currentBranchStockedProductCount;
    if (!branchStockInitialized.contains(branchId)) return 0;
    final activeProductIds = products.map((product) => product.id).toSet();
    return (branchStockSnapshots[branchId] ?? {})
        .entries
        .where((entry) => activeProductIds.contains(entry.key))
        .map((entry) => entry.value)
        .where((quantity) => quantity > 0)
        .length;
  }

  int branchTotalStockQuantity(String branchId) {
    final activeProductIds = products.map((product) => product.id).toSet();
    return (branchStockSnapshots[branchId] ?? {})
        .entries
        .where((entry) => activeProductIds.contains(entry.key))
        .map((entry) => entry.value)
        .fold(0, (sum, quantity) => sum + max(quantity, 0));
  }

  List<Product> get transferableProducts =>
      products.where((product) => stockViewQuantityFor(product) > 0).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  List<Product> transferableProductsFromBranch(String branchId) => products
      .where((product) => branchStockQuantity(branchId, product) > 0)
      .toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  String branchJoinMessage(BranchProfile branch) {
    final code = activationCodesByBranch[branch.id] ?? '';
    final fiscalLabel = fiscalMode ? 'Fiscal mode' : 'Non-fiscal mode';
    return '''
Light Winter RetailOS device enrollment

Shop: ${company?.shopName ?? ''}
Branch: ${branch.name}
Activation code: $code
Cloud URL: $backendUrl
Mode: $fiscalLabel

Install the Light Winter RetailOS app, choose "Join Existing Shop / Branch", enter the details above, then log in using the username and PIN created by the owner/admin.

Each device still needs its own Light Winter Technologies license voucher after joining.
'''
        .trim();
  }

  List<Product> get branchScopedProducts => catalogueWideViewEnabled
      ? activeCatalogueProducts
      : currentBranchAssignedProducts;
  Set<String> get branchScopedSupplierIds => branchScopedProducts
      .map((product) => product.supplierId)
      .where((id) => id.trim().isNotEmpty)
      .toSet();
  List<Supplier> get branchScopedSuppliers => [...suppliers]
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  int get stockViewProductCount => catalogueWideViewEnabled
      ? activeCatalogueProducts.length
      : currentBranchProductCount;
  int get stockViewCategoryCount => branchScopedProducts
      .map((product) => product.category.trim())
      .where((category) => category.isNotEmpty)
      .toSet()
      .length;
  int get lowStockCount => branchScopedProducts.where((product) {
        final quantity = stockViewQuantityFor(product);
        return quantity > 0 && quantity <= product.reorderLevel;
      }).length;
  int get outOfStockCount => branchScopedProducts
      .where((product) => stockViewQuantityFor(product) <= 0)
      .length;
  int get currentBranchProductCount => currentBranchAssignedProducts.length;
  int get currentBranchStockedProductCount => currentBranchAssignedProducts
      .where(
          (product) => branchStockQuantity(assignedBranchId ?? '', product) > 0)
      .length;
  int get stockViewTotalUnits => catalogueWideViewEnabled
      ? activeCatalogueProducts.fold(
          0, (sum, product) => sum + max(catalogueStockFor(product), 0))
      : branchTotalStockQuantity(assignedBranchId ?? '');
  int get allBranchesTotalUnits => activeCatalogueProducts.fold(
      0, (sum, product) => sum + max(catalogueStockFor(product), 0));
  int get currentBranchTotalUnits =>
      branchTotalStockQuantity(assignedBranchId ?? '');
  int get allBranchesStockedProductCount => activeCatalogueProducts
      .where((product) => catalogueStockFor(product) > 0)
      .length;
  int get stockValueAtAverageCostCents => branchScopedProducts.fold(
      0,
      (sum, product) =>
          sum + max(0, stockViewQuantityFor(product)) * product.costCents);
  int get stockValueAtFifoCostCents {
    var total = 0;
    for (final product in branchScopedProducts) {
      var remaining = max(0, stockViewQuantityFor(product));
      if (remaining <= 0) continue;
      final layers = batchExpiryRecords
          .where((record) =>
              record.productName.toLowerCase() == product.name.toLowerCase() &&
              (catalogueWideViewEnabled ||
                  record.entry.branchId.isEmpty ||
                  record.entry.branchId == assignedBranchId))
          .toList()
        ..sort((a, b) => b.entry.createdAt.compareTo(a.entry.createdAt));
      for (final layer in layers) {
        if (remaining <= 0) break;
        final take = min(remaining, max(0, layer.quantity));
        if (take <= 0) continue;
        final unitCost = layer.quantity <= 0
            ? product.costCents
            : (layer.entry.amountCents / layer.quantity).round();
        total += take * unitCost;
        remaining -= take;
      }
      if (remaining > 0) total += remaining * product.costCents;
    }
    return total;
  }

  List<BatchExpiryRecord> get batchExpiryRecords {
    final records = <BatchExpiryRecord>[];
    for (final entry
        in accountingEntries.where((entry) => entry.isStockPurchase)) {
      final expiry = entry.batchExpiryDate;
      if (expiry == null) continue;
      final productName = entry.batchProductName;
      records.add(BatchExpiryRecord(
          entry: entry,
          productName: productName,
          batchNumber: entry.batchNumber,
          expiryDate: expiry,
          quantity: entry.batchQuantity));
    }
    records.sort((a, b) => a.expiryDate.compareTo(b.expiryDate));
    return records;
  }

  List<BatchExpiryRecord> nearExpiryRecords({int days = 45}) {
    final today = DateTime.now();
    final limit =
        DateTime(today.year, today.month, today.day).add(Duration(days: days));
    return batchExpiryRecords
        .where((record) => !record.expiryDate.isAfter(limit))
        .toList();
  }

  List<AccountingEntry> payrollEntriesForPeriod(String period,
          {required bool allBranches}) =>
      accountingEntriesForPeriod(period, allBranches: allBranches)
          .where((entry) => entry.isPayroll)
          .toList();

  List<AuditRow> auditRows({required bool allBranches}) {
    final rows = <AuditRow>[];
    bool scopedBranch(String branchId) =>
        allBranches ||
        branchId.isEmpty ||
        assignedBranchId == null ||
        branchId == assignedBranchId;
    for (final sale
        in allKnownSales.where((sale) => scopedBranch(sale.branchId))) {
      rows.add(AuditRow(
          when: sale.createdAt,
          action: 'Sale',
          actor: sale.cashier,
          branch: branchNameForId(sale.branchId),
          detail:
              '${sale.paymentMethod} | ${sale.lines.length} lines | ${moneyFor(sale.totalCents)}'));
    }
    for (final item
        in saleVoids.where((voidRecord) => scopedBranch(voidRecord.branchId))) {
      rows.add(AuditRow(
          when: item.createdAt,
          action: item.type.replaceAll('_', ' '),
          actor: item.userName,
          branch: branchNameForId(item.branchId),
          detail: '${item.reason} | ${moneyFor(item.totalCents)}'));
    }
    for (final transfer in stockTransfers.where((item) =>
        scopedBranch(item.fromBranchId) || scopedBranch(item.toBranchId))) {
      rows.add(AuditRow(
          when: transfer.createdAt,
          action: 'Stock transfer',
          actor: transfer.userName,
          branch:
              '${branchNameForId(transfer.fromBranchId)} -> ${branchNameForId(transfer.toBranchId)}',
          detail: '${transfer.productName} x ${transfer.quantity}'));
    }
    for (final entry
        in accountingEntries.where((entry) => scopedBranch(entry.branchId))) {
      rows.add(AuditRow(
          when: entry.createdAt,
          action: entry.category,
          actor: entry.counterparty.isEmpty ? '-' : entry.counterparty,
          branch: branchNameForId(entry.branchId),
          detail: '${entry.description} | ${moneyFor(entry.amountCents)}'));
    }
    rows.sort((a, b) => b.when.compareTo(a.when));
    return rows;
  }

  List<SmartInsight> smartInsights(ReportSnapshot report,
      {required bool allBranches}) {
    final insights = <SmartInsight>[];
    void add(SmartInsight insight) {
      if (insights.length < 8) insights.add(insight);
    }

    if (report.sales.isEmpty) {
      add(const SmartInsight(
          tone: Tone.neutral,
          title: 'No sales in this period',
          body:
              'Record sales first. Insights become stronger when the shop has real sales, stock, and expense history.',
          icon: Icons.auto_awesome));
    }
    if (outOfStockCount > 0) {
      add(SmartInsight(
          tone: Tone.danger,
          title: '$outOfStockCount items out of stock',
          body:
              'Review the Stock section and restock the items that should still be available for selling.',
          icon: Icons.remove_shopping_cart));
    }
    if (lowStockCount > 0) {
      add(SmartInsight(
          tone: Tone.warning,
          title: '$lowStockCount low-stock items',
          body:
              'These products are at or below their reorder threshold. Check fast movers before the next busy period.',
          icon: Icons.warning_amber));
    }
    final expiry = nearExpiryRecords(days: 30);
    if (expiry.isNotEmpty) {
      final first = expiry.first;
      add(SmartInsight(
          tone: first.expired ? Tone.danger : Tone.warning,
          title: '${expiry.length} batch expiry alerts',
          body:
              '${first.productName} ${first.expired ? 'has expired' : 'expires in ${first.daysLeft} days'}. Review batch/expiry tracking in Stock.',
          icon: Icons.event_busy));
    }
    if (report.grossProfitCents < 0 && report.transactionCount > 0) {
      add(SmartInsight(
          tone: Tone.danger,
          title: 'Loss detected',
          body:
              'Recorded cost is higher than net sales in this period. Check selling prices, discounts, and buying costs.',
          icon: Icons.trending_down));
    } else if (report.totalSalesCents > 0 && report.grossMarginPercent < 15) {
      add(SmartInsight(
          tone: Tone.warning,
          title: 'Low gross margin',
          body:
              'Gross margin is ${report.grossMarginPercent.toStringAsFixed(1)}%. Review buying costs, selling prices, and discounts.',
          icon: Icons.percent));
    }
    if (report.grossSalesCents > 0 &&
        report.voidedCents / report.grossSalesCents >= 0.1) {
      add(SmartInsight(
          tone: Tone.warning,
          title: 'High void/return value',
          body:
              'Voids and returns are above 10% of gross sales. Open Customers and Debt to review the transaction history.',
          icon: Icons.assignment_return));
    }
    if (report.grossSalesCents > 0 &&
        report.discountCents / report.grossSalesCents >= 0.1) {
      add(SmartInsight(
          tone: Tone.warning,
          title: 'Discounts are high',
          body:
              'Discounts are above 10% of gross sales. Confirm that only approved staff are giving discounts.',
          icon: Icons.local_offer));
    }
    if (debtCents > 0) {
      add(SmartInsight(
          tone: Tone.warning,
          title: 'Customer debt outstanding',
          body:
              '${moneyFor(debtCents)} is still unpaid. Use customer statements to follow up before debt gets old.',
          icon: Icons.account_balance_wallet));
    }
    if (report.topProducts.isNotEmpty) {
      final top = report.topProducts.first;
      add(SmartInsight(
          tone: Tone.good,
          title: 'Fast mover: ${top.name}',
          body:
              'Sold ${top.quantity} units in this period. Keep this item visible and stocked.',
          icon: Icons.bolt));
    }
    if (report.slowProducts.isNotEmpty) {
      final slow = report.slowProducts.first;
      add(SmartInsight(
          tone: Tone.neutral,
          title: 'Slow mover: ${slow.name}',
          body:
              'No sales recorded for this stocked item in the selected period. Consider checking price or shelf position.',
          icon: Icons.hourglass_bottom));
    }
    return insights;
  }

  bool get canUseCentralCatalogueMode {
    final user = currentUser;
    if (user == null) return false;
    return user.hasAllPrivileges ||
        user.can(AppPermission.branches) ||
        user.can(AppPermission.inventory);
  }

  bool get allowCatalogueWideSale =>
      canUseCentralCatalogueMode && allCatalogueProductsVisible;
  bool get catalogueWideViewEnabled =>
      canUseCentralCatalogueMode && allCatalogueProductsVisible;

  List<Product> stockExportProducts(String filter) {
    final productsForExport = branchScopedProducts.where((product) {
      if (product.isCustom) return false;
      final quantity = stockViewQuantityFor(product);
      return switch (filter) {
        'low' => quantity > 0 && quantity <= product.reorderLevel,
        'out' => quantity <= 0,
        _ => true,
      };
    }).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return productsForExport;
  }

  String stockFilterLabel(String filter) => switch (filter) {
        'low' => 'Low stock',
        'out' => 'Out of stock',
        _ => 'All products',
      };

  String exportCurrentStockCsv({String filter = 'all'}) {
    final branchName = currentBranch?.name ?? 'Unassigned branch';
    final scope = catalogueWideViewEnabled ? 'All branches' : 'Current branch';
    final rows = <List<String>>[
      [
        'Product Name',
        'Product Category',
        'SKU number',
        'Barcode',
        'Cost Price',
        'Selling Price',
        'Initial Stock',
        'Low Stock Threshold',
        'Supplier',
        'Supplier Phone',
        'Branch',
        'Scope'
      ]
    ];
    final exportProducts = stockExportProducts(filter);
    for (final product in exportProducts) {
      final supplier =
          suppliers.where((item) => item.id == product.supplierId).firstOrNull;
      rows.add([
        product.name,
        product.category,
        product.sku,
        product.barcode,
        (product.costCents / 100).toStringAsFixed(2),
        (product.priceCents / 100).toStringAsFixed(2),
        '${stockViewQuantityFor(product)}',
        '${product.reorderLevel}',
        supplier?.name ?? '',
        supplier?.phone ?? '',
        branchName,
        scope
      ]);
    }
    return rows.map(csvLine).join('\r\n');
  }

  String stockReportText({String filter = 'all'}) {
    final branchName = currentBranch?.name ?? 'Unassigned branch';
    final scope = catalogueWideViewEnabled ? 'All branches' : 'Current branch';
    final exportProducts = stockExportProducts(filter);
    final totalPieces = exportProducts.fold<int>(
        0, (sum, product) => sum + max(0, stockViewQuantityFor(product)));
    final stockValue = exportProducts.fold<int>(
        0,
        (sum, product) =>
            sum + max(0, stockViewQuantityFor(product)) * product.priceCents);
    final costValue = exportProducts.fold<int>(
        0,
        (sum, product) =>
            sum + max(0, stockViewQuantityFor(product)) * product.costCents);
    final buffer = StringBuffer()
      ..writeln('Light Winter Technologies')
      ..writeln('${stockFilterLabel(filter)} Stock Report')
      ..writeln('Shop: ${company?.shopName ?? ''}')
      ..writeln('Branch: $branchName')
      ..writeln('Scope: $scope')
      ..writeln('Generated: ${DateTime.now().toLocal()}')
      ..writeln('Products: ${exportProducts.length}')
      ..writeln('Total quantity: $totalPieces')
      ..writeln('Stock value at selling price: ${moneyFor(stockValue)}')
      ..writeln('Stock cost value: ${moneyFor(costValue)}')
      ..writeln()
      ..writeln('Stock Product List');
    for (final product in exportProducts) {
      final quantity = stockViewQuantityFor(product);
      final supplier =
          suppliers.where((item) => item.id == product.supplierId).firstOrNull;
      buffer
        ..writeln(
            '${product.name} | Qty: $quantity | Price: ${moneyFor(product.priceCents)}')
        ..writeln(
            '  Category: ${product.category.isEmpty ? '-' : product.category}')
        ..writeln('  SKU: ${product.sku.isEmpty ? '-' : product.sku}')
        ..writeln(
            '  Barcode: ${product.barcode.isEmpty ? '-' : product.barcode}')
        ..writeln(
            '  Cost: ${moneyFor(product.costCents)} | Threshold: ${product.reorderLevel}')
        ..writeln('  Supplier: ${supplier?.name ?? '-'}')
        ..writeln();
    }
    if (exportProducts.isEmpty) {
      buffer.writeln('No products found for this stock report.');
    }
    return buffer.toString().trim();
  }

  String moneyFor(int cents, {String? currency}) {
    final code = currency ?? displayCurrency;
    final rate = exchangeRates[code] ?? 1;
    final amount = (cents / 100) * rate;
    return '$code ${amount.toStringAsFixed(2)}';
  }

  int displayAmountToBaseCents(String value, {String? currency}) {
    final code = currency ?? displayCurrency;
    final rate = exchangeRates[code] ?? 1;
    final amount = double.tryParse(value.trim().replaceAll(',', '')) ?? 0;
    if (rate <= 0) return 0;
    return ((amount / rate) * 100).round();
  }

  void setDisplayCurrency(String currency) {
    displayCurrency = currency;
    unawaited(save());
    notifyListeners();
  }

  void setPosCurrency(String currency) {
    posCurrency = currency;
    unawaited(save());
    notifyListeners();
  }

  String reportText(ReportSnapshot report, {required bool allBranches}) {
    final scope =
        allBranches ? 'All branches' : currentBranch?.name ?? 'Current branch';
    final buffer = StringBuffer()
      ..writeln('Light Winter RetailOS')
      ..writeln(report.title)
      ..writeln('Shop: ${company?.shopName ?? ''}')
      ..writeln('Scope: $scope')
      ..writeln('Generated: ${DateTime.now()}')
      ..writeln('')
      ..writeln('Gross sales: ${moneyFor(report.grossSalesCents)}')
      ..writeln('Voids/returns: ${moneyFor(report.voidedCents)}')
      ..writeln('Net sales: ${moneyFor(report.totalSalesCents)}')
      ..writeln('Cost of goods sold: ${moneyFor(report.costOfGoodsCents)}')
      ..writeln('Gross profit: ${moneyFor(report.grossProfitCents)}')
      ..writeln(
          'Gross margin: ${report.grossMarginPercent.toStringAsFixed(1)}%')
      ..writeln('Transactions: ${report.transactionCount}')
      ..writeln('Average sale: ${moneyFor(report.averageSaleCents)}')
      ..writeln('Discounts: ${moneyFor(report.discountCents)}')
      ..writeln('Debt recorded: ${moneyFor(report.debtCents)}')
      ..writeln(
          'Stock value at cost: ${moneyFor(report.stockValueAtCostCents)}')
      ..writeln(
          'Stock value at selling price: ${moneyFor(report.stockValueAtRetailCents)}')
      ..writeln(
          'Potential stock profit: ${moneyFor(report.potentialStockProfitCents)}')
      ..writeln('')
      ..writeln('Smart Business Insights');
    final insights = smartInsights(report, allBranches: allBranches);
    if (insights.isEmpty) {
      buffer.writeln('No major insights for this period.');
    } else {
      for (final insight in insights) {
        buffer.writeln('${insight.title}: ${insight.body}');
      }
    }
    buffer
      ..writeln('')
      ..writeln('Payment mix')
      ..writeln('Cash: ${moneyFor(report.cashCents)}')
      ..writeln('Card: ${moneyFor(report.cardCents)}')
      ..writeln('Mobile money: ${moneyFor(report.mobileMoneyCents)}')
      ..writeln('')
      ..writeln('High performing stock');
    if (report.topProducts.isEmpty) {
      buffer.writeln('No product sales recorded in this period.');
    } else {
      for (final product in report.topProducts) {
        buffer.writeln(
            '${product.name}${product.branchName.isEmpty ? '' : ' (${product.branchName})'}: ${product.quantity} sold, sales ${moneyFor(product.revenueCents)}, cost ${moneyFor(product.costCents)}, profit ${moneyFor(product.profitCents)}');
      }
    }
    buffer
      ..writeln('')
      ..writeln('Slow moving stock');
    if (report.slowProducts.isEmpty) {
      buffer.writeln('No slow moving products detected for this period.');
    } else {
      for (final product in report.slowProducts) {
        buffer.writeln('${product.name}: no sales in this period');
      }
    }
    buffer
      ..writeln('')
      ..writeln('User performance');
    if (report.userPerformance.isEmpty) {
      buffer.writeln('No user performance recorded in this period.');
    } else {
      for (final user in report.userPerformance) {
        buffer.writeln(
            '${user.userName}: ${user.transactionCount} sales, gross ${moneyFor(user.grossCents)}, voided ${moneyFor(user.voidedCents)}, net ${moneyFor(user.netCents)}, cost ${moneyFor(user.costCents)}, profit ${moneyFor(user.profitCents)}, debt ${moneyFor(user.debtCents)}');
      }
    }
    buffer
      ..writeln('')
      ..writeln('Transaction details');
    if (report.sales.isEmpty) {
      buffer.writeln('No transactions in this period.');
    } else {
      for (final sale in report.sales) {
        buffer
          ..writeln(
              '${sale.createdAt} | Branch: ${branchNameForId(sale.branchId)} | ${sale.cashier} | ${sale.paymentMethod} | ${moneyFor(sale.totalCents)}')
          ..writeln(
              'Customer: ${sale.customerName.isEmpty ? '-' : sale.customerName}');
        for (final line in sale.lines) {
          buffer.writeln(
              '  ${saleLineDisplayName(line)}: qty ${line.quantity}, selling ${moneyFor(line.lineTotalCents)}, cost ${moneyFor(line.lineCostCents)}, profit ${moneyFor(line.lineTotalCents - line.lineCostCents)}');
        }
      }
    }
    return buffer.toString();
  }

  List<AccountingEntry> accountingEntriesForPeriod(String period,
      {required bool allBranches}) {
    return accountingEntries
        .where((entry) =>
            entryIsInPeriod(entry, period) &&
            (allBranches ||
                entry.branchId.isEmpty ||
                entry.branchId == assignedBranchId))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  bool entryIsInPeriod(AccountingEntry entry, String period) {
    final custom = customPeriodDate(period);
    if (custom != null) {
      return businessDate(entry.createdAt) ==
          DateTime(custom.year, custom.month, custom.day);
    }
    final entryDay = businessDate(entry.createdAt);
    final today = businessDate(DateTime.now());
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final weekEnd = weekStart.add(const Duration(days: 6));
    return switch (period) {
      'yearly' => entryDay.year == today.year,
      'monthly' => entryDay.year == today.year && entryDay.month == today.month,
      'weekly' => !entryDay.isBefore(weekStart) && !entryDay.isAfter(weekEnd),
      _ => sameBusinessDay(entry.createdAt, DateTime.now()),
    };
  }

  ProfitLossStatement profitLossStatement(String period,
      {required bool allBranches}) {
    final report = reportSnapshot(period, allBranches: allBranches);
    final entries =
        accountingEntriesForPeriod(period, allBranches: allBranches);
    final allScopedEntries = accountingEntries
        .where((entry) =>
            allBranches ||
            entry.branchId.isEmpty ||
            entry.branchId == assignedBranchId)
        .toList();
    final expenses = entries.where((entry) =>
        entry.type == AccountingEntryType.expense &&
        entry.affectsProfitAndLoss);
    final incomes = entries.where((entry) =>
        entry.type == AccountingEntryType.income && entry.affectsProfitAndLoss);
    final stockPurchases =
        entries.where((entry) => entry.isStockPurchase).toList();
    final supplierPayments =
        entries.where((entry) => entry.isSupplierPayment).toList();
    final ownerCapital = entries
        .where((entry) => entry.category.toLowerCase() == 'owner capital')
        .fold(0, (sum, entry) => sum + entry.amountCents);
    final ownerDrawings = entries
        .where((entry) => entry.isOwnerDrawing)
        .fold(0, (sum, entry) => sum + entry.amountCents);
    final operatingExpenses =
        expenses.fold(0, (sum, entry) => sum + entry.amountCents);
    final otherIncome =
        incomes.fold(0, (sum, entry) => sum + entry.amountCents);
    final stockPurchaseTotal =
        stockPurchases.fold(0, (sum, entry) => sum + entry.amountCents);
    final supplierPaymentTotal =
        supplierPayments.fold(0, (sum, entry) => sum + entry.amountCents);
    final supplierBalances = supplierBalanceMap(allScopedEntries);
    final supplierPayables = supplierBalances.values
        .where((amount) => amount > 0)
        .fold(0, (sum, amount) => sum + amount);
    final expensesByCategory = <String, int>{};
    for (final entry in expenses) {
      expensesByCategory[entry.category] =
          (expensesByCategory[entry.category] ?? 0) + entry.amountCents;
    }
    final incomeByCategory = <String, int>{};
    for (final entry in incomes) {
      incomeByCategory[entry.category] =
          (incomeByCategory[entry.category] ?? 0) + entry.amountCents;
    }
    final netProfit = report.grossProfitCents + otherIncome - operatingExpenses;
    final netMargin = report.totalSalesCents <= 0
        ? 0.0
        : (netProfit / report.totalSalesCents) * 100;
    return ProfitLossStatement(
        period: period,
        report: report,
        entries: entries,
        operatingExpensesCents: operatingExpenses,
        otherIncomeCents: otherIncome,
        netProfitCents: netProfit,
        netMarginPercent: netMargin,
        stockPurchasesCents: stockPurchaseTotal,
        supplierPaymentsCents: supplierPaymentTotal,
        supplierPayablesCents: supplierPayables,
        customerDebtOutstandingCents: debtCents,
        ownerCapitalCents: ownerCapital,
        ownerDrawingsCents: ownerDrawings,
        supplierBalances: supplierBalances,
        cashbookByMethod: cashbookByMethod(period, allBranches: allBranches),
        customerDebtAging: customerDebtAging(),
        expensesByCategory: expensesByCategory,
        incomeByCategory: incomeByCategory);
  }

  Map<String, int> supplierBalanceMap(List<AccountingEntry> entries) {
    final balances = <String, int>{};
    for (final entry in entries) {
      final supplier = entry.counterparty.trim().isEmpty
          ? 'Unknown supplier'
          : entry.counterparty.trim();
      if (entry.isStockPurchase) {
        balances[supplier] = (balances[supplier] ?? 0) + entry.amountCents;
      } else if (entry.isSupplierPayment) {
        balances[supplier] = (balances[supplier] ?? 0) - entry.amountCents;
      }
    }
    return balances;
  }

  Map<String, int> cashbookByMethod(String period,
      {required bool allBranches}) {
    final start = periodStart(period);
    final scopedSales = (allBranches ? allKnownSales : sales)
        .where((sale) => !sale.createdAt.isBefore(start));
    final result = <String, int>{
      'Cash in': 0,
      'Card in': 0,
      'Mobile money in': 0,
      'Bank in': 0,
      'Cash out': 0,
      'Mobile money out': 0,
      'Bank out': 0,
    };
    for (final sale in scopedSales) {
      final method = sale.paymentMethod.toLowerCase();
      final paid = max(0, sale.paidCents - sale.changeCents);
      if (paid <= 0) continue;
      if (method.contains('card')) {
        result['Card in'] = result['Card in']! + paid;
      } else if (method.contains('mobile')) {
        result['Mobile money in'] = result['Mobile money in']! + paid;
      } else {
        result['Cash in'] = result['Cash in']! + paid;
      }
    }
    for (final entry
        in accountingEntriesForPeriod(period, allBranches: allBranches)) {
      final method = entry.paymentMethod.toLowerCase();
      if (entry.isOwnerDrawing ||
          entry.isSupplierPayment ||
          entry.affectsProfitAndLoss) {
        final key = method.contains('bank')
            ? 'Bank out'
            : method.contains('mobile')
                ? 'Mobile money out'
                : 'Cash out';
        result[key] = result[key]! + entry.amountCents;
      } else if (entry.type == AccountingEntryType.income) {
        final key = method.contains('bank')
            ? 'Bank in'
            : method.contains('mobile')
                ? 'Mobile money in'
                : 'Cash in';
        result[key] = result[key]! + entry.amountCents;
      }
    }
    return result;
  }

  Map<String, int> customerDebtAging() {
    final result = <String, int>{
      '0-7 days': 0,
      '8-30 days': 0,
      '31-60 days': 0,
      'Over 60 days': 0,
    };
    final now = DateTime.now();
    for (final sale in debtSales) {
      final balance = debtBalanceForSale(sale);
      if (balance <= 0) continue;
      final days = now.difference(sale.createdAt).inDays;
      final bucket = days <= 7
          ? '0-7 days'
          : days <= 30
              ? '8-30 days'
              : days <= 60
                  ? '31-60 days'
                  : 'Over 60 days';
      result[bucket] = result[bucket]! + balance;
    }
    return result;
  }

  String profitLossText(ProfitLossStatement statement,
      {required bool allBranches}) {
    final scope =
        allBranches ? 'All branches' : currentBranch?.name ?? 'Current branch';
    final buffer = StringBuffer()
      ..writeln('Light Winter RetailOS')
      ..writeln('Profit and Loss Statement')
      ..writeln('Shop: ${company?.shopName ?? ''}')
      ..writeln('Scope: $scope')
      ..writeln('Period: ${statement.title}')
      ..writeln('Generated: ${DateTime.now()}')
      ..writeln('')
      ..writeln('Revenue')
      ..writeln(
          'Gross recorded sales: ${moneyFor(statement.report.grossSalesCents)}')
      ..writeln('Voids / returns: ${moneyFor(statement.report.voidedCents)}')
      ..writeln('Discounts: ${moneyFor(statement.report.discountCents)}')
      ..writeln('Net sales: ${moneyFor(statement.report.totalSalesCents)}')
      ..writeln('Other income: ${moneyFor(statement.otherIncomeCents)}')
      ..writeln('Owner capital: ${moneyFor(statement.ownerCapitalCents)}')
      ..writeln('')
      ..writeln('Cost of Sales')
      ..writeln(
          'Cost of goods sold: ${moneyFor(statement.report.costOfGoodsCents)}')
      ..writeln('Stock purchases: ${moneyFor(statement.stockPurchasesCents)}')
      ..writeln('Gross profit: ${moneyFor(statement.report.grossProfitCents)}')
      ..writeln(
          'Gross margin: ${statement.report.grossMarginPercent.toStringAsFixed(1)}%')
      ..writeln('')
      ..writeln('Operating Expenses')
      ..writeln(
          'Total expenses: ${moneyFor(statement.operatingExpensesCents)}');
    if (statement.expensesByCategory.isEmpty) {
      buffer.writeln('No operating expenses recorded.');
    } else {
      for (final entry in statement.expensesByCategory.entries) {
        buffer.writeln('${entry.key}: ${moneyFor(entry.value)}');
      }
    }
    buffer
      ..writeln('')
      ..writeln('Net Profit / Loss')
      ..writeln('Owner drawings: ${moneyFor(statement.ownerDrawingsCents)}')
      ..writeln('Net profit: ${moneyFor(statement.netProfitCents)}')
      ..writeln('Net margin: ${statement.netMarginPercent.toStringAsFixed(1)}%')
      ..writeln('')
      ..writeln('Supplier and Customer Balances')
      ..writeln('Supplier bills: ${moneyFor(statement.stockPurchasesCents)}')
      ..writeln(
          'Supplier payments: ${moneyFor(statement.supplierPaymentsCents)}')
      ..writeln('Supplier owing: ${moneyFor(statement.supplierPayablesCents)}')
      ..writeln(
          'Customer debt outstanding: ${moneyFor(statement.customerDebtOutstandingCents)}')
      ..writeln('')
      ..writeln('Stock Position')
      ..writeln(
          'Stock value at cost: ${moneyFor(statement.report.stockValueAtCostCents)}')
      ..writeln(
          'Stock value at selling price: ${moneyFor(statement.report.stockValueAtRetailCents)}')
      ..writeln(
          'Potential stock profit: ${moneyFor(statement.report.potentialStockProfitCents)}')
      ..writeln(
          'Average-cost valuation: ${moneyFor(stockValueAtAverageCostCents)}')
      ..writeln('FIFO layer valuation: ${moneyFor(stockValueAtFifoCostCents)}');
    final expiryRows = nearExpiryRecords();
    buffer
      ..writeln('')
      ..writeln('Batch / Expiry Watch');
    if (expiryRows.isEmpty) {
      buffer.writeln('No expired or near-expiry batches in the next 45 days.');
    } else {
      for (final record in expiryRows.take(40)) {
        buffer.writeln(
            '${record.productName} | Batch ${record.batchNumber.isEmpty ? '-' : record.batchNumber} | Qty ${record.quantity} | Expiry ${shortDate(record.expiryDate)} | ${record.expired ? 'Expired' : '${record.daysLeft} days left'}');
      }
    }
    final payrollRows =
        statement.entries.where((entry) => entry.isPayroll).toList();
    buffer
      ..writeln('')
      ..writeln('Payroll / HR');
    if (payrollRows.isEmpty) {
      buffer.writeln('No payroll recorded in this period.');
    } else {
      for (final entry in payrollRows.take(80)) {
        buffer.writeln(
            '${shortDate(entry.createdAt)} | ${entry.counterparty} | ${entry.description} | ${moneyFor(entry.amountCents)}');
      }
    }
    buffer
      ..writeln('')
      ..writeln('Cashbook Summary');
    for (final entry in statement.cashbookByMethod.entries) {
      buffer.writeln('${entry.key}: ${moneyFor(entry.value)}');
    }
    buffer
      ..writeln('')
      ..writeln('Debt Aging');
    for (final entry in statement.customerDebtAging.entries) {
      buffer.writeln('${entry.key}: ${moneyFor(entry.value)}');
    }
    buffer
      ..writeln('')
      ..writeln('Expense / Income Register');
    if (statement.entries.isEmpty) {
      buffer.writeln('No manual accounting entries recorded.');
    } else {
      for (final entry in statement.entries.take(200)) {
        buffer.writeln(
            '${shortDateTime(entry.createdAt)} | ${entry.typeLabel} | ${entry.category} | ${moneyFor(entry.amountCents)} | ${entry.description}');
      }
    }
    return buffer.toString();
  }

  Future<void> addAccountingEntry(AccountingEntry entry) async {
    if (_busyDepth == 0) {
      return runBusy(
          'Saving accounting entry...', () => addAccountingEntry(entry));
    }
    accountingEntries.insert(0, entry);
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncAccountingEntryCreate(entry));
    }
  }

  Future<void> recordStockPurchase({
    required Product? product,
    required String productName,
    required String supplierName,
    required int quantity,
    required int totalCents,
    required int paidCents,
    required String paymentMethod,
    String batchNumber = '',
    DateTime? expiryDate,
  }) async {
    if (_busyDepth == 0) {
      return runBusy(
          'Recording stock purchase...',
          () => recordStockPurchase(
              product: product,
              productName: productName,
              supplierName: supplierName,
              quantity: quantity,
              totalCents: totalCents,
              paidCents: paidCents,
              paymentMethod: paymentMethod,
              batchNumber: batchNumber,
              expiryDate: expiryDate));
    }
    final cleanSupplier =
        supplierName.trim().isEmpty ? 'Unknown supplier' : supplierName.trim();
    final purchaseName = product?.name ??
        (productName.trim().isEmpty ? 'stock purchase' : productName.trim());
    if (product != null && quantity > 0) {
      final unitCost = (totalCents / quantity).round();
      final beforeQuantity = branchQuantityForPurchase(product);
      final newQuantity = beforeQuantity + quantity;
      final previousValue = beforeQuantity * product.costCents;
      final weightedCost = newQuantity <= 0
          ? unitCost
          : ((previousValue + totalCents) / newQuantity).round();
      product.stock = newQuantity;
      if (weightedCost > 0) product.costCents = weightedCost;
      _markCurrentBranchStockInitialized();
      if (organizationId != null && currentBranch != null) {
        unawaited(_syncProductUpdate(product, currentBranch!.id));
      }
    }
    final details = <String>[
      if (quantity > 0) '$quantity x $purchaseName' else purchaseName,
      if (batchNumber.trim().isNotEmpty) 'Batch: ${batchNumber.trim()}',
      if (expiryDate != null) 'Expiry: ${shortDate(expiryDate)}',
    ].join(' | ');
    await addAccountingEntry(AccountingEntry(
        id: newId(),
        branchId: assignedBranchId ?? '',
        type: AccountingEntryType.expense,
        category: 'Stock Purchase',
        description: details,
        amountCents: totalCents,
        paymentMethod:
            paidCents >= totalCents ? paymentMethod : 'Supplier debt',
        counterparty: cleanSupplier,
        createdAt: DateTime.now()));
    final appliedPayment = min(max(0, paidCents), totalCents);
    if (appliedPayment > 0) {
      await addAccountingEntry(AccountingEntry(
          id: newId(),
          branchId: assignedBranchId ?? '',
          type: AccountingEntryType.expense,
          category: 'Supplier Payment',
          description: 'Payment for $purchaseName',
          amountCents: appliedPayment,
          paymentMethod: paymentMethod,
          counterparty: cleanSupplier,
          createdAt: DateTime.now()));
    }
    syncStatus = 'Stock purchase recorded.';
    await save();
    notifyListeners();
  }

  Future<void> recordStockCount({
    required Product product,
    required int countedQuantity,
    required String reason,
  }) async {
    if (_busyDepth == 0) {
      return runBusy(
          'Recording stock count...',
          () => recordStockCount(
              product: product,
              countedQuantity: countedQuantity,
              reason: reason));
    }
    final before = stockViewQuantityFor(product);
    final delta = countedQuantity - before;
    product.stock = countedQuantity;
    _markCurrentBranchStockInitialized();
    await addAccountingEntry(AccountingEntry(
        id: newId(),
        branchId: assignedBranchId ?? '',
        type: AccountingEntryType.expense,
        category: 'Stock Count',
        description:
            '${product.name}: counted $countedQuantity, system $before, difference $delta. ${reason.trim()}',
        amountCents: (delta.abs() * product.costCents),
        paymentMethod: 'Stock adjustment',
        counterparty: currentUser?.name ?? '',
        createdAt: DateTime.now()));
    if (organizationId != null && currentBranch != null) {
      unawaited(_syncProductUpdate(product, currentBranch!.id));
    }
    syncStatus = 'Stock count recorded.';
    await save();
    notifyListeners();
  }

  String customerStatementText(SaleRecord sale) {
    final related = debtSales.where((item) {
      if (sale.customerName.trim().isEmpty) return item.id == sale.id;
      return item.customerName.trim().toLowerCase() ==
          sale.customerName.trim().toLowerCase();
    }).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final totalDebt =
        related.fold(0, (sum, item) => sum + debtBalanceForSale(item));
    final buffer = StringBuffer()
      ..writeln('Light Winter RetailOS')
      ..writeln('Customer Statement')
      ..writeln('Shop: ${company?.shopName ?? ''}')
      ..writeln(
          'Customer: ${sale.customerName.isEmpty ? 'Customer' : sale.customerName}')
      ..writeln('Generated: ${DateTime.now()}')
      ..writeln('')
      ..writeln('Outstanding balance: ${moneyFor(totalDebt)}')
      ..writeln('')
      ..writeln('Debt History');
    for (final item in related) {
      buffer.writeln(
          '${shortDateTime(item.createdAt)} | Sale ${item.id} | Total ${moneyFor(item.totalCents)} | Paid ${moneyFor(item.paidCents)} | Balance ${moneyFor(debtBalanceForSale(item))} | ${debtStatusForSale(item)}');
    }
    return buffer.toString();
  }

  String customerPurchaseHistoryText(String customerName) {
    final related = salesForCustomerName(customerName);
    final total = related.fold(0, (sum, item) => sum + item.totalCents);
    final debt = related.fold(0, (sum, item) => sum + debtBalanceForSale(item));
    final buffer = StringBuffer()
      ..writeln('Light Winter RetailOS')
      ..writeln('Customer Purchase History')
      ..writeln('Shop: ${company?.shopName ?? ''}')
      ..writeln(
          'Customer: ${customerName.trim().isEmpty ? 'Customer' : customerName.trim()}')
      ..writeln('Generated: ${DateTime.now()}')
      ..writeln('')
      ..writeln('Total purchases: ${moneyFor(total)}')
      ..writeln('Outstanding debt: ${moneyFor(debt)}')
      ..writeln('')
      ..writeln('Transactions');
    for (final item in related) {
      final lines = item.lines
          .map((line) => '${line.quantity}x ${saleLineDisplayName(line)}')
          .join(', ');
      buffer.writeln(
          '${shortDateTime(item.createdAt)} | ${branchNameForId(item.branchId)} | ${item.paymentMethod} | ${item.cashier} | ${moneyFor(item.totalCents)} | ${lines.isEmpty ? 'No line detail' : lines}');
    }
    return buffer.toString();
  }

  String debtLedgerText(List<SaleRecord> debts) {
    final total = debts.fold(0, (sum, item) => sum + item.totalCents);
    final paid = debts.fold(0, (sum, item) => sum + item.paidCents);
    final balance =
        debts.fold(0, (sum, item) => sum + debtBalanceForSale(item));
    final buffer = StringBuffer()
      ..writeln('Light Winter RetailOS')
      ..writeln('Debt Ledger')
      ..writeln('Shop: ${company?.shopName ?? ''}')
      ..writeln('Branch: ${currentBranch?.name ?? 'All visible branches'}')
      ..writeln('Generated: ${DateTime.now()}')
      ..writeln('')
      ..writeln('Debt sales total: ${moneyFor(total)}')
      ..writeln('Paid so far: ${moneyFor(paid)}')
      ..writeln('Outstanding: ${moneyFor(balance)}')
      ..writeln('')
      ..writeln('Ledger');
    for (final sale in debts) {
      buffer.writeln(
          '${shortDateTime(sale.createdAt)} | ${branchNameForId(sale.branchId)} | ${sale.customerName.isEmpty ? 'Customer' : sale.customerName} | Sale ${sale.id} | Total ${moneyFor(sale.totalCents)} | Paid ${moneyFor(sale.paidCents)} | Balance ${moneyFor(debtBalanceForSale(sale))} | ${debtStatusForSale(sale)} | Cashier ${sale.cashier}');
    }
    return buffer.toString();
  }

  String supplierStatementText(String supplierName) {
    final clean = supplierName.trim();
    final entries = accountingEntries
        .where((entry) =>
            entry.counterparty.trim().toLowerCase() == clean.toLowerCase() &&
            (entry.isStockPurchase || entry.isSupplierPayment))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final balance = supplierBalanceMap(entries)[clean] ?? 0;
    final buffer = StringBuffer()
      ..writeln('Light Winter RetailOS')
      ..writeln('Supplier Statement')
      ..writeln('Shop: ${company?.shopName ?? ''}')
      ..writeln('Supplier: ${clean.isEmpty ? 'Supplier' : clean}')
      ..writeln('Generated: ${DateTime.now()}')
      ..writeln('')
      ..writeln('Balance owing: ${moneyFor(balance)}')
      ..writeln('')
      ..writeln('Purchases and Payments');
    for (final entry in entries) {
      buffer.writeln(
          '${shortDateTime(entry.createdAt)} | ${entry.category} | ${entry.description} | ${moneyFor(entry.amountCents)} | ${entry.paymentMethod}');
    }
    return buffer.toString();
  }

  Future<void> _syncAccountingEntryCreate(AccountingEntry entry) async {
    final orgId = organizationId;
    if (orgId == null) return;
    try {
      await ApiClient(backendUrl).createAccountingEntry(
          orgId, assignedBranchId ?? currentBranch?.id ?? '', deviceUid, entry);
      syncStatus = 'Accounting entry synced.';
    } catch (error) {
      syncStatus = 'Accounting entry saved locally: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> deleteAccountingEntry(AccountingEntry entry) async {
    if (_busyDepth == 0) {
      return runBusy(
          'Deleting accounting entry...', () => deleteAccountingEntry(entry));
    }
    accountingEntries.removeWhere((item) => item.id == entry.id);
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncAccountingEntryDelete(entry.id));
    }
  }

  Future<void> _syncAccountingEntryDelete(String entryId) async {
    try {
      await ApiClient(backendUrl).deleteAccountingEntry(deviceUid, entryId);
      syncStatus = 'Accounting entry deleted from cloud.';
    } catch (error) {
      syncStatus = 'Accounting entry deleted locally: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> deleteAllAccountingEntries({required bool allBranches}) async {
    if (_busyDepth == 0) {
      return runBusy('Deleting accounting entries...',
          () => deleteAllAccountingEntries(allBranches: allBranches));
    }
    final branchId = assignedBranchId;
    final deleteIds = accountingEntries
        .where((entry) =>
            allBranches || branchId == null || entry.branchId == branchId)
        .map((entry) => entry.id)
        .toSet();
    accountingEntries.removeWhere((entry) => deleteIds.contains(entry.id));
    syncStatus = allBranches
        ? 'All accounting entries deleted locally.'
        : 'This branch accounting entries deleted locally.';
    await save();
    notifyListeners();
    if (organizationId != null && deleteIds.isNotEmpty) {
      unawaited(_syncAccountingEntryBulkDelete(deleteIds.toList()));
    }
  }

  Future<void> _syncAccountingEntryBulkDelete(List<String> entryIds) async {
    try {
      final api = ApiClient(backendUrl);
      for (final entryId in entryIds) {
        await api.deleteAccountingEntry(deviceUid, entryId);
      }
      syncStatus = 'Accounting entries deleted from cloud.';
    } catch (error) {
      syncStatus = 'Accounting entries deleted locally: $error';
    }
    await save();
    notifyListeners();
  }

  String backupText() {
    final buffer = StringBuffer()
      ..writeln('Light Winter RetailOS Recovery Summary')
      ..writeln('Shop: ${company?.shopName ?? ''}')
      ..writeln('Device: $deviceUid')
      ..writeln('Owner recovery code: $recoveryCode')
      ..writeln('Branch: ${currentBranch?.name ?? ''}')
      ..writeln('Generated: ${DateTime.now()}')
      ..writeln('')
      ..writeln('Branches: ${branches.length}')
      ..writeln('Users: ${users.length}')
      ..writeln('Products: ${products.length}')
      ..writeln('Suppliers: ${suppliers.length}')
      ..writeln('Customers: ${customers.length}')
      ..writeln('Sales cached: ${allKnownSales.length}')
      ..writeln('Void/reversal records: ${saleVoids.length}')
      ..writeln('Stock transfer records: ${stockTransfers.length}')
      ..writeln('Synced branch stock tables: ${branchStockSnapshots.length}')
      ..writeln('')
      ..writeln(
          'This recovery summary covers local cached operating data. Supabase remains the shared cloud database for all synced devices and branches.');
    return buffer.toString();
  }

  Future<File> createJsonBackupFile() async {
    if (_busyDepth == 0) {
      return runBusy('Creating backup...', createJsonBackupFile);
    }
    await save();
    final state = await _stateFile();
    final directory = await getApplicationDocumentsDirectory();
    final rawStamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9A-Za-z]'), '');
    final stamp = rawStamp.substring(0, min(14, rawStamp.length));
    final backup = File(
        '${directory.path}${Platform.pathSeparator}light-winter-backup-$stamp.json');
    await backup.writeAsString(await state.readAsString());
    return backup;
  }

  Future<void> setCatalogueVisibilityMode(bool showAllCatalogue) async {
    allCatalogueProductsVisible =
        canUseCentralCatalogueMode && showAllCatalogue;
    await save();
    notifyListeners();
  }

  Future<void> updateExchangeRates(
      Map<String, double> rates, String currency) async {
    if (_busyDepth == 0) {
      return runBusy('Saving exchange rates...',
          () => updateExchangeRates(rates, currency));
    }
    exchangeRates = {...exchangeRates, ...rates};
    displayCurrency = currency;
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncExchangeRates());
    }
  }

  Future<void> _syncExchangeRates() async {
    final orgId = organizationId;
    if (orgId == null) return;
    try {
      final data = await ApiClient(backendUrl).updateExchangeRates(
          orgId, deviceUid, exchangeRates, displayCurrency);
      _applyBootstrap(data);
      syncStatus = 'Exchange rates synced to all devices.';
    } catch (error) {
      syncStatus = 'Exchange rates saved locally: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> updateCloudSettings(String serverUrl, String anonKey) async {
    if (serverUrl.trim().isNotEmpty) backendUrl = serverUrl.trim();
    if (anonKey.trim().isNotEmpty) {
      supabaseAnonKey = anonKey.trim();
    }
    _applyBuiltInCloudFallbacks();
    await save();
    notifyListeners();
  }

  void _applyBuiltInCloudFallbacks() {
    if (backendUrl.trim().isEmpty && defaultSupabaseUrl.trim().isNotEmpty) {
      backendUrl = defaultSupabaseUrl;
    }
    if (supabaseAnonKey.trim().isEmpty &&
        defaultSupabaseAnonKey.trim().isNotEmpty) {
      supabaseAnonKey = defaultSupabaseAnonKey;
    }
    runtimeSupabaseAnonKey = supabaseAnonKey.trim().isEmpty
        ? defaultSupabaseAnonKey
        : supabaseAnonKey.trim();
  }

  Future<void> useBuiltInCloudSettings() async {
    if (defaultSupabaseUrl.trim().isNotEmpty) backendUrl = defaultSupabaseUrl;
    if (defaultSupabaseAnonKey.trim().isNotEmpty) {
      supabaseAnonKey = defaultSupabaseAnonKey;
    }
    _applyBuiltInCloudFallbacks();
    await save();
    notifyListeners();
  }

  Future<void> load() async {
    final file = await _stateFile();
    if (!await file.exists()) {
      deviceUid = _newDeviceUid();
      _applyBuiltInCloudFallbacks();
      await save();
      return;
    }
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      deviceUid = _newDeviceUid();
      _applyBuiltInCloudFallbacks();
      await save();
      return;
    }
    final data = jsonDecode(raw) as Map<String, dynamic>;
    deviceUid = data['deviceUid'] ?? _newDeviceUid();
    backendUrl = data['backendUrl'] ?? backendUrl;
    supabaseAnonKey = data['supabaseAnonKey'] ?? supabaseAnonKey;
    _applyBuiltInCloudFallbacks();
    organizationId = data['organizationId'];
    backendDeviceId = data['backendDeviceId'];
    recoveryCode = data['recoveryCode'] ?? recoveryCode;
    syncStatus = data['syncStatus'] ?? syncStatus;
    company =
        data['company'] == null ? null : Company.fromJson(data['company']);
    branches = ((data['branches'] ?? []) as List)
        .map((item) => BranchProfile.fromJson(item))
        .toList();
    activationCodesByBranch =
        Map<String, String>.from(data['activationCodesByBranch'] ?? {});
    if (branches.isEmpty && company != null) {
      branches = [
        BranchProfile(
            id: newId(),
            name: company!.branchName,
            address: company!.address,
            phone: company!.phone)
      ];
    }
    assignedBranchId = data['assignedBranchId'] ?? branches.firstOrNull?.id;
    users = ((data['users'] ?? []) as List)
        .map((item) => AppUser.fromJson(item))
        .toList();
    products = ((data['products'] ?? []) as List)
        .map((item) => Product.fromJson(item))
        .toList();
    branchStockSnapshots = {
      for (final entry
          in Map<String, dynamic>.from(data['branchStockSnapshots'] ?? {})
              .entries)
        entry.key: Map<String, int>.from(Map<String, dynamic>.from(entry.value)
            .map((key, value) => MapEntry(key, value as int)))
    };
    branchSaleSnapshots = {
      for (final entry
          in Map<String, dynamic>.from(data['branchSaleSnapshots'] ?? {})
              .entries)
        entry.key: ((entry.value ?? []) as List)
            .map((item) => SaleRecord.fromJson(item))
            .toList()
    };
    branchStockInitialized =
        Set<String>.from(data['branchStockInitialized'] ?? []);
    stockTransfers = ((data['stockTransfers'] ?? []) as List)
        .map((item) =>
            StockTransferRecord.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    saleVoids = ((data['saleVoids'] ?? []) as List)
        .map((item) => SaleVoidRecord.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    accountingEntries = ((data['accountingEntries'] ?? []) as List)
        .map(
            (item) => AccountingEntry.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    pendingSaleSyncIds = Set<String>.from(data['pendingSaleSyncIds'] ?? []);
    _migrateLegacyBranchStockIfNeeded();
    if (assignedBranchId != null) _restoreBranchSnapshot(assignedBranchId!);
    suppliers = ((data['suppliers'] ?? []) as List)
        .map((item) => Supplier.fromJson(item))
        .toList();
    customers = ((data['customers'] ?? []) as List)
        .map((item) => Customer.fromJson(item))
        .toList();
    sales = ((data['sales'] ?? []) as List)
        .map((item) => SaleRecord.fromJson(item))
        .toList();
    activeCartName = data['activeCartName'] ?? activeCartName;
    openCarts = {
      for (final entry
          in Map<String, dynamic>.from(data['openCarts'] ?? {}).entries)
        entry.key: ((entry.value ?? []) as List)
            .map((item) => CartItem.fromJson(
                Map<String, dynamic>.from(item as Map), products))
            .toList()
    };
    if (openCarts.isEmpty) openCarts = {'Customer 1': []};
    if (!openCarts.containsKey(activeCartName)) {
      activeCartName = openCarts.keys.first;
    }
    cart = _cloneCart(openCarts[activeCartName] ?? []);
    customerCounterDate = data['customerCounterDate'] ?? customerCounterDate;
    nextCustomerNumber = data['nextCustomerNumber'] ?? nextCustomerNumber;
    _ensureCustomerCounterDay();
    displayCurrency = data['displayCurrency'] ?? displayCurrency;
    if (data['posCurrency'] == null) {
      posCurrency = displayCurrency;
      displayCurrency = 'USD';
    } else {
      posCurrency = data['posCurrency'] ?? posCurrency;
    }
    allCatalogueProductsVisible =
        data['allCatalogueProductsVisible'] ?? allCatalogueProductsVisible;
    exchangeRates = {
      ...exchangeRates,
      ...Map<String, dynamic>.from(data['exchangeRates'] ?? {}).map(
        (key, value) => MapEntry(key, (value as num).toDouble()),
      ),
    };
    fiscalDayNo = data['fiscalDayNo'] ?? 0;
    fiscalDayOpen = data['fiscalDayOpen'] ?? false;
    fiscalDayOpenedAt = data['fiscalDayOpenedAt'] == null
        ? null
        : DateTime.tryParse(data['fiscalDayOpenedAt']);
    licenseLabel = data['licenseLabel'] ?? 'Not licensed';
    licenseExpiresAt = data['licenseExpiresAt'] == null
        ? null
        : DateTime.tryParse(data['licenseExpiresAt'])?.toUtc();
    deviceActive = data['deviceActive'] ?? deviceActive;
    deviceLockMessage = data['deviceLockMessage'] ?? deviceLockMessage;
    trustedServerNowAtSync = data['trustedServerNowAtSync'] == null
        ? trustedServerNowAtSync
        : DateTime.tryParse(data['trustedServerNowAtSync'])?.toUtc();
    sessionUsername = data['sessionUsername'];
    sessionLastSeenAt = data['sessionLastSeenAt'] == null
        ? null
        : DateTime.tryParse(data['sessionLastSeenAt'])?.toUtc();
    _trustedClock
      ..reset()
      ..start();
    restoreOrExpireSession(notify: false);
  }

  void refreshStartupCloudInBackground() {
    if (!isSupabaseUrl(backendUrl) || deviceUid.trim().isEmpty) return;
    unawaited(_refreshStartupCloud());
  }

  Future<void> _refreshStartupCloud() async {
    if (_syncInProgress) return;
    _syncInProgress = true;
    try {
      final cloud = await ApiClient(backendUrl).bootstrap(deviceUid);
      _applyBootstrap(cloud);
      syncStatus = 'Cloud license checkpoint loaded.';
      await save();
      notifyListeners();
    } catch (_) {
      // Startup must stay instant; login/manual sync handles visible errors.
    } finally {
      _syncInProgress = false;
    }
  }

  Future<void> save() async {
    final file = await _stateFile();
    await file.writeAsString(
      jsonEncode({
        'company': company?.toJson(),
        'deviceUid': deviceUid,
        'backendUrl': backendUrl,
        'supabaseAnonKey': supabaseAnonKey.trim().isEmpty
            ? defaultSupabaseAnonKey
            : supabaseAnonKey,
        'organizationId': organizationId,
        'backendDeviceId': backendDeviceId,
        'recoveryCode': recoveryCode,
        'syncStatus': syncStatus,
        'branches': branches.map((item) => item.toJson()).toList(),
        'activationCodesByBranch': activationCodesByBranch,
        'assignedBranchId': assignedBranchId,
        'users': users.map((item) => item.toJson()).toList(),
        'products': products.map((item) => item.toJson()).toList(),
        'branchStockSnapshots': branchStockSnapshots,
        'branchSaleSnapshots': branchSaleSnapshots.map((key, value) =>
            MapEntry(key, value.map((item) => item.toJson()).toList())),
        'branchStockInitialized': branchStockInitialized.toList(),
        'stockTransfers': stockTransfers.map((item) => item.toJson()).toList(),
        'saleVoids': saleVoids.map((item) => item.toJson()).toList(),
        'accountingEntries':
            accountingEntries.map((item) => item.toJson()).toList(),
        'pendingSaleSyncIds': pendingSaleSyncIds.toList(),
        'suppliers': suppliers.map((item) => item.toJson()).toList(),
        'customers': customers.map((item) => item.toJson()).toList(),
        'sales': sales.map((item) => item.toJson()).toList(),
        'activeCartName': activeCartName,
        'openCarts': openCarts.map((key, value) =>
            MapEntry(key, value.map((item) => item.toJson()).toList())),
        'customerCounterDate': customerCounterDate,
        'nextCustomerNumber': nextCustomerNumber,
        'displayCurrency': displayCurrency,
        'posCurrency': posCurrency,
        'allCatalogueProductsVisible': allCatalogueProductsVisible,
        'exchangeRates': exchangeRates,
        'fiscalDayNo': fiscalDayNo,
        'fiscalDayOpen': fiscalDayOpen,
        'fiscalDayOpenedAt': fiscalDayOpenedAt?.toIso8601String(),
        'licenseLabel': licenseLabel,
        'licenseExpiresAt': licenseExpiresAt?.toIso8601String(),
        'deviceActive': deviceActive,
        'deviceLockMessage': deviceLockMessage,
        'trustedServerNowAtSync': trustedServerNowAtSync?.toIso8601String(),
        'sessionUsername': sessionUsername,
        'sessionLastSeenAt': sessionLastSeenAt?.toIso8601String(),
      }),
    );
  }

  Future<File> _stateFile() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      return File('${directory.path}${Platform.pathSeparator}$storageFileName');
    } catch (_) {
      // Fall back for unusual desktop/test environments where platform paths are unavailable.
    }
    final candidates = [
      File(
          '${Directory.current.path}${Platform.pathSeparator}$storageFileName'),
      File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}$storageFileName'),
    ];
    for (final file in candidates) {
      try {
        if (!await file.parent.exists()) {
          await file.parent.create(recursive: true);
        }
        final probe = File('${file.path}.probe');
        await probe.writeAsString('ok');
        await probe.delete();
        return file;
      } catch (_) {
        continue;
      }
    }
    return candidates.last;
  }

  Future<void> setup({
    required String shopName,
    required String branchName,
    required String ownerName,
    required String ownerUsername,
    required String ownerPin,
    required bool fiscalMode,
    List<UserDraft> extraUsers = const [],
    List<BranchDraft> extraBranches = const [],
    String? phone,
    String? address,
    String? serverUrl,
    String? serverAnonKey,
  }) async {
    if (_busyDepth == 0) {
      return runBusy(
          'Creating shop...',
          () => setup(
                shopName: shopName,
                branchName: branchName,
                ownerName: ownerName,
                ownerUsername: ownerUsername,
                ownerPin: ownerPin,
                fiscalMode: fiscalMode,
                extraUsers: extraUsers,
                extraBranches: extraBranches,
                phone: phone,
                address: address,
                serverUrl: serverUrl,
                serverAnonKey: serverAnonKey,
              ));
    }
    if ((serverUrl ?? '').trim().isNotEmpty) backendUrl = serverUrl!.trim();
    if ((serverAnonKey ?? '').trim().isNotEmpty) {
      supabaseAnonKey = serverAnonKey!.trim();
      runtimeSupabaseAnonKey = supabaseAnonKey;
    }
    if (isSupabaseUrl(backendUrl)) {
      await ApiClient(backendUrl).testSupabase();
    }
    company = Company(
        shopName: shopName,
        branchName: branchName,
        phone: phone ?? '',
        address: address ?? '',
        fiscalMode: fiscalMode);
    final firstBranch = BranchProfile(
        id: newId(),
        name: branchName,
        address: address ?? '',
        phone: phone ?? '');
    branches = [
      firstBranch,
      ...extraBranches.map((branch) => BranchProfile(
          id: newId(),
          name: branch.name,
          address: branch.address,
          phone: branch.phone))
    ];
    assignedBranchId = firstBranch.id;
    users = [
      AppUser(
          name: ownerName,
          username: ownerUsername,
          role: 'Owner',
          pin: ownerPin,
          permissions: AppPermission.all,
          branchIds: [])
    ];
    for (final draft in extraUsers) {
      users.add(AppUser(
          name: draft.name,
          username: draft.username,
          role: draft.role,
          pin: draft.pin,
          permissions: draft.permissions,
          branchIds:
              draft.branchIds.isEmpty ? [firstBranch.id] : draft.branchIds));
    }
    products = [];
    suppliers = [];
    branchStockSnapshots = {firstBranch.id: {}};
    branchStockInitialized = {firstBranch.id};
    try {
      final data = await ApiClient(backendUrl).createShop(
        shopName: shopName,
        mainBranch: firstBranch,
        fiscalMode: fiscalMode,
        owner: users.first,
        users: users.skip(1).toList(),
        branches: branches.skip(1).toList(),
        deviceUid: deviceUid,
      );
      _applyBootstrap(data);
      syncStatus = 'Synced with shared database';
    } catch (error) {
      if (isSupabaseUrl(backendUrl)) {
        company = null;
        branches = [];
        assignedBranchId = null;
        users = [];
        products = [];
        syncStatus = 'Supabase setup failed: $error';
        await save();
        notifyListeners();
        rethrow;
      }
      syncStatus = 'Offline setup saved: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> joinExistingShop({
    required String shopName,
    required String branchName,
    required String activationCode,
    required bool fiscalMode,
    String? serverUrl,
    String? serverAnonKey,
  }) async {
    if (_busyDepth == 0) {
      return runBusy(
          'Joining shop...',
          () => joinExistingShop(
                shopName: shopName,
                branchName: branchName,
                activationCode: activationCode,
                fiscalMode: fiscalMode,
                serverUrl: serverUrl,
                serverAnonKey: serverAnonKey,
              ));
    }
    if ((serverUrl ?? '').trim().isNotEmpty) backendUrl = serverUrl!.trim();
    if ((serverAnonKey ?? '').trim().isNotEmpty) {
      supabaseAnonKey = serverAnonKey!.trim();
      runtimeSupabaseAnonKey = supabaseAnonKey;
    }
    final branch = BranchProfile(id: newId(), name: branchName);
    company = Company(
        shopName: shopName, branchName: branchName, fiscalMode: fiscalMode);
    branches = [branch];
    assignedBranchId = branch.id;
    users = [];
    licenseLabel = 'Pending owner activation $activationCode';
    try {
      final data = await ApiClient(backendUrl)
          .joinShop(activationCode: activationCode, deviceUid: deviceUid);
      _applyBootstrap(data);
      syncStatus = 'Joined shared database';
    } catch (error) {
      if (isSupabaseUrl(backendUrl)) {
        company = null;
        branches = [];
        assignedBranchId = null;
        users = [];
        licenseLabel = 'Not licensed';
        syncStatus = 'Supabase join failed: $error';
        await save();
        notifyListeners();
        rethrow;
      }
      syncStatus = 'Join pending/offline: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> recoverExistingShop({
    required String recoveryCode,
    required String ownerUsername,
    required String ownerPin,
    String? serverUrl,
    String? serverAnonKey,
  }) async {
    if (_busyDepth == 0) {
      return runBusy(
          'Recovering shop...',
          () => recoverExistingShop(
                recoveryCode: recoveryCode,
                ownerUsername: ownerUsername,
                ownerPin: ownerPin,
                serverUrl: serverUrl,
                serverAnonKey: serverAnonKey,
              ));
    }
    if ((serverUrl ?? '').trim().isNotEmpty) backendUrl = serverUrl!.trim();
    if ((serverAnonKey ?? '').trim().isNotEmpty) {
      supabaseAnonKey = serverAnonKey!.trim();
      runtimeSupabaseAnonKey = supabaseAnonKey;
    }
    try {
      final data = await ApiClient(backendUrl).recoverShop(recoveryCode.trim(),
          ownerUsername.trim(), ownerPin.trim(), deviceUid);
      _applyBootstrap(data);
      syncStatus = 'Shop recovered from Supabase. Apply this device license.';
      await save();
      notifyListeners();
    } catch (error) {
      syncStatus = 'Recovery failed: $error';
      await save();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> recoverCurrentDeviceFromCloud() async {
    if (_busyDepth == 0) {
      return runBusy(
          'Recovering this device...', recoverCurrentDeviceFromCloud);
    }
    await useBuiltInCloudSettings();
    final data = await ApiClient(backendUrl).bootstrap(deviceUid);
    _applyBootstrap(data);
    syncStatus = 'Device recovered from cloud.';
    await save();
    notifyListeners();
  }

  Future<void> recoverPreviousDeviceIdFromCloud(
      String previousDeviceUid) async {
    final cleanUid = previousDeviceUid.trim().toUpperCase();
    if (!RegExp(r'^LWR-[0-9A-Z]{3,}$').hasMatch(cleanUid)) {
      throw StateError(
          'Enter the old Device ID exactly, for example LWR-123456.');
    }
    if (_busyDepth == 0) {
      return runBusy('Recovering previous device ID...',
          () => recoverPreviousDeviceIdFromCloud(cleanUid));
    }
    await useBuiltInCloudSettings();
    final data = await ApiClient(backendUrl).bootstrap(cleanUid);
    deviceUid = cleanUid;
    _applyBootstrap(data);
    syncStatus =
        'Previous Device ID restored. This device is now using $cleanUid.';
    await save();
    notifyListeners();
  }

  Future<Map<String, dynamic>> resetOwnerAccess({
    required String recoveryCode,
    required String resetVoucher,
    String newPin = '',
  }) async {
    if (_busyDepth == 0) {
      return runBusy(
          'Resetting owner access...',
          () => resetOwnerAccess(
              recoveryCode: recoveryCode,
              resetVoucher: resetVoucher,
              newPin: newPin));
    }
    final result = await ApiClient(backendUrl)
        .resetOwnerAccess(recoveryCode, deviceUid, resetVoucher, newPin);
    final data = await ApiClient(backendUrl).bootstrap(deviceUid);
    _applyBootstrap(data);
    syncStatus = 'Owner access reset completed.';
    await save();
    notifyListeners();
    return result;
  }

  Future<void> syncNow() async {
    if (_busyDepth == 0) return runBusy('Syncing cloud data...', syncNow);
    if (_manualSyncInProgress || _syncInProgress) {
      syncStatus = 'Sync already running. Stock is safe.';
      await save();
      notifyListeners();
      return;
    }
    _manualSyncInProgress = true;
    try {
      await _retryPendingSales();
      final data = await ApiClient(backendUrl).bootstrap(deviceUid);
      _applyBootstrap(data);
      syncStatus = 'Synced ${DateTime.now().toLocal()}';
    } catch (error) {
      final message = cleanError(error);
      if (message.toLowerCase().contains('deactivated') ||
          message.toLowerCase().contains('not activated')) {
        deviceActive = false;
        deviceLockMessage =
            'This device has been deactivated. Contact Light Winter Technologies.';
        currentUser = null;
      }
      syncStatus = 'Sync failed: $message';
      rethrow;
    } finally {
      _manualSyncInProgress = false;
    }
    await save();
    notifyListeners();
  }

  Future<void> syncSilently() async {
    if (_syncInProgress ||
        isBusy ||
        company == null ||
        organizationId == null ||
        currentUser == null) {
      return;
    }
    final now = DateTime.now();
    if (_lastSilentSyncAt != null &&
        now.difference(_lastSilentSyncAt!) < const Duration(minutes: 15)) {
      return;
    }
    _lastSilentSyncAt = now;
    _syncInProgress = true;
    try {
      await _retryPendingSales();
      final data = await ApiClient(backendUrl).bootstrap(deviceUid);
      _applyBootstrap(data);
      syncStatus = 'Synced ${DateTime.now().toLocal()}';
      await save();
      notifyListeners();
    } catch (_) {
      // Keep offline-first use smooth for network errors; login/manual sync handles lockout errors.
    } finally {
      _syncInProgress = false;
    }
  }

  Future<void> _retryPendingSales() async {
    if (pendingSaleSyncIds.isEmpty) return;
    final pendingIds = pendingSaleSyncIds.toList();
    for (final saleId in pendingIds) {
      final sale = sales.where((item) => item.id == saleId).firstOrNull;
      if (sale == null) {
        pendingSaleSyncIds.remove(saleId);
        continue;
      }
      final saleLines = sale.lines
          .map((line) => CartItem(
              product: Product(
                id: line.productId,
                name: line.name,
                sku: '',
                barcode: '',
                priceCents: line.unitPriceCents,
                costCents: line.unitCostCents,
                stock: line.quantity,
                reorderLevel: 0,
                isCustom: line.productId.startsWith('CUSTOM-'),
              ),
              quantity: line.quantity))
          .toList();
      final customerId = sale.customerName.trim().isEmpty
          ? null
          : customers
              .where((customer) =>
                  customer.name.toLowerCase() ==
                  sale.customerName.toLowerCase())
              .firstOrNull
              ?.id;
      await ApiClient(backendUrl).createSale(deviceUid, currentUser?.id,
          customerId, sale.paymentMethod, saleLines, sale.totalCents,
          saleId: sale.id,
          discountCents: sale.discountCents,
          paidCents: sale.paidCents,
          changeCents: sale.changeCents,
          debtCents: sale.debtCents);
      pendingSaleSyncIds.remove(saleId);
    }
  }

  Future<void> testCloudConnection(String serverUrl,
      {String? serverAnonKey}) async {
    if ((serverAnonKey ?? '').trim().isNotEmpty) {
      supabaseAnonKey = serverAnonKey!.trim();
      runtimeSupabaseAnonKey = supabaseAnonKey;
    }
    final client = ApiClient(serverUrl.trim());
    if (client.usesSupabase) {
      await client.testSupabase();
      return;
    }
    await client.healthCheck();
  }

  void _applyBootstrap(Map<String, dynamic> data) {
    final previousAssignedBranchId = assignedBranchId;
    final localCurrentBranchStockBeforeBootstrap =
        previousAssignedBranchId == null
            ? <String, int>{}
            : Map<String, int>.from(
                branchStockSnapshots[previousAssignedBranchId] ?? const {});
    organizationId = data['organization_id'];
    backendDeviceId = data['device_id'];
    deviceActive = data['device_active'] ?? true;
    deviceLockMessage = data['device_lock_message'] ?? '';
    recoveryCode = data['recovery_code'] ?? recoveryCode;
    assignedBranchId = data['assigned_branch_id'];
    licenseLabel = data['license_label'] ?? licenseLabel;
    licenseExpiresAt = data['license_expires_at'] == null
        ? null
        : DateTime.tryParse('${data['license_expires_at']}')?.toUtc();
    final serverNow = data['server_now'] == null
        ? null
        : DateTime.tryParse('${data['server_now']}')?.toUtc();
    if (serverNow != null) {
      trustedServerNowAtSync = serverNow;
      _trustedClock
        ..reset()
        ..start();
    }
    company = Company(
      shopName: data['shop_name'] ?? company?.shopName ?? '',
      branchName: '',
      phone: data['shop_phone'] ?? company?.phone ?? '',
      address: data['shop_address'] ?? company?.address ?? '',
      fiscalMode: data['fiscal_mode'] == 'fiscal',
      registeredName: data['registered_name'] ?? company?.registeredName ?? '',
      tin: data['tin'] ?? company?.tin ?? '',
      vatNumber: data['vat_number'] ?? company?.vatNumber ?? '',
      zimraDeviceId: data['zimra_device_id'] ?? company?.zimraDeviceId ?? '',
      fiscalSerialNumber:
          data['fiscal_serial_number'] ?? company?.fiscalSerialNumber ?? '',
      fiscalQrUrl: data['fiscal_qr_url'] ?? company?.fiscalQrUrl ?? '',
    );
    fiscalDayNo = data['fiscal_day_no'] ?? fiscalDayNo;
    fiscalDayOpen = data['fiscal_day_open'] ?? fiscalDayOpen;
    fiscalDayOpenedAt = data['fiscal_day_opened_at'] == null
        ? fiscalDayOpenedAt
        : DateTime.tryParse('${data['fiscal_day_opened_at']}')?.toLocal();
    branches = ((data['branches'] ?? []) as List)
        .map((item) => BranchProfile.fromApi(item))
        .toList();
    activationCodesByBranch = {
      for (final item in ((data['activation_codes'] ?? []) as List))
        if (item['branch_id'] != null && item['code'] != null)
          '${item['branch_id']}': '${item['code']}'
    };
    final localUserBranchIds = {
      for (final user in users) user.username.toLowerCase(): [...user.branchIds]
    };
    users = ((data['users'] ?? []) as List)
        .map((item) => AppUser.fromApi(item))
        .toList();
    for (final user in users) {
      if (user.branchIds.isEmpty) {
        user.branchIds = localUserBranchIds[user.username.toLowerCase()] ?? [];
      }
    }
    final localProductsBeforeBootstrap = [...products];
    final localCustomersBeforeBootstrap = [...customers];
    final localSuppliersBeforeBootstrap = [...suppliers];
    final localTransfersBeforeBootstrap = [...stockTransfers];
    final localVoidsBeforeBootstrap = [...saleVoids];
    final localAccountingBeforeBootstrap = [...accountingEntries];
    final localSalesBeforeBootstrap = [...sales];
    final localProductStockBeforeBootstrap = {
      for (final product in localProductsBeforeBootstrap)
        product.id: max(product.stock,
            localCurrentBranchStockBeforeBootstrap[product.id] ?? 0)
    };
    final stockItems = ((data['stock'] ?? []) as List);
    final currentStockRows = <String, int>{
      for (final item in stockItems)
        if ('${item['branch_id']}' == assignedBranchId)
          '${item['product_id']}': item['quantity'] ?? 0
    };
    final currentBranchCloudHasPositiveStock =
        currentStockRows.values.any((quantity) => quantity > 0);
    if (!currentBranchCloudHasPositiveStock) {
      for (final entry in localProductStockBeforeBootstrap.entries) {
        if (entry.value <= 0) continue;
        currentStockRows[entry.key] =
            max(currentStockRows[entry.key] ?? 0, entry.value);
      }
    }
    int localStockForIncomingProduct(Map<String, dynamic> item) {
      final id = '${item['id'] ?? ''}';
      return localProductStockBeforeBootstrap[id] ?? 0;
    }

    final incomingProducts = ((data['products'] ?? []) as List)
        .map((item) => Product.fromApi(
            item,
            max(currentStockRows['${item['id']}'] ?? 0,
                localStockForIncomingProduct(Map<String, dynamic>.from(item)))))
        .toList();
    final incomingProductIds = incomingProducts.map((item) => item.id).toSet();
    final mergedById = {
      for (final product in incomingProducts) product.id: product
    };
    for (final localProduct in localProductsBeforeBootstrap) {
      if (incomingProductIds.contains(localProduct.id)) continue;
      final localStock = localProductStockBeforeBootstrap[localProduct.id] ?? 0;
      if (localStock > 0 ||
          branchStockSnapshots.values
              .any((snapshot) => snapshot.containsKey(localProduct.id))) {
        mergedById[localProduct.id] = localProduct;
      }
    }
    products = mergedById.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final incomingCustomers = ((data['customers'] ?? []) as List)
        .map((item) => Customer.fromApi(item))
        .toList();
    customers = mergeById<Customer>(
        localCustomersBeforeBootstrap, incomingCustomers, (item) => item.id);
    if (data['suppliers'] != null) {
      final incomingSuppliers = ((data['suppliers'] ?? []) as List)
          .map((item) => Supplier.fromApi(Map<String, dynamic>.from(item)))
          .toList();
      suppliers = mergeById<Supplier>(
          localSuppliersBeforeBootstrap, incomingSuppliers, (item) => item.id);
    }
    if (data['exchange_rates'] != null) {
      exchangeRates = {
        ...exchangeRates,
        ...Map<String, dynamic>.from(data['exchange_rates']).map(
          (key, value) => MapEntry(key, (value as num).toDouble()),
        )
      };
    }
    displayCurrency = data['display_currency'] ?? displayCurrency;
    final incomingTransfers = ((data['stock_transfers'] ?? []) as List)
        .map((item) =>
            StockTransferRecord.fromApi(Map<String, dynamic>.from(item)))
        .toList();
    stockTransfers = mergeById<StockTransferRecord>(
        localTransfersBeforeBootstrap, incomingTransfers, (item) => item.id)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final incomingVoids = ((data['sale_voids'] ?? []) as List)
        .map((item) => SaleVoidRecord.fromApi(Map<String, dynamic>.from(item)))
        .toList();
    saleVoids = mergeById<SaleVoidRecord>(
        localVoidsBeforeBootstrap, incomingVoids, (item) => item.id)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final incomingAccounting = ((data['accounting_entries'] ?? []) as List)
        .map(
            (item) => AccountingEntry.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    accountingEntries = mergeById<AccountingEntry>(
        localAccountingBeforeBootstrap, incomingAccounting, (item) => item.id)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final incomingSales = ((data['sales'] ?? []) as List)
        .map((item) => SaleRecord.fromApi(item))
        .toList();
    final cloudSaleIds = incomingSales.map((sale) => sale.id).toSet();
    pendingSaleSyncIds.removeWhere(cloudSaleIds.contains);
    sales = mergeById<SaleRecord>(
        localSalesBeforeBootstrap, incomingSales, (item) => item.id)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final salesByBranch = <String, List<SaleRecord>>{};
    for (final sale in sales) {
      if (sale.branchId.isEmpty) continue;
      salesByBranch.putIfAbsent(sale.branchId, () => []).add(sale);
    }
    for (final entry in salesByBranch.entries) {
      branchSaleSnapshots[entry.key] = entry.value;
    }
    final activeProductIds = products.map((product) => product.id).toSet();
    final stockByBranch = <String, Map<String, int>>{};
    final branchProductActivity = <String, Set<String>>{};
    void markBranchProductActivity(String branchId, String productId) {
      if (branchId.trim().isEmpty || productId.trim().isEmpty) return;
      branchProductActivity
          .putIfAbsent(branchId, () => <String>{})
          .add(productId);
    }

    for (final sale in sales) {
      for (final line in sale.lines) {
        markBranchProductActivity(sale.branchId, line.productId);
      }
    }
    for (final transfer in stockTransfers) {
      markBranchProductActivity(transfer.fromBranchId, transfer.productId);
      markBranchProductActivity(transfer.toBranchId, transfer.productId);
    }
    for (final entry
        in accountingEntries.where((entry) => entry.isStockPurchase)) {
      final productName = entry.batchProductName.trim().toLowerCase();
      if (productName.isEmpty) continue;
      final product = products
          .where((item) => item.name.trim().toLowerCase() == productName)
          .firstOrNull;
      if (product != null) {
        markBranchProductActivity(entry.branchId, product.id);
      }
    }
    for (final item in stockItems) {
      final branchId = '${item['branch_id']}';
      final productId = '${item['product_id']}';
      if (!activeProductIds.contains(productId)) continue;
      final quantity = item['quantity'] ?? 0;
      stockByBranch.putIfAbsent(branchId, () => {})[productId] = quantity;
    }
    if (assignedBranchId != null &&
        !currentBranchCloudHasPositiveStock &&
        localProductStockBeforeBootstrap.values
            .any((quantity) => quantity > 0)) {
      final canonicalLocalStock = <String, int>{};
      for (final product in products) {
        final stock = localProductStockBeforeBootstrap[product.id] ?? 0;
        if (stock > 0) canonicalLocalStock[product.id] = stock;
      }
      stockByBranch[assignedBranchId!] = {
        ...?stockByBranch[assignedBranchId!],
        for (final entry in canonicalLocalStock.entries)
          if (entry.value > 0)
            entry.key: max(
                stockByBranch[assignedBranchId!]?[entry.key] ?? 0, entry.value)
      };
    }
    for (final branch in branches) {
      final cleanSnapshot = stockByBranch[branch.id] ?? <String, int>{};
      branchStockSnapshots[branch.id] = cleanSnapshot;
      if (cleanSnapshot.isEmpty) {
        branchStockInitialized.remove(branch.id);
      } else {
        branchStockInitialized.add(branch.id);
      }
    }
    if (currentUser != null) {
      currentUser = users
              .where((user) =>
                  user.id == currentUser!.id ||
                  user.username.toLowerCase() ==
                      currentUser!.username.toLowerCase())
              .firstOrNull ??
          currentUser;
    }
    if (assignedBranchId != null) {
      if (stockByBranch.containsKey(assignedBranchId!)) {
        branchStockSnapshots[assignedBranchId!] =
            stockByBranch[assignedBranchId!]!;
        branchStockInitialized.add(assignedBranchId!);
      } else if (!branchStockSnapshots.containsKey(assignedBranchId!)) {
        branchStockSnapshots[assignedBranchId!] = <String, int>{};
      }
      sales = [...(branchSaleSnapshots[assignedBranchId!] ?? sales)];
      _restoreBranchSnapshot(assignedBranchId!);
    }
    if (branches.isNotEmpty)
      company!.branchName = currentBranch?.name ?? branches.first.name;
  }

  void _migrateLegacyBranchStockIfNeeded() {
    if (branchStockInitialized.isNotEmpty ||
        products.isEmpty ||
        branches.isEmpty) {
      return;
    }
    final mainBranchId = branches.first.id;
    final mainSnapshot = branchStockSnapshots[mainBranchId] ??
        {for (final product in products) product.id: product.stock};
    final hasStock = mainSnapshot.values.any((quantity) => quantity > 0) ||
        products.any((product) => product.stock > 0);
    branchStockSnapshots.clear();
    if (hasStock) {
      branchStockSnapshots[mainBranchId] = {
        for (final product in products)
          product.id: mainSnapshot[product.id] ?? product.stock
      };
      branchStockInitialized.add(mainBranchId);
    }
  }

  void _captureCurrentBranchSnapshot({bool force = false}) {
    final branchId = assignedBranchId;
    if (branchId == null) return;
    final existing = branchStockSnapshots[branchId] ?? const <String, int>{};
    final branchWasInitialized =
        branchStockInitialized.contains(branchId) || existing.isNotEmpty;
    final snapshot = <String, int>{};
    for (final product in products) {
      final previousAssigned = existing.containsKey(product.id);
      if (previousAssigned || (!branchWasInitialized && product.stock > 0)) {
        snapshot[product.id] = product.stock;
      }
    }
    final hasStock = snapshot.values.any((quantity) => quantity > 0);
    if (!force && existing.isEmpty && !hasStock) {
      branchStockSnapshots.remove(branchId);
      branchSaleSnapshots[branchId] = [...sales];
      return;
    }
    branchStockSnapshots[branchId] = snapshot;
    if (force || snapshot.isNotEmpty || hasStock) {
      branchStockInitialized.add(branchId);
    }
    branchSaleSnapshots[branchId] = [...sales];
  }

  void _markCurrentBranchStockInitialized() {
    final branchId = assignedBranchId;
    if (branchId == null) return;
    branchStockInitialized.add(branchId);
    _captureCurrentBranchSnapshot(force: true);
  }

  void _assignProductToCurrentBranch(Product product, {int? quantity}) {
    final branchId = assignedBranchId;
    if (branchId == null) return;
    final snapshot = branchStockSnapshots.putIfAbsent(branchId, () => {});
    snapshot[product.id] = quantity ?? product.stock;
    branchStockInitialized.add(branchId);
  }

  void _markBranchStockInitialized(String branchId, Map<String, int> snapshot) {
    branchStockInitialized.add(branchId);
    branchStockSnapshots[branchId] = snapshot;
  }

  void _restoreBranchSnapshot(String branchId) {
    final stock = branchStockInitialized.contains(branchId)
        ? branchStockSnapshots[branchId]
        : null;
    for (final product in products) {
      product.stock = stock?[product.id] ?? 0;
    }
    sales = [...(branchSaleSnapshots[branchId] ?? [])];
  }

  void _clearBranchWorkingSession() {
    cart.clear();
    openCarts = {'Customer 1': []};
    activeCartName = 'Customer 1';
    allCatalogueProductsVisible = false;
  }

  Future<bool> login(String username, String pin) async {
    lastLoginError = 'Username or PIN is incorrect.';
    if (!deviceActive) {
      lastLoginError = deviceLockMessage.isEmpty
          ? 'This device has been deactivated. Contact Light Winter Technologies.'
          : deviceLockMessage;
      return false;
    }
    if (users.isEmpty) return false;
    final normalized = username.trim().toLowerCase();
    var user = users
        .where((item) =>
            item.username.toLowerCase() == normalized && item.pin == pin)
        .firstOrNull;
    if (user == null) return false;
    if (!user.canLoginAtBranch(assignedBranchId)) {
      lastLoginError =
          '${user.name} is not assigned to ${currentBranch?.name ?? 'this branch'}. Ask the owner to edit branch access.';
      return false;
    }
    currentUser = user;
    sessionUsername = user.username;
    sessionLastSeenAt = DateTime.now().toUtc();
    unawaited(save());
    notifyListeners();
    if (Platform.isWindows && isSupabaseUrl(backendUrl)) {
      try {
        await _refreshLoginCloud(normalized, pin)
            .timeout(const Duration(seconds: 4));
      } catch (_) {
        // Keep local login available; the startup/manual sync path will refresh
        // the trusted license checkpoint when the connection is available.
      }
    } else {
      unawaited(_refreshLoginCloud(normalized, pin));
    }
    return true;
  }

  Future<void> _refreshLoginCloud(String normalizedUsername, String pin) async {
    if (!isSupabaseUrl(backendUrl)) return;
    try {
      final data = await ApiClient(backendUrl).bootstrap(deviceUid);
      _applyBootstrap(data);
      final user = users
          .where((item) =>
              item.username.toLowerCase() == normalizedUsername &&
              item.pin == pin)
          .firstOrNull;
      if (user != null && user.canLoginAtBranch(assignedBranchId)) {
        currentUser = user;
        sessionUsername = user.username;
        sessionLastSeenAt = DateTime.now().toUtc();
      }
      await save();
      notifyListeners();
    } catch (error) {
      final message = cleanError(error);
      syncStatus = 'Cloud refresh failed: $message';
      if (message.toLowerCase().contains('deactivated') ||
          message.toLowerCase().contains('not activated')) {
        deviceActive = false;
        deviceLockMessage =
            'This device has been deactivated. Contact Light Winter Technologies.';
        currentUser = null;
        sessionUsername = null;
        sessionLastSeenAt = null;
      }
      await save();
      notifyListeners();
    }
  }

  void logout() {
    clearDraftState();
    currentUser = null;
    sessionUsername = null;
    sessionLastSeenAt = null;
    unawaited(save());
    notifyListeners();
  }

  void markSessionBackgrounded() {
    if (currentUser == null) return;
    sessionUsername = currentUser!.username;
    sessionLastSeenAt = DateTime.now().toUtc();
    unawaited(save());
  }

  void restoreOrExpireSession({bool notify = true}) {
    if (sessionUsername == null || sessionLastSeenAt == null) return;
    final shouldExpireSession = !Platform.isWindows &&
        DateTime.now().toUtc().difference(sessionLastSeenAt!) >
            sessionGracePeriod;
    if (shouldExpireSession) {
      currentUser = null;
      sessionUsername = null;
      sessionLastSeenAt = null;
      clearDraftState();
      if (notify) notifyListeners();
      return;
    }
    if (currentUser == null && users.isNotEmpty) {
      currentUser = users
          .where((user) =>
              user.username.toLowerCase() == sessionUsername!.toLowerCase())
          .firstOrNull;
      if (notify) notifyListeners();
    }
  }

  void clearDraftState() {
    cart = [];
    activeCartName = _nextCustomerCartName(consume: false);
    openCarts = {activeCartName: []};
    unawaited(save());
  }

  Future<void> saveCompany(Company updated) async {
    if (_busyDepth == 0) {
      return runBusy('Saving company profile...', () => saveCompany(updated));
    }
    company = updated;
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncCompany(updated));
    }
  }

  Future<void> _syncCompany(Company updated) async {
    final orgId = organizationId;
    if (orgId == null) return;
    try {
      final data =
          await ApiClient(backendUrl).updateCompany(orgId, deviceUid, updated);
      _applyBootstrap(data);
      syncStatus = 'Company and fiscal settings synced.';
    } catch (error) {
      syncStatus = 'Company settings saved locally: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> setFiscalMode(bool enabled) async {
    final updated = company;
    if (updated == null) return;
    updated.fiscalMode = enabled;
    await saveCompany(updated);
  }

  Future<void> addUser(String name, String username, String role, String pin,
      List<String> permissions, List<String> branchIds) async {
    if (_busyDepth == 0) {
      return runBusy('Saving user...',
          () => addUser(name, username, role, pin, permissions, branchIds));
    }
    if (users
        .any((user) => user.username.toLowerCase() == username.toLowerCase())) {
      throw StateError('Username already exists.');
    }
    users.add(AppUser(
        name: name,
        username: username,
        role: role,
        pin: pin,
        permissions: permissions,
        branchIds: role == 'Owner' ? [] : branchIds));
    final created = users.last;
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncUserCreate(created));
    }
  }

  Future<void> _syncUserCreate(AppUser user) async {
    final orgId = organizationId;
    if (orgId == null) return;
    try {
      final data =
          await ApiClient(backendUrl).createUser(orgId, deviceUid, user);
      _applyBootstrap(data);
      syncStatus = 'User synced.';
    } catch (error) {
      syncStatus = 'User queued locally: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> updateUser(AppUser user, UserDraft draft) async {
    if (_busyDepth == 0) {
      return runBusy('Updating user...', () => updateUser(user, draft));
    }
    if (users.any((item) =>
        item != user &&
        item.username.toLowerCase() == draft.username.toLowerCase())) {
      throw StateError('Username already exists.');
    }
    final removingFullAccess = user.hasAllPrivileges &&
        draft.permissions.toSet().length < AppPermission.all.length;
    final otherFullAccessUsers =
        users.where((item) => item != user && item.hasAllPrivileges).length;
    if (removingFullAccess && otherFullAccessUsers == 0) {
      throw StateError('At least one user must keep all privileges.');
    }
    user.name = draft.name;
    user.username = draft.username;
    user.role = draft.role;
    user.pin = draft.pin;
    user.permissions = draft.permissions;
    user.branchIds = user.isOwner ? [] : draft.branchIds;
    await save();
    notifyListeners();
    if (user.id != null) {
      unawaited(_syncUserUpdate(user));
    }
  }

  Future<void> _syncUserUpdate(AppUser user) async {
    if (user.id == null) return;
    try {
      final data =
          await ApiClient(backendUrl).updateUser(user.id!, deviceUid, user);
      _applyBootstrap(data);
      syncStatus = 'User synced.';
    } catch (error) {
      syncStatus = 'User update local only: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> deleteUser(AppUser user) async {
    if (_busyDepth == 0) {
      return runBusy('Deleting user...', () => deleteUser(user));
    }
    if (user == currentUser) {
      throw StateError('You cannot delete the user currently logged in.');
    }
    if (user.hasAllPrivileges &&
        users.where((item) => item != user && item.hasAllPrivileges).isEmpty) {
      throw StateError('At least one user must keep all privileges.');
    }
    users.remove(user);
    await save();
    notifyListeners();
    if (user.id != null) {
      unawaited(_syncUserDelete(user.id!));
    }
  }

  Future<void> _syncUserDelete(String userId) async {
    try {
      final data = await ApiClient(backendUrl).deleteUser(userId, deviceUid);
      _applyBootstrap(data);
      syncStatus = 'User deleted from cloud.';
    } catch (error) {
      syncStatus = 'User delete local only: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> addBranch(BranchDraft draft) async {
    if (_busyDepth == 0) {
      return runBusy('Saving branch...', () => addBranch(draft));
    }
    branches.add(BranchProfile(
        id: newId(),
        name: draft.name,
        address: draft.address,
        phone: draft.phone));
    final created = branches.last;
    assignedBranchId ??= branches.first.id;
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncBranchCreate(created, draft));
    }
  }

  Future<void> _syncBranchCreate(BranchProfile local, BranchDraft draft) async {
    final orgId = organizationId;
    if (orgId == null) return;
    try {
      final data =
          await ApiClient(backendUrl).createBranch(orgId, deviceUid, draft);
      _applyBootstrap(data);
      syncStatus = '${local.name} branch synced.';
    } catch (error) {
      syncStatus = 'Branch queued locally: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> updateBranch(BranchProfile branch, BranchDraft draft) async {
    if (_busyDepth == 0) {
      return runBusy('Updating branch...', () => updateBranch(branch, draft));
    }
    branch.name = draft.name;
    branch.address = draft.address;
    branch.phone = draft.phone;
    if (branch.id == assignedBranchId && company != null) {
      company!.branchName = branch.name;
    }
    await save();
    notifyListeners();
    unawaited(_syncBranchUpdate(branch.id, draft));
  }

  Future<void> _syncBranchUpdate(String branchId, BranchDraft draft) async {
    try {
      final data =
          await ApiClient(backendUrl).updateBranch(branchId, deviceUid, draft);
      _applyBootstrap(data);
      syncStatus = 'Branch synced.';
    } catch (error) {
      syncStatus = 'Branch update local only: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> deleteBranch(BranchProfile branch) async {
    if (_busyDepth == 0) {
      return runBusy('Deleting branch...', () => deleteBranch(branch));
    }
    if (branches.length == 1) {
      throw StateError('At least one branch is required.');
    }
    branches.remove(branch);
    if (assignedBranchId == branch.id) {
      assignedBranchId = branches.first.id;
    }
    await save();
    notifyListeners();
    unawaited(_syncBranchDelete(branch.id));
  }

  Future<void> _syncBranchDelete(String branchId) async {
    try {
      final data =
          await ApiClient(backendUrl).deleteBranch(branchId, deviceUid);
      _applyBootstrap(data);
      syncStatus = 'Branch deleted from cloud.';
    } catch (error) {
      syncStatus = 'Branch delete local only: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> assignDeviceToBranch(BranchProfile branch) async {
    if (_busyDepth == 0) {
      return runBusy('Switching branch...', () => assignDeviceToBranch(branch));
    }
    final user = currentUser;
    if (user != null && !user.canLoginAtBranch(branch.id)) {
      throw StateError(
          '${user.name} is not assigned to ${branch.name}. Ask the owner to edit branch access.');
    }
    _captureCurrentBranchSnapshot();
    _clearBranchWorkingSession();
    assignedBranchId = branch.id;
    if (company != null) company!.branchName = branch.name;
    _restoreBranchSnapshot(branch.id);
    await save();
    notifyListeners();
    unawaited(_syncBranchView(branch));
  }

  Future<void> _syncBranchView(BranchProfile branch) async {
    try {
      final data =
          await ApiClient(backendUrl).loadBranchView(deviceUid, branch.id);
      _applyBootstrap(data);
      _clearBranchWorkingSession();
      syncStatus = 'Loaded branch session for ${branch.name}.';
    } catch (error) {
      syncStatus = 'Branch switched with local snapshot: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> transferStockToBranch(
      Product product, BranchProfile targetBranch, int quantity) async {
    if (_busyDepth == 0) {
      return runBusy('Transferring stock...',
          () => transferStockToBranch(product, targetBranch, quantity));
    }
    if (currentBranch == null) throw StateError('Current branch is missing.');
    if (targetBranch.id == currentBranch!.id) {
      throw StateError('Choose a different target branch.');
    }
    if (quantity <= 0) throw StateError('Quantity must be greater than zero.');
    final available = stockViewQuantityFor(product);
    if (available < quantity) {
      throw StateError('Not enough stock in ${currentBranch!.name}.');
    }
    final sourceBranchId = currentBranch!.id;
    product.stock = available - quantity;
    _markCurrentBranchStockInitialized();
    final targetSnapshot = {
      ...?branchStockSnapshots[targetBranch.id],
      product.id:
          (branchStockSnapshots[targetBranch.id]?[product.id] ?? 0) + quantity,
    };
    _markBranchStockInitialized(targetBranch.id, targetSnapshot);
    stockTransfers.insert(
        0,
        StockTransferRecord(
          id: newId(),
          productId: product.id,
          productName: product.name,
          fromBranchId: sourceBranchId,
          fromBranchName: currentBranch!.name,
          toBranchId: targetBranch.id,
          toBranchName: targetBranch.name,
          quantity: quantity,
          userName: currentUser?.name ?? currentUser?.username ?? 'User',
          createdAt: DateTime.now(),
        ));
    if (stockTransfers.length > 100) {
      stockTransfers = stockTransfers.take(100).toList();
    }
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncStockTransfer(
          sourceBranchId,
          targetBranch.id,
          product,
          quantity,
          'Transferred $quantity ${product.name} to ${targetBranch.name}.'));
    }
  }

  Future<void> transferStockBetweenBranches(
      Product product,
      BranchProfile sourceBranch,
      BranchProfile targetBranch,
      int quantity) async {
    if (_busyDepth == 0) {
      return runBusy(
          'Transferring stock...',
          () => transferStockBetweenBranches(
              product, sourceBranch, targetBranch, quantity));
    }
    if (sourceBranch.id == targetBranch.id) {
      throw StateError('Choose two different branches.');
    }
    if (quantity <= 0) throw StateError('Quantity must be greater than zero.');
    final available = branchStockQuantity(sourceBranch.id, product);
    if (available < quantity) {
      throw StateError('Not enough stock in ${sourceBranch.name}.');
    }
    final sourceSnapshot = {
      ...?branchStockSnapshots[sourceBranch.id],
      product.id: available - quantity,
    };
    _markBranchStockInitialized(sourceBranch.id, sourceSnapshot);
    final targetSnapshot = {
      ...?branchStockSnapshots[targetBranch.id],
      product.id:
          (branchStockSnapshots[targetBranch.id]?[product.id] ?? 0) + quantity,
    };
    _markBranchStockInitialized(targetBranch.id, targetSnapshot);
    if (sourceBranch.id == assignedBranchId) {
      product.stock = available - quantity;
    }
    stockTransfers.insert(
        0,
        StockTransferRecord(
          id: newId(),
          productId: product.id,
          productName: product.name,
          fromBranchId: sourceBranch.id,
          fromBranchName: sourceBranch.name,
          toBranchId: targetBranch.id,
          toBranchName: targetBranch.name,
          quantity: quantity,
          userName: currentUser?.name ?? currentUser?.username ?? 'User',
          createdAt: DateTime.now(),
        ));
    if (stockTransfers.length > 100) {
      stockTransfers = stockTransfers.take(100).toList();
    }
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncStockTransfer(
          sourceBranch.id,
          targetBranch.id,
          product,
          quantity,
          'Transferred $quantity ${product.name} from ${sourceBranch.name} to ${targetBranch.name}.'));
    }
  }

  Future<void> _syncStockTransfer(String sourceBranchId, String targetBranchId,
      Product product, int quantity, String successMessage) async {
    try {
      final data = await ApiClient(backendUrl).transferStock(
          deviceUid, sourceBranchId, targetBranchId, product.id, quantity,
          productName: product.name,
          userName: currentUser?.name ?? currentUser?.username ?? 'User');
      _applyBootstrap(data);
      syncStatus = successMessage;
    } catch (error) {
      syncStatus = 'Transfer queued locally: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> changePin(AppUser user, String currentPin, String newPin) async {
    if (_busyDepth == 0) {
      return runBusy(
          'Changing PIN...', () => changePin(user, currentPin, newPin));
    }
    if (user.pin != currentPin) {
      throw StateError('Current PIN is incorrect.');
    }
    user.pin = newPin;
    await save();
    notifyListeners();
    if (user.id != null && organizationId != null) {
      unawaited(_syncPinChange(user));
    }
  }

  Future<void> _syncPinChange(AppUser user) async {
    if (user.id == null) return;
    try {
      final data =
          await ApiClient(backendUrl).updateUser(user.id!, deviceUid, user);
      _applyBootstrap(data);
      syncStatus = 'PIN synced so the owner can see the latest user PIN.';
    } catch (error) {
      syncStatus = 'PIN changed locally and will need sync: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> addProduct(Product product) async {
    if (_busyDepth == 0) {
      return runBusy('Saving product...', () => addProduct(product));
    }
    products.add(product);
    _assignProductToCurrentBranch(product);
    await save();
    notifyListeners();
    if (organizationId != null && currentBranch != null) {
      await _syncProductCreate(product, currentBranch!.id);
    }
  }

  Future<void> _syncProductCreate(Product product, String branchId) async {
    final orgId = organizationId;
    if (orgId == null) return;
    final localIdBeforeSync = product.id;
    try {
      final data = await ApiClient(backendUrl)
          .createProduct(orgId, branchId, deviceUid, product);
      _remapProductId(localIdBeforeSync, product.id);
      if (data.isNotEmpty) _applyBootstrap(data);
      syncStatus = 'Product synced.';
    } catch (error) {
      syncStatus = 'Product queued locally: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> updateProduct(Product product) async {
    if (_busyDepth == 0) {
      return runBusy('Updating product...', () => updateProduct(product));
    }
    final index = products.indexWhere((item) => item.id == product.id);
    if (index >= 0) {
      products[index] = product;
    } else {
      products.add(product);
    }
    syncStatus =
        'Product details saved locally. Price and stock sync on supported backend columns.';
    _assignProductToCurrentBranch(product);
    await save();
    notifyListeners();
    if (organizationId != null && currentBranch != null) {
      await _syncProductUpdate(product, currentBranch!.id);
    }
  }

  Future<void> _syncProductUpdate(Product product, String branchId) async {
    final localIdBeforeSync = product.id;
    try {
      final data = await ApiClient(backendUrl)
          .updateProduct(deviceUid, branchId, product);
      _remapProductId(localIdBeforeSync, product.id);
      if (data.isNotEmpty) _applyBootstrap(data);
      syncStatus = 'Product details and branch quantity synced.';
    } catch (error) {
      syncStatus = 'Product update saved locally: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> deleteProduct(Product product) async {
    if (_busyDepth == 0) {
      return runBusy('Deleting product...', () => deleteProduct(product));
    }
    products.removeWhere((item) => item.id == product.id);
    for (final snapshot in branchStockSnapshots.values) {
      snapshot.remove(product.id);
    }
    for (final cartName in openCarts.keys.toList()) {
      openCarts[cartName] = (openCarts[cartName] ?? [])
          .where((item) => item.product.id != product.id)
          .toList();
    }
    cart.removeWhere((item) => item.product.id == product.id);
    syncStatus = 'Product deleted locally.';
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncProductDelete(product.id));
    }
  }

  Future<void> _syncProductDelete(String productId) async {
    try {
      final data =
          await ApiClient(backendUrl).deleteProduct(deviceUid, productId);
      if (data.isNotEmpty) _applyBootstrap(data);
      syncStatus = 'Product deleted from shared catalogue.';
    } catch (error) {
      syncStatus = 'Product delete saved locally: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> importProducts(List<Product> imported) async {
    if (_busyDepth == 0) {
      return runBusy('Importing stock CSV...', () => importProducts(imported));
    }
    var added = 0;
    var updated = 0;
    final currentBranchProductIds =
        currentBranchAssignedProducts.map((product) => product.id).toSet();
    final currentBranchSkuIds = {
      for (final product in currentBranchAssignedProducts)
        if (product.sku.trim().isNotEmpty)
          product.sku.trim().toLowerCase(): product.id
    };
    final currentBranchNameIds = {
      for (final product in currentBranchAssignedProducts)
        product.name.trim().toLowerCase(): product.id
    };
    for (final product in imported) {
      final matchingId = currentBranchProductIds.contains(product.id)
          ? product.id
          : (product.sku.trim().isNotEmpty
                  ? currentBranchSkuIds[product.sku.trim().toLowerCase()]
                  : null) ??
              currentBranchNameIds[product.name.trim().toLowerCase()];
      final existingIndex = matchingId == null
          ? -1
          : products.indexWhere((item) => item.id == matchingId);
      if (existingIndex >= 0) {
        final existing = products[existingIndex];
        product.id = existing.id;
        products[existingIndex] = product;
        updated++;
      } else {
        products.add(product);
        added++;
      }
      _assignProductToCurrentBranch(product);
    }
    syncStatus = 'CSV import saved locally: $added added, $updated updated.';
    await save();
    notifyListeners();
    if (organizationId != null && currentBranch != null) {
      await _syncImportedStock(imported, currentBranch!.id);
    }
  }

  Future<void> _syncImportedStock(
      List<Product> imported, String branchId) async {
    final orgId = organizationId;
    if (orgId == null) return;
    try {
      for (final supplier in suppliers) {
        await ApiClient(backendUrl)
            .upsertSupplier(orgId, deviceUid, supplier, refresh: false);
      }
      final oldIdsByObject = {
        for (final product in imported) product: product.id
      };
      final data = await ApiClient(backendUrl)
          .upsertProducts(orgId, branchId, deviceUid, imported);
      for (final product in imported) {
        _remapProductId(oldIdsByObject[product] ?? product.id, product.id);
      }
      if (data.isNotEmpty) _applyBootstrap(data);
      syncStatus = 'CSV import synced to cloud.';
    } catch (error) {
      syncStatus = 'CSV import saved locally. Cloud sync failed: $error';
    }
    await save();
    notifyListeners();
  }

  void _remapProductId(String oldId, String newId) {
    if (oldId == newId || oldId.trim().isEmpty || newId.trim().isEmpty) return;
    for (final snapshot in branchStockSnapshots.values) {
      if (snapshot.containsKey(oldId)) {
        final existing = snapshot[newId] ?? 0;
        final moved = snapshot.remove(oldId) ?? 0;
        snapshot[newId] = max(existing, moved);
      }
    }
    for (final cartName in openCarts.keys.toList()) {
      for (final item in openCarts[cartName] ?? <CartItem>[]) {
        if (item.product.id == oldId) item.product.id = newId;
      }
    }
    for (final item in cart) {
      if (item.product.id == oldId) item.product.id = newId;
    }
  }

  Future<void> addSupplier(Supplier supplier) async {
    if (_busyDepth == 0) {
      return runBusy('Saving supplier...', () => addSupplier(supplier));
    }
    suppliers.add(supplier);
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncSupplierUpsert(supplier));
    }
  }

  Future<void> updateSupplier(Supplier supplier) async {
    if (_busyDepth == 0) {
      return runBusy('Updating supplier...', () => updateSupplier(supplier));
    }
    final index = suppliers.indexWhere((item) => item.id == supplier.id);
    if (index >= 0) {
      suppliers[index] = supplier;
    } else {
      suppliers.add(supplier);
    }
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncSupplierUpsert(supplier));
    }
  }

  Future<void> deleteSupplier(Supplier supplier) async {
    if (_busyDepth == 0) {
      return runBusy('Deleting supplier...', () => deleteSupplier(supplier));
    }
    suppliers.removeWhere((item) => item.id == supplier.id);
    for (final product in products) {
      if (product.supplierId == supplier.id) product.supplierId = '';
    }
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncSupplierDelete(supplier.id));
    }
  }

  Future<void> _syncSupplierUpsert(Supplier supplier) async {
    final orgId = organizationId;
    if (orgId == null) return;
    try {
      final data = await ApiClient(backendUrl)
          .upsertSupplier(orgId, deviceUid, supplier);
      _applyBootstrap(data);
      syncStatus = 'Supplier synced.';
    } catch (error) {
      syncStatus = 'Supplier saved locally. Cloud sync failed: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> _syncSupplierDelete(String supplierId) async {
    try {
      final data =
          await ApiClient(backendUrl).deleteSupplier(deviceUid, supplierId);
      _applyBootstrap(data);
      syncStatus = 'Supplier deleted from cloud.';
    } catch (error) {
      syncStatus = 'Supplier deleted locally. Cloud sync failed: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> deleteAllProducts() async {
    if (_busyDepth == 0) {
      return runBusy('Deleting products...', deleteAllProducts);
    }
    final productIds = products.map((product) => product.id).toList();
    products.clear();
    branchStockSnapshots.clear();
    branchStockInitialized.clear();
    cart.clear();
    openCarts = {'Customer 1': []};
    activeCartName = 'Customer 1';
    syncStatus = 'All products deleted locally.';
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncProductBulkDelete(productIds));
    }
  }

  Future<void> deleteAllSuppliers() async {
    if (_busyDepth == 0) {
      return runBusy('Deleting suppliers...', deleteAllSuppliers);
    }
    final supplierIds = suppliers.map((supplier) => supplier.id).toList();
    suppliers.clear();
    for (final product in products) {
      product.supplierId = '';
    }
    syncStatus = 'All suppliers deleted locally.';
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncSupplierBulkDelete(supplierIds));
    }
  }

  Future<void> deleteAllStockData() async {
    if (_busyDepth == 0) {
      return runBusy('Deleting stock data...', deleteAllStockData);
    }
    final productIds = products.map((product) => product.id).toList();
    final supplierIds = suppliers.map((supplier) => supplier.id).toList();
    products.clear();
    suppliers.clear();
    branchStockSnapshots.clear();
    branchSaleSnapshots.clear();
    branchStockInitialized.clear();
    cart.clear();
    openCarts = {'Customer 1': []};
    activeCartName = 'Customer 1';
    syncStatus = 'All stock products and suppliers deleted locally.';
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncStockBulkDelete(productIds, supplierIds));
    }
  }

  Future<void> deleteAllReportHistory({required bool allBranches}) async {
    if (_busyDepth == 0) {
      return runBusy('Deleting report history...',
          () => deleteAllReportHistory(allBranches: allBranches));
    }
    final targetSales = allBranches ? allKnownSales : [...sales];
    final saleIds = targetSales.map((sale) => sale.id).toSet();
    if (allBranches) {
      sales.clear();
      branchSaleSnapshots.clear();
    } else {
      sales.clear();
      final branchId = assignedBranchId;
      if (branchId != null) branchSaleSnapshots[branchId] = [];
    }
    saleVoids.removeWhere((record) => saleIds.contains(record.saleId));
    pendingSaleSyncIds.removeWhere(saleIds.contains);
    syncStatus = allBranches
        ? 'All report, sales, and debt history deleted locally.'
        : 'This branch report, sales, and debt history deleted locally.';
    await save();
    notifyListeners();
    if (organizationId != null && saleIds.isNotEmpty) {
      unawaited(_syncSaleBulkDelete(saleIds.toList()));
    }
  }

  Future<void> deleteAllDebtHistory() async {
    if (_busyDepth == 0) {
      return runBusy('Deleting debt history...', deleteAllDebtHistory);
    }
    final saleIds = debtSales.map((sale) => sale.id).toSet();
    sales.removeWhere((sale) => saleIds.contains(sale.id));
    branchSaleSnapshots.updateAll((_, branchSales) =>
        branchSales.where((sale) => !saleIds.contains(sale.id)).toList());
    saleVoids.removeWhere((record) => saleIds.contains(record.saleId));
    pendingSaleSyncIds.removeWhere(saleIds.contains);
    syncStatus = 'Debt history deleted locally.';
    await save();
    notifyListeners();
    if (organizationId != null && saleIds.isNotEmpty) {
      unawaited(_syncSaleBulkDelete(saleIds.toList()));
    }
  }

  Future<void> deleteAllCustomers() async {
    if (_busyDepth == 0) {
      return runBusy('Deleting customers...', deleteAllCustomers);
    }
    final customerIds = customers.map((customer) => customer.id).toList();
    customers.clear();
    syncStatus = 'All customer records deleted locally.';
    await save();
    notifyListeners();
    if (organizationId != null && customerIds.isNotEmpty) {
      unawaited(_syncCustomerBulkDelete(customerIds));
    }
  }

  Future<void> deleteAllTransferHistory() async {
    if (_busyDepth == 0) {
      return runBusy('Deleting transfer history...', deleteAllTransferHistory);
    }
    final transferIds = stockTransfers.map((transfer) => transfer.id).toList();
    stockTransfers.clear();
    syncStatus = 'Transfer history deleted locally.';
    await save();
    notifyListeners();
    if (organizationId != null && transferIds.isNotEmpty) {
      unawaited(_syncTransferBulkDelete(transferIds));
    }
  }

  Future<void> _syncProductBulkDelete(List<String> productIds) async {
    try {
      for (final productId in productIds) {
        await ApiClient(backendUrl).deleteProduct(deviceUid, productId);
      }
      syncStatus = 'Products deleted from cloud.';
    } catch (error) {
      syncStatus = 'Products deleted locally. Cloud sync failed: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> deleteSaleRecord(SaleRecord sale) async {
    if (_busyDepth == 0) {
      return runBusy('Deleting sale...', () => deleteSaleRecord(sale));
    }
    sales.removeWhere((item) => item.id == sale.id);
    branchSaleSnapshots.updateAll(
        (_, list) => list.where((item) => item.id != sale.id).toList());
    saleVoids.removeWhere((record) => record.saleId == sale.id);
    syncStatus = 'Sale deleted locally.';
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncSaleBulkDelete([sale.id]));
    }
  }

  Future<void> deleteVoidRecord(SaleVoidRecord record) async {
    if (_busyDepth == 0) {
      return runBusy('Deleting void record...', () => deleteVoidRecord(record));
    }
    saleVoids.removeWhere((item) => item.id == record.id);
    syncStatus = 'Void/return record deleted locally.';
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncVoidBulkDelete([record.id]));
    }
  }

  Future<void> deleteAllVoidHistory() async {
    if (_busyDepth == 0) {
      return runBusy('Deleting void history...', deleteAllVoidHistory);
    }
    final ids = saleVoids.map((record) => record.id).toList();
    saleVoids.clear();
    syncStatus = 'Void/return history deleted locally.';
    await save();
    notifyListeners();
    if (ids.isNotEmpty && organizationId != null) {
      unawaited(_syncVoidBulkDelete(ids));
    }
  }

  Future<void> _syncSupplierBulkDelete(List<String> supplierIds) async {
    try {
      for (final supplierId in supplierIds) {
        await ApiClient(backendUrl).deleteSupplier(deviceUid, supplierId);
      }
      final data = await ApiClient(backendUrl).bootstrap(deviceUid);
      _applyBootstrap(data);
      syncStatus = 'Suppliers deleted from cloud.';
    } catch (error) {
      syncStatus = 'Suppliers deleted locally. Cloud sync failed: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> _syncStockBulkDelete(
      List<String> productIds, List<String> supplierIds) async {
    try {
      for (final productId in productIds) {
        await ApiClient(backendUrl).deleteProduct(deviceUid, productId);
      }
      for (final supplierId in supplierIds) {
        await ApiClient(backendUrl).deleteSupplier(deviceUid, supplierId);
      }
      syncStatus = 'Stock data deleted from cloud.';
    } catch (error) {
      syncStatus = 'Stock deleted locally. Cloud sync failed: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> _syncSaleBulkDelete(List<String> saleIds) async {
    try {
      await ApiClient(backendUrl).deleteSales(deviceUid, saleIds);
      syncStatus = 'Report, sales, and debt history deleted from cloud.';
    } catch (error) {
      syncStatus =
          'Report, sales, and debt history deleted locally. Cloud sync failed: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> _syncCustomerBulkDelete(List<String> customerIds) async {
    try {
      await ApiClient(backendUrl).deleteCustomers(deviceUid, customerIds);
      syncStatus = 'Customers deleted from cloud.';
    } catch (error) {
      syncStatus = 'Customers deleted locally. Cloud sync failed: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> _syncTransferBulkDelete(List<String> transferIds) async {
    try {
      await ApiClient(backendUrl).deleteStockTransfers(deviceUid, transferIds);
      syncStatus = 'Transfer history deleted from cloud.';
    } catch (error) {
      syncStatus =
          'Transfer history deleted locally. Cloud sync failed: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> _syncVoidBulkDelete(List<String> voidIds) async {
    try {
      await ApiClient(backendUrl).deleteSaleVoids(deviceUid, voidIds);
      syncStatus = 'Void/return history deleted from cloud.';
    } catch (error) {
      syncStatus =
          'Void/return history deleted locally. Cloud sync failed: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> adjustStock(Product product, int delta) async {
    if (_busyDepth == 0) {
      return runBusy('Adjusting stock...', () => adjustStock(product, delta));
    }
    product.stock += delta;
    _markCurrentBranchStockInitialized();
    await save();
    notifyListeners();
    if (organizationId != null && currentBranch != null) {
      unawaited(_syncStockAdjustment(product.id, currentBranch!.id, delta));
    }
  }

  Future<void> _syncStockAdjustment(
      String productId, String branchId, int delta) async {
    try {
      final data = await ApiClient(backendUrl)
          .adjustStock(deviceUid, branchId, productId, delta);
      _applyBootstrap(data);
      syncStatus = 'Stock adjustment synced.';
    } catch (error) {
      syncStatus = 'Stock adjustment queued locally: $error';
    }
    await save();
    notifyListeners();
  }

  List<CartItem> _cloneCart(List<CartItem> source) => source
      .map((item) => CartItem(product: item.product, quantity: item.quantity))
      .toList();

  void _persistActiveCartDraft() {
    _ensureCustomerCounterDay();
    _pruneEmptyInactiveCarts();
    openCarts[activeCartName] = _cloneCart(cart);
    unawaited(save());
  }

  void _pruneEmptyInactiveCarts() {
    final removable = openCarts.entries
        .where((entry) => entry.key != activeCartName && entry.value.isEmpty)
        .map((entry) => entry.key)
        .toList();
    for (final name in removable) {
      openCarts.remove(name);
    }
  }

  void _ensureCustomerCounterDay() {
    final today = localDateKey(DateTime.now());
    if (customerCounterDate == today) return;
    customerCounterDate = today;
    nextCustomerNumber = 1;
  }

  String _nextCustomerCartName({bool consume = true}) {
    _ensureCustomerCounterDay();
    final name = 'Customer $nextCustomerNumber';
    if (consume) nextCustomerNumber += 1;
    return name;
  }

  void switchOpenCart(String name) {
    _persistActiveCartDraft();
    activeCartName = name;
    cart = _cloneCart(openCarts[name] ?? []);
    unawaited(save());
    notifyListeners();
  }

  void createOpenCart() {
    if (cart.isEmpty) {
      _persistActiveCartDraft();
      return;
    }
    _persistActiveCartDraft();
    var name = _nextCustomerCartName();
    while (openCarts.containsKey(name)) {
      name = _nextCustomerCartName();
    }
    openCarts[name] = [];
    activeCartName = name;
    cart = [];
    unawaited(save());
    notifyListeners();
  }

  void closeOpenCart(String name) {
    _persistActiveCartDraft();
    openCarts.remove(name);
    if (openCarts.isEmpty) {
      final nextName = _nextCustomerCartName();
      openCarts[nextName] = [];
    }
    activeCartName = openCarts.keys.first;
    cart = _cloneCart(openCarts[activeCartName] ?? []);
    unawaited(save());
    notifyListeners();
  }

  void addToCart(Product product) {
    final available = product.isCustom ? 999999 : sellableQuantityFor(product);
    if (!product.isCustom && available <= 0) return;
    final existing =
        cart.where((item) => item.product.id == product.id).firstOrNull;
    if (existing == null) {
      cart.add(CartItem(product: product, quantity: 1));
    } else if (product.isCustom || existing.quantity < available) {
      existing.quantity += 1;
    }
    _persistActiveCartDraft();
    notifyListeners();
  }

  void replaceCart(List<CartItem> nextCart) {
    cart = _cloneCart(nextCart);
    _persistActiveCartDraft();
    notifyListeners();
  }

  void addCustomItem(String name, int priceCents) {
    if (name.trim().isEmpty || priceCents <= 0) return;
    cart.add(CartItem(
      product: Product(
        id: 'CUSTOM-${newId()}',
        name: name.trim(),
        sku: 'CUSTOM',
        barcode: '',
        priceCents: priceCents,
        stock: 999999,
        reorderLevel: 0,
        isCustom: true,
      ),
      quantity: 1,
    ));
    _persistActiveCartDraft();
    notifyListeners();
  }

  void incrementCartItem(CartItem item) {
    final available =
        item.product.isCustom ? 999999 : sellableQuantityFor(item.product);
    if (item.product.isCustom || item.quantity < available) {
      item.quantity += 1;
      _persistActiveCartDraft();
      notifyListeners();
    }
  }

  void setCartItemQuantity(CartItem item, int quantity) {
    final next = max(0, quantity);
    if (next == 0) {
      cart.remove(item);
    } else {
      final available = item.product.isCustom
          ? 999999
          : max(sellableQuantityFor(item.product), item.quantity);
      item.quantity = item.product.isCustom ? next : min(next, available);
    }
    _persistActiveCartDraft();
    notifyListeners();
  }

  void decrementCartItem(CartItem item) {
    item.quantity -= 1;
    if (item.quantity <= 0) cart.remove(item);
    _persistActiveCartDraft();
    notifyListeners();
  }

  void removeFromCart(CartItem item) {
    cart.remove(item);
    _persistActiveCartDraft();
    notifyListeners();
  }

  Future<SaleRecord?> checkout(
    String paymentMethod, {
    Customer? customer,
    int discountCents = 0,
    int paidCents = 0,
    int debtCents = 0,
    int changeCents = 0,
  }) async {
    if (_busyDepth == 0) {
      return runBusy(
          'Recording sale...',
          () => checkout(paymentMethod,
              customer: customer,
              discountCents: discountCents,
              paidCents: paidCents,
              debtCents: debtCents,
              changeCents: changeCents));
    }
    if (cart.isEmpty) return null;
    final saleLines = [...cart];
    var currentBranchStockChanged = false;
    for (final item in cart) {
      if (!item.product.isCustom) {
        var remaining = item.quantity;
        if (item.product.stock > 0) {
          final used = min(item.product.stock, remaining);
          item.product.stock -= used;
          remaining -= used;
          currentBranchStockChanged = true;
        }
        if (remaining > 0 && allowCatalogueWideSale) {
          remaining = _consumeCatalogueSnapshotStock(item.product, remaining);
        }
        if (remaining > 0) {
          throw StateError('Not enough stock for ${item.product.name}.');
        }
      }
    }
    if (currentBranchStockChanged ||
        (assignedBranchId != null &&
            branchStockInitialized.contains(assignedBranchId))) {
      _captureCurrentBranchSnapshot(force: currentBranchStockChanged);
    }
    final totalAfterDiscount =
        (cartTotalCents - discountCents).clamp(0, 1 << 31).toInt();
    final sale = SaleRecord(
      id: newId(),
      branchId: assignedBranchId ?? '',
      totalCents: totalAfterDiscount,
      paymentMethod: paymentMethod,
      cashier: currentUser?.name ?? 'Unknown',
      customerName: customer?.name ?? '',
      discountCents: discountCents,
      paidCents: paidCents,
      changeCents: changeCents,
      debtCents: debtCents,
      lines: saleLines
          .map((item) => ReceiptLineSnapshot(
                productId: item.product.id,
                name: item.product.name,
                quantity: item.quantity,
                unitPriceCents: item.product.priceCents,
                lineTotalCents: item.product.priceCents * item.quantity,
                unitCostCents: item.product.costCents,
                lineCostCents: item.product.costCents * item.quantity,
              ))
          .toList(),
      createdAt: DateTime.now(),
    );
    sales.add(sale);
    cart.clear();
    closeOpenCart(activeCartName);
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncSaleInBackground(
          sale: sale,
          saleLines: saleLines,
          customer: customer,
          paymentMethod: paymentMethod,
          totalCents: sale.totalCents,
          discountCents: discountCents,
          paidCents: paidCents,
          changeCents: changeCents,
          debtCents: debtCents));
    }
    return sale;
  }

  Future<void> _syncSaleInBackground({
    required SaleRecord sale,
    required List<CartItem> saleLines,
    required Customer? customer,
    required String paymentMethod,
    required int totalCents,
    required int discountCents,
    required int paidCents,
    required int changeCents,
    required int debtCents,
  }) async {
    try {
      final syncedLines = saleLines;
      await ApiClient(backendUrl).createSale(deviceUid, currentUser?.id,
          customer?.id, paymentMethod, syncedLines, totalCents,
          saleId: sale.id,
          discountCents: discountCents,
          paidCents: paidCents,
          changeCents: changeCents,
          debtCents: debtCents);
      syncStatus = 'Sale synced.';
      pendingSaleSyncIds.remove(sale.id);
      await save();
      notifyListeners();
    } catch (error) {
      pendingSaleSyncIds.add(sale.id);
      syncStatus = 'Sale queued locally: $error';
      await save();
      notifyListeners();
    }
  }

  Future<void> settleDebt(SaleRecord sale, int amountCents) async {
    if (_busyDepth == 0) {
      return runBusy(
          'Saving debt payment...', () => settleDebt(sale, amountCents));
    }
    if (amountCents <= 0) throw StateError('Enter a valid payment amount.');
    final balance = debtBalanceForSale(sale);
    if (balance <= 0) throw StateError('This debt is already fully paid.');
    final applied = min(amountCents, balance);
    sale.paidCents += applied;
    sale.debtCents = max(0, sale.debtCents - applied);
    accountingEntries.insert(
        0,
        AccountingEntry(
            id: newId(),
            branchId: sale.branchId.isNotEmpty
                ? sale.branchId
                : assignedBranchId ?? '',
            type: AccountingEntryType.income,
            category: 'Customer Debt Payment',
            description: sale.customerName.isEmpty
                ? 'Debt payment for ${sale.id}'
                : 'Debt payment from ${sale.customerName}',
            amountCents: applied,
            paymentMethod: 'Cash',
            counterparty: sale.customerName,
            createdAt: DateTime.now()));
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncDebtSettlement(sale));
      unawaited(_syncAccountingEntryCreate(accountingEntries.first));
    }
  }

  Future<void> _syncDebtSettlement(SaleRecord sale) async {
    try {
      await ApiClient(backendUrl)
          .updateSaleDebt(deviceUid, sale.id, sale.paidCents, sale.debtCents);
      syncStatus = 'Debt payment synced.';
    } catch (error) {
      syncStatus = 'Debt payment saved locally: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> voidSale(
      SaleRecord sale, List<ReceiptLineSnapshot> lines, String reason) async {
    if (_busyDepth == 0) {
      return runBusy('Recording void...', () => voidSale(sale, lines, reason));
    }
    if (lines.isEmpty) throw StateError('Choose at least one item to void.');
    if (reason.trim().isEmpty) throw StateError('Enter a void reason.');
    final branchId = sale.branchId.isNotEmpty
        ? sale.branchId
        : assignedBranchId ?? currentBranch?.id ?? '';
    final voidTotal = lines.fold(0, (sum, line) => sum + line.lineTotalCents);
    final originalQty = sale.lines.fold(0, (sum, line) => sum + line.quantity);
    final voidQty = lines.fold(0, (sum, line) => sum + line.quantity);
    final type = voidQty >= originalQty ? 'full_void' : 'partial_void';
    for (final line in lines) {
      if (line.productId.isEmpty) continue;
      final current = branchStockSnapshots[branchId]?[line.productId] ?? 0;
      final snapshot = {
        ...?branchStockSnapshots[branchId],
        line.productId: current + line.quantity,
      };
      _markBranchStockInitialized(branchId, snapshot);
      if (branchId == assignedBranchId) {
        final product =
            products.where((item) => item.id == line.productId).firstOrNull;
        if (product != null) product.stock = current + line.quantity;
      }
    }
    final record = SaleVoidRecord(
      id: newId(),
      saleId: sale.id,
      branchId: branchId,
      type: type,
      reason: reason.trim(),
      userName: currentUser?.name ?? currentUser?.username ?? 'User',
      totalCents: voidTotal,
      lines: lines,
      createdAt: DateTime.now(),
    );
    saleVoids.insert(0, record);
    if (saleVoids.length > 300) {
      saleVoids = saleVoids.take(300).toList();
    }
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncVoidSale(record, type));
    }
  }

  Future<void> _syncVoidSale(SaleVoidRecord record, String type) async {
    try {
      final data = await ApiClient(backendUrl)
          .voidSale(deviceUid, currentUser?.id, record);
      _applyBootstrap(data);
      syncStatus =
          '${type == 'full_void' ? 'Full void' : 'Partial void'} synced.';
    } catch (error) {
      syncStatus = 'Void queued locally: $error';
    }
    await save();
    notifyListeners();
  }

  int _consumeCatalogueSnapshotStock(Product product, int quantity) {
    var remaining = quantity;
    for (final branchId in branchStockInitialized) {
      if (branchId == assignedBranchId) continue;
      final snapshot = branchStockSnapshots[branchId];
      if (snapshot == null) continue;
      final available = snapshot[product.id] ?? 0;
      if (available <= 0) continue;
      final used = min(available, remaining);
      snapshot[product.id] = available - used;
      remaining -= used;
      if (remaining <= 0) break;
    }
    return remaining;
  }

  Future<Customer> addCustomer(String name, String phone) async {
    if (_busyDepth == 0) {
      return runBusy('Saving customer...', () => addCustomer(name, phone));
    }
    final customer = Customer(id: newId(), name: name, phone: phone);
    customers.add(customer);
    await save();
    notifyListeners();
    if (organizationId != null) {
      unawaited(_syncCustomerCreate(customer));
    }
    return customer;
  }

  Future<void> _syncCustomerCreate(Customer customer) async {
    final orgId = organizationId;
    if (orgId == null) return;
    try {
      final data = await ApiClient(backendUrl)
          .createCustomer(orgId, deviceUid, customer);
      _applyBootstrap(data);
      syncStatus = 'Customer synced.';
    } catch (error) {
      syncStatus = 'Customer queued locally: $error';
    }
    await save();
    notifyListeners();
  }

  Future<void> applyLicense(String token) async {
    if (_busyDepth == 0) {
      return runBusy('Verifying license...', () => applyLicense(token));
    }
    final normalized = token.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (normalized.isEmpty) {
      throw StateError(
          'Enter the license voucher sent by Light Winter Technologies.');
    }
    try {
      final data = await ApiClient(backendUrl).applyLicense(
        deviceUid,
        normalized,
      );
      _applyBootstrap(data);
      syncStatus = 'License verified for this device';
    } catch (error) {
      licenseLabel = 'Not licensed';
      licenseExpiresAt = null;
      syncStatus = 'License rejected: ${cleanError(error)}';
      await save();
      notifyListeners();
      throw StateError(cleanError(error));
    }
    await save();
    notifyListeners();
  }

  Future<void> openFiscalDay() async {
    if (_busyDepth == 0) return runBusy('Opening fiscal day...', openFiscalDay);
    if (!fiscalMode || fiscalDayOpen) return;
    final blocker = fiscalDayOpenBlocker();
    if (blocker != null) throw StateError(blocker);
    fiscalDayOpen = true;
    fiscalDayNo += 1;
    fiscalDayOpenedAt = DateTime.now();
    if (organizationId != null && currentBranch != null) {
      try {
        final data = await ApiClient(backendUrl)
            .openFiscalDay(deviceUid, currentUser?.id, fiscalDayNo);
        _applyBootstrap(data);
        syncStatus = 'Fiscal day opened in Supabase.';
      } catch (error) {
        syncStatus = 'Fiscal day opened locally: $error';
      }
    }
    await save();
    notifyListeners();
  }

  Future<void> closeFiscalDay() async {
    if (_busyDepth == 0)
      return runBusy('Closing fiscal day...', closeFiscalDay);
    if (!fiscalDayOpen) return;
    fiscalDayOpen = false;
    if (organizationId != null && currentBranch != null) {
      try {
        final data = await ApiClient(backendUrl)
            .closeFiscalDay(deviceUid, currentUser?.id, fiscalDayNo);
        _applyBootstrap(data);
        syncStatus = 'Fiscal day closed in Supabase.';
      } catch (error) {
        syncStatus = 'Fiscal day closed locally: $error';
      }
    }
    await save();
    notifyListeners();
  }

  String receiptText(SaleRecord sale) {
    return fiscalMode ? fiscalReceiptText(sale) : nonFiscalReceiptText(sale);
  }

  String nonFiscalReceiptText(SaleRecord sale) {
    final lineText = sale.lines.isEmpty
        ? 'Items: details unavailable for synced sale'
        : sale.lines
            .map((line) =>
                '${line.name}\n  ${line.quantity} x ${moneyFor(line.unitPriceCents)}  ${moneyFor(line.lineTotalCents)}')
            .join('\n');
    return '''
${company?.shopName ?? 'Light Winter RetailOS'}
${currentBranch?.name ?? company?.branchName ?? 'Main Branch'}
${company?.address ?? ''}
${company?.phone ?? ''}
Receipt No: ${sale.id}
Cashier: ${sale.cashier}
Payment: ${sale.paymentMethod}
${sale.customerName.isEmpty ? '' : 'Customer: ${sale.customerName}'}
Date: ${formatReceiptDate(sale.createdAt)}

$lineText

Subtotal: ${moneyFor(sale.subtotalCents)}
Discount: ${moneyFor(sale.discountCents)}
Total: ${moneyFor(sale.totalCents)}
Paid: ${moneyFor(sale.paidCents)}
Change: ${moneyFor(sale.changeCents)}
Debt: ${moneyFor(sale.debtCents)}

Thank you for shopping with us.
Powered by Light Winter Technologies
''';
  }

  String fiscalReceiptText(SaleRecord sale) {
    final error = fiscalReceiptBlocker();
    if (error != null) throw StateError(error);
    final c = company!;
    final lineText = sale.lines.isEmpty
        ? 'Items: details unavailable for synced sale'
        : sale.lines
            .map((line) =>
                '${line.name}\n  Qty ${line.quantity} @ ${moneyFor(line.unitPriceCents)}  ${moneyFor(line.lineTotalCents)}')
            .join('\n');
    return '''
FISCAL TAX INVOICE
${c.registeredName.trim().isEmpty ? c.shopName : c.registeredName}
Trading as: ${c.shopName}
Branch: ${currentBranch?.name ?? c.branchName}
Address: ${c.address}
Phone: ${c.phone}
TIN: ${c.tin}
VAT No: ${c.vatNumber}
ZIMRA Device ID: ${c.zimraDeviceId}
Fiscal Serial: ${c.fiscalSerialNumber}
Fiscal Day: $fiscalDayNo ${fiscalDayOpen ? 'OPEN' : 'CLOSED'}
Receipt No: ${sale.id}
Cashier: ${sale.cashier}
Payment: ${sale.paymentMethod}
${sale.customerName.isEmpty ? '' : 'Buyer: ${sale.customerName}'}
Date: ${formatReceiptDate(sale.createdAt)}

$lineText

Subtotal: ${moneyFor(sale.subtotalCents)}
Discount: ${moneyFor(sale.discountCents)}
Total Incl. Tax: ${moneyFor(sale.totalCents)}
Paid: ${moneyFor(sale.paidCents)}
Change: ${moneyFor(sale.changeCents)}
Debt: ${moneyFor(sale.debtCents)}

Tax Summary:
VAT/TIN tax mapping must match FDMS submitted tax groups.

FDMS QR / Verification URL:
${c.fiscalQrUrl}

Powered by Light Winter Technologies
''';
  }

  String? fiscalReceiptBlocker() {
    if (!fiscalMode) return null;
    final c = company;
    if (c == null) return 'Company profile is missing.';
    if (!fiscalDayOpen) {
      return 'Open fiscal day before printing a fiscal receipt.';
    }
    if (c.tin.trim().isEmpty ||
        c.zimraDeviceId.trim().isEmpty ||
        c.fiscalQrUrl.trim().isEmpty) {
      return 'Fiscal receipt blocked. Add TIN, ZIMRA device ID, and FDMS QR/verification URL before printing.';
    }
    return null;
  }

  String? fiscalDayOpenBlocker() {
    if (!fiscalMode) return 'Fiscalisation is not enabled for this shop.';
    final c = company;
    if (c == null) return 'Company profile is missing.';
    if (c.tin.trim().isEmpty)
      return 'Add the shop TIN before opening fiscal day.';
    if (c.zimraDeviceId.trim().isEmpty) {
      return 'Add the ZIMRA Fiscal Device ID before opening fiscal day.';
    }
    if (c.fiscalSerialNumber.trim().isEmpty) {
      return 'Add the Fiscal Device Serial before opening fiscal day.';
    }
    return null;
  }
}

class Company {
  Company({
    required this.shopName,
    required this.branchName,
    this.phone = '',
    this.address = '',
    this.fiscalMode = false,
    this.registeredName = '',
    this.tin = '',
    this.vatNumber = '',
    this.zimraDeviceId = '',
    this.fiscalSerialNumber = '',
    this.fiscalQrUrl = '',
  });

  String shopName;
  String branchName;
  String phone;
  String address;
  bool fiscalMode;
  String registeredName;
  String tin;
  String vatNumber;
  String zimraDeviceId;
  String fiscalSerialNumber;
  String fiscalQrUrl;

  Map<String, dynamic> toJson() => {
        'shopName': shopName,
        'branchName': branchName,
        'phone': phone,
        'address': address,
        'fiscalMode': fiscalMode,
        'registeredName': registeredName,
        'tin': tin,
        'vatNumber': vatNumber,
        'zimraDeviceId': zimraDeviceId,
        'fiscalSerialNumber': fiscalSerialNumber,
        'fiscalQrUrl': fiscalQrUrl,
      };

  factory Company.fromJson(Map<String, dynamic> json) => Company(
        shopName: json['shopName'] ?? '',
        branchName: json['branchName'] ?? '',
        phone: json['phone'] ?? '',
        address: json['address'] ?? '',
        fiscalMode: json['fiscalMode'] ?? false,
        registeredName: json['registeredName'] ?? '',
        tin: json['tin'] ?? '',
        vatNumber: json['vatNumber'] ?? '',
        zimraDeviceId: json['zimraDeviceId'] ?? '',
        fiscalSerialNumber: json['fiscalSerialNumber'] ?? '',
        fiscalQrUrl: json['fiscalQrUrl'] ?? '',
      );
}

class BranchProfile {
  BranchProfile(
      {required this.id,
      required this.name,
      this.address = '',
      this.phone = ''});
  String id;
  String name;
  String address;
  String phone;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'address': address, 'phone': phone};
  factory BranchProfile.fromJson(Map<String, dynamic> json) => BranchProfile(
      id: json['id'] ?? newId(),
      name: json['name'] ?? 'Main Branch',
      address: json['address'] ?? '',
      phone: json['phone'] ?? '');
  factory BranchProfile.fromApi(Map<String, dynamic> json) => BranchProfile(
      id: json['id'] ?? newId(),
      name: json['name'] ?? 'Main Branch',
      address: json['address'] ?? '',
      phone: json['phone'] ?? '');
}

class BranchDraft {
  BranchDraft({required this.name, this.address = '', this.phone = ''});
  String name;
  String address;
  String phone;
}

class AppUser {
  AppUser(
      {this.id,
      required this.name,
      required this.username,
      required this.role,
      required this.pin,
      required this.permissions,
      List<String> branchIds = const []})
      : branchIds = [...branchIds];
  String? id;
  String name;
  String username;
  String role;
  String pin;
  List<String> permissions;
  List<String> branchIds;
  bool get isOwner => role == 'Owner';
  bool get hasAllPrivileges =>
      AppPermission.all.every((permission) => can(permission));
  bool can(String permission) => isOwner || permissions.contains(permission);
  bool canLoginAtBranch(String? branchId) =>
      isOwner ||
      hasAllPrivileges ||
      (branchId != null && branchIds.contains(branchId));
  List<String> get cloudPermissions => [
        ...permissions.where((item) => !item.startsWith('branch:')),
        ...branchIds.map((id) => 'branch:$id')
      ];
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'username': username,
        'role': role,
        'pin': pin,
        'permissions': permissions,
        'branchIds': branchIds
      };
  factory AppUser.fromJson(Map<String, dynamic> json) {
    final rawPermissions = List<String>.from(json['permissions'] ?? []);
    final role = json['role'] ?? 'Cashier';
    return AppUser(
      id: json['id'],
      name: json['name'] ?? '',
      username: json['username'] ?? json['name'] ?? '',
      role: role,
      pin: json['pin'] ?? '',
      permissions: normalizePermissions(rawPermissions
              .where((item) => !item.startsWith('branch:'))
              .toList())
          .ifEmpty(defaultPermissionsForRole(role)),
      branchIds: List<String>.from(json['branchIds'] ??
          rawPermissions
              .where((item) => item.startsWith('branch:'))
              .map((item) => item.substring('branch:'.length))),
    );
  }
  factory AppUser.fromApi(Map<String, dynamic> json) {
    final role = roleLabel(json['role'] ?? 'cashier');
    final rawPermissions = List<String>.from(json['permissions'] ?? []);
    return AppUser(
      id: json['id'],
      name: json['name'] ?? '',
      username: json['username'] ?? json['name'] ?? '',
      role: role,
      pin: json['pin'] ?? '',
      permissions: normalizePermissions(rawPermissions
              .where((item) => !item.startsWith('branch:'))
              .toList())
          .ifEmpty(defaultPermissionsForRole(role)),
      branchIds: rawPermissions
          .where((item) => item.startsWith('branch:'))
          .map((item) => item.substring('branch:'.length))
          .toList(),
    );
  }
}

class UserDraft {
  UserDraft(
      {required this.name,
      required this.username,
      required this.role,
      required this.pin,
      required this.permissions,
      required this.branchIds});
  String name;
  String username;
  String role;
  String pin;
  List<String> permissions;
  List<String> branchIds;
}

class AppPermission {
  static const dashboard = 'dashboard';
  static const profit = 'profit';
  static const pos = 'pos';
  static const inventory = 'inventory';
  static const branches = 'branches';
  static const customers = 'customers';
  static const printing = 'printing';
  static const fiscal = 'fiscal';
  static const admin = 'admin';

  static const all = [
    dashboard,
    profit,
    pos,
    inventory,
    branches,
    customers,
    printing,
    fiscal,
    admin
  ];
  static const legacyAll = [
    dashboard,
    pos,
    inventory,
    branches,
    customers,
    printing,
    fiscal,
    admin
  ];
  static const labels = {
    dashboard: 'Dashboard and reports',
    profit: 'Profit and loss accounting',
    pos: 'POS selling',
    inventory: 'Inventory and stock',
    branches: 'Branches and device assignment',
    customers: 'Customers and debt',
    printing: 'Receipts and printing',
    fiscal: 'Fiscal settings and day control',
    admin: 'Users, cloud, and admin',
  };
}

List<String> normalizePermissions(List<String> permissions) {
  final unique = permissions.toSet();
  final hadLegacyFullAccess = AppPermission.legacyAll
      .every((permission) => unique.contains(permission));
  if (hadLegacyFullAccess) unique.add(AppPermission.profit);
  return unique.toList();
}

List<String> defaultPermissionsForRole(String role) {
  return switch (role) {
    'Owner' => AppPermission.all,
    'Manager' => [
        AppPermission.dashboard,
        AppPermission.profit,
        AppPermission.pos,
        AppPermission.inventory,
        AppPermission.branches,
        AppPermission.customers,
        AppPermission.printing
      ],
    'Cashier' => [
        AppPermission.pos,
        AppPermission.customers,
        AppPermission.printing
      ],
    'Stock Clerk' => [AppPermission.inventory],
    'Auditor' => [
        AppPermission.dashboard,
        AppPermission.profit,
        AppPermission.printing
      ],
    'Branch Supervisor' => [
        AppPermission.dashboard,
        AppPermission.profit,
        AppPermission.pos,
        AppPermission.inventory,
        AppPermission.branches,
        AppPermission.customers,
        AppPermission.printing
      ],
    _ => [AppPermission.pos],
  };
}

String roleLabel(String role) {
  return switch (role) {
    'owner' => 'Owner',
    'manager' => 'Manager',
    'cashier' => 'Cashier',
    'auditor' => 'Auditor',
    'stock_clerk' => 'Stock Clerk',
    'branch_supervisor' => 'Branch Supervisor',
    _ => role,
  };
}

String roleApiValue(String role) {
  return switch (role) {
    'Owner' => 'owner',
    'Manager' => 'manager',
    'Cashier' => 'cashier',
    'Auditor' => 'auditor',
    'Stock Clerk' => 'stock_clerk',
    'Branch Supervisor' => 'branch_supervisor',
    _ => role,
  };
}

class Product {
  Product(
      {required this.id,
      required this.name,
      this.category = '',
      required this.sku,
      required this.barcode,
      required this.priceCents,
      this.costCents = 0,
      required this.stock,
      required this.reorderLevel,
      this.supplierId = '',
      this.isCustom = false});
  String id;
  String name;
  String category;
  String sku;
  String barcode;
  int priceCents;
  int costCents;
  int stock;
  int reorderLevel;
  String supplierId;
  bool isCustom;
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'category': category,
        'sku': sku,
        'barcode': barcode,
        'priceCents': priceCents,
        'costCents': costCents,
        'stock': stock,
        'reorderLevel': reorderLevel,
        'supplierId': supplierId,
        'isCustom': isCustom
      };
  factory Product.fromJson(Map<String, dynamic> json) => Product(
      id: json['id'],
      name: json['name'],
      category: json['category'] ?? '',
      sku: json['sku'] ?? '',
      barcode: json['barcode'] ?? '',
      priceCents: json['priceCents'] ?? json['price_cents'] ?? 0,
      costCents: json['costCents'] ?? json['cost_price_cents'] ?? 0,
      stock: json['stock'] ?? 0,
      reorderLevel: json['reorderLevel'] ?? 5,
      supplierId: json['supplierId'] ?? json['supplier_id'] ?? '',
      isCustom: json['isCustom'] ?? false);
  factory Product.fromApi(Map<String, dynamic> json, int stock) => Product(
      id: json['id'],
      name: json['name'],
      category: json['category'] ?? '',
      sku: json['sku'] ?? '',
      barcode: json['barcode'] ?? '',
      priceCents: json['price_cents'],
      costCents: json['cost_price_cents'] ?? 0,
      stock: stock,
      reorderLevel: json['reorder_level'] ?? 5,
      supplierId: json['supplier_id'] ?? '');
}

class Supplier {
  Supplier(
      {required this.id, required this.name, this.phone = '', this.notes = ''});
  String id;
  String name;
  String phone;
  String notes;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'phone': phone, 'notes': notes};
  factory Supplier.fromJson(Map<String, dynamic> json) => Supplier(
      id: json['id'],
      name: json['name'] ?? '',
      phone: json['phone'] ?? '',
      notes: json['notes'] ?? '');
  factory Supplier.fromApi(Map<String, dynamic> json) => Supplier(
      id: json['id'],
      name: json['name'] ?? '',
      phone: json['phone'] ?? '',
      notes: json['notes'] ?? '');
}

class Customer {
  Customer(
      {required this.id, required this.name, required this.phone, String? code})
      : code = code ?? customerShortCode(id);
  String id;
  String name;
  String phone;
  String code;
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'phone': phone, 'code': code};
  factory Customer.fromJson(Map<String, dynamic> json) => Customer(
      id: json['id'],
      name: json['name'],
      phone: json['phone'] ?? '',
      code: json['code']);
  factory Customer.fromApi(Map<String, dynamic> json) =>
      Customer(id: json['id'], name: json['name'], phone: json['phone'] ?? '');
}

class CartItem {
  CartItem({required this.product, required this.quantity});
  Product product;
  int quantity;

  Map<String, dynamic> toJson() =>
      {'product': product.toJson(), 'quantity': quantity};

  factory CartItem.fromJson(
      Map<String, dynamic> json, List<Product> productMaster) {
    final productJson = Map<String, dynamic>.from(json['product'] ?? {});
    final productId = '${productJson['id'] ?? ''}';
    final masterProduct =
        productMaster.where((product) => product.id == productId).firstOrNull;
    return CartItem(
      product: masterProduct ?? Product.fromJson(productJson),
      quantity: json['quantity'] ?? 1,
    );
  }
}

class SaleRecord {
  SaleRecord(
      {required this.id,
      this.branchId = '',
      required this.totalCents,
      required this.paymentMethod,
      required this.cashier,
      required this.customerName,
      this.discountCents = 0,
      this.paidCents = 0,
      this.changeCents = 0,
      this.debtCents = 0,
      this.lines = const [],
      required this.createdAt});
  String id;
  String branchId;
  int totalCents;
  String paymentMethod;
  String cashier;
  String customerName;
  int discountCents;
  int paidCents;
  int changeCents;
  int debtCents;
  List<ReceiptLineSnapshot> lines;
  DateTime createdAt;
  int get subtotalCents => lines.isEmpty
      ? totalCents + discountCents
      : lines.fold(0, (sum, line) => sum + line.lineTotalCents);
  Map<String, dynamic> toJson() => {
        'id': id,
        'branchId': branchId,
        'totalCents': totalCents,
        'paymentMethod': paymentMethod,
        'cashier': cashier,
        'customerName': customerName,
        'discountCents': discountCents,
        'paidCents': paidCents,
        'changeCents': changeCents,
        'debtCents': debtCents,
        'lines': lines.map((line) => line.toJson()).toList(),
        'createdAt': createdAt.toIso8601String()
      };
  factory SaleRecord.fromJson(Map<String, dynamic> json) => SaleRecord(
      id: json['id'],
      branchId: json['branchId'] ?? '',
      totalCents: json['totalCents'],
      paymentMethod: json['paymentMethod'],
      cashier: json['cashier'],
      customerName: json['customerName'] ?? '',
      discountCents: json['discountCents'] ?? 0,
      paidCents: json['paidCents'] ?? 0,
      changeCents: json['changeCents'] ?? 0,
      debtCents: json['debtCents'] ?? 0,
      lines: ((json['lines'] ?? []) as List)
          .map((line) =>
              ReceiptLineSnapshot.fromJson(Map<String, dynamic>.from(line)))
          .toList(),
      createdAt: DateTime.parse(json['createdAt']));
  factory SaleRecord.fromApi(Map<String, dynamic> json) => SaleRecord(
        id: '${json['id']}',
        branchId: '${json['branch_id'] ?? ''}',
        totalCents: json['total_cents'] ?? 0,
        paymentMethod: paymentMethodLabel(json['payment_method'] ?? 'cash'),
        cashier: json['cashier_name'] ?? 'Synced user',
        customerName: json['customer_name'] ?? '',
        discountCents: json['discount_cents'] ?? 0,
        paidCents: json['paid_cents'] ?? 0,
        changeCents: json['change_cents'] ?? 0,
        debtCents: json['debt_cents'] ?? 0,
        lines: ((json['lines'] ?? []) as List)
            .map((line) =>
                ReceiptLineSnapshot.fromJson(Map<String, dynamic>.from(line)))
            .toList(),
        createdAt: DateTime.tryParse('${json['created_at']}')?.toLocal() ??
            DateTime.now(),
      );
}

class ReportProductPerformance {
  const ReportProductPerformance(
      {required this.name,
      required this.quantity,
      required this.revenueCents,
      this.branchName = '',
      this.costCents = 0,
      this.profitCents = 0});
  final String name;
  final String branchName;
  final int quantity;
  final int revenueCents;
  final int costCents;
  final int profitCents;
}

class ReportSnapshot {
  const ReportSnapshot({
    required this.title,
    required this.sales,
    required this.totalSalesCents,
    required this.grossSalesCents,
    required this.voidedCents,
    required this.discountCents,
    required this.costOfGoodsCents,
    required this.grossProfitCents,
    required this.grossMarginPercent,
    required this.stockValueAtCostCents,
    required this.stockValueAtRetailCents,
    required this.potentialStockProfitCents,
    required this.debtCents,
    required this.paidCents,
    required this.transactionCount,
    required this.averageSaleCents,
    required this.cashCents,
    required this.cardCents,
    required this.mobileMoneyCents,
    required this.topProducts,
    required this.slowProducts,
    required this.userPerformance,
  });

  final String title;
  final List<SaleRecord> sales;
  final int totalSalesCents;
  final int grossSalesCents;
  final int voidedCents;
  final int discountCents;
  final int costOfGoodsCents;
  final int grossProfitCents;
  final double grossMarginPercent;
  final int stockValueAtCostCents;
  final int stockValueAtRetailCents;
  final int potentialStockProfitCents;
  final int debtCents;
  final int paidCents;
  final int transactionCount;
  final int averageSaleCents;
  final int cashCents;
  final int cardCents;
  final int mobileMoneyCents;
  final List<ReportProductPerformance> topProducts;
  final List<ReportProductPerformance> slowProducts;
  final List<UserPerformanceReport> userPerformance;
}

class UserPerformanceReport {
  const UserPerformanceReport({
    required this.userName,
    required this.transactionCount,
    required this.grossCents,
    required this.voidedCents,
    required this.netCents,
    required this.costCents,
    required this.profitCents,
    required this.debtCents,
  });

  final String userName;
  final int transactionCount;
  final int grossCents;
  final int voidedCents;
  final int netCents;
  final int costCents;
  final int profitCents;
  final int debtCents;
}

enum AccountingEntryType { expense, income }

AccountingEntryType accountingEntryTypeFromText(String value) =>
    value.toLowerCase() == 'income'
        ? AccountingEntryType.income
        : AccountingEntryType.expense;

class AccountingEntry {
  AccountingEntry({
    required this.id,
    required this.branchId,
    required this.type,
    required this.category,
    required this.description,
    required this.amountCents,
    this.paymentMethod = '',
    this.counterparty = '',
    required this.createdAt,
  });

  String id;
  String branchId;
  AccountingEntryType type;
  String category;
  String description;
  int amountCents;
  String paymentMethod;
  String counterparty;
  DateTime createdAt;

  String get typeText =>
      type == AccountingEntryType.income ? 'income' : 'expense';
  String get typeLabel =>
      type == AccountingEntryType.income ? 'Income' : 'Expense';
  String get normalizedCategory => category.trim().toLowerCase();
  bool get isStockPurchase => normalizedCategory == 'stock purchase';
  bool get isSupplierPayment => normalizedCategory == 'supplier payment';
  bool get isOwnerDrawing => normalizedCategory == 'owner drawings';
  bool get isPayroll =>
      normalizedCategory == 'payroll' ||
      normalizedCategory == 'salary payment' ||
      normalizedCategory == 'employee advance';
  int get batchQuantity {
    final match = RegExp(r'(\d+)\s+x\s+').firstMatch(description);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  String get batchProductName {
    final withoutQuantity =
        description.replaceFirst(RegExp(r'^\s*\d+\s+x\s+'), '').trim();
    final pipeIndex = withoutQuantity.indexOf('|');
    return (pipeIndex >= 0
            ? withoutQuantity.substring(0, pipeIndex)
            : withoutQuantity)
        .trim();
  }

  String get batchNumber {
    final match = RegExp(r'Batch:\s*([^|]+)', caseSensitive: false)
        .firstMatch(description);
    return match?.group(1)?.trim() ?? '';
  }

  DateTime? get batchExpiryDate {
    final match = RegExp(r'Expiry:\s*(\d{4}-\d{2}-\d{2})', caseSensitive: false)
        .firstMatch(description);
    return DateTime.tryParse(match?.group(1) ?? '');
  }

  bool get isBalanceSheetOnly =>
      isStockPurchase ||
      isSupplierPayment ||
      isOwnerDrawing ||
      normalizedCategory == 'owner capital' ||
      normalizedCategory == 'cash transfer' ||
      normalizedCategory == 'customer debt payment' ||
      normalizedCategory == 'purchase order' ||
      normalizedCategory == 'stock count' ||
      normalizedCategory == 'cash-up' ||
      normalizedCategory == 'reconciliation';
  bool get affectsProfitAndLoss => !isBalanceSheetOnly;

  Map<String, dynamic> toJson() => {
        'id': id,
        'branchId': branchId,
        'type': typeText,
        'category': category,
        'description': description,
        'amountCents': amountCents,
        'paymentMethod': paymentMethod,
        'counterparty': counterparty,
        'createdAt': createdAt.toIso8601String(),
      };

  factory AccountingEntry.fromJson(Map<String, dynamic> json) =>
      AccountingEntry(
        id: '${json['id']}',
        branchId: json['branchId'] ?? json['branch_id'] ?? '',
        type: accountingEntryTypeFromText('${json['type'] ?? 'expense'}'),
        category: json['category'] ?? 'General',
        description: json['description'] ?? '',
        amountCents: json['amountCents'] ?? json['amount_cents'] ?? 0,
        paymentMethod: json['paymentMethod'] ?? json['payment_method'] ?? '',
        counterparty: json['counterparty'] ?? '',
        createdAt: DateTime.tryParse(
              '${json['createdAt'] ?? json['created_at'] ?? ''}',
            )?.toLocal() ??
            DateTime.now(),
      );
}

class ProfitLossStatement {
  ProfitLossStatement({
    required this.period,
    required this.report,
    required this.entries,
    required this.operatingExpensesCents,
    required this.otherIncomeCents,
    required this.netProfitCents,
    required this.netMarginPercent,
    required this.stockPurchasesCents,
    required this.supplierPaymentsCents,
    required this.supplierPayablesCents,
    required this.customerDebtOutstandingCents,
    required this.ownerCapitalCents,
    required this.ownerDrawingsCents,
    required this.supplierBalances,
    required this.cashbookByMethod,
    required this.customerDebtAging,
    required this.expensesByCategory,
    required this.incomeByCategory,
  });

  final String period;
  final ReportSnapshot report;
  final List<AccountingEntry> entries;
  final int operatingExpensesCents;
  final int otherIncomeCents;
  final int netProfitCents;
  final double netMarginPercent;
  final int stockPurchasesCents;
  final int supplierPaymentsCents;
  final int supplierPayablesCents;
  final int customerDebtOutstandingCents;
  final int ownerCapitalCents;
  final int ownerDrawingsCents;
  final Map<String, int> supplierBalances;
  final Map<String, int> cashbookByMethod;
  final Map<String, int> customerDebtAging;
  final Map<String, int> expensesByCategory;
  final Map<String, int> incomeByCategory;

  String get title {
    if (period.startsWith('date:')) {
      return period.substring(5);
    }
    return switch (period) {
      'yearly' => 'Yearly',
      'weekly' => 'Weekly',
      'monthly' => 'Monthly',
      _ => 'Daily',
    };
  }
}

class BatchExpiryRecord {
  const BatchExpiryRecord({
    required this.entry,
    required this.productName,
    required this.batchNumber,
    required this.expiryDate,
    required this.quantity,
  });

  final AccountingEntry entry;
  final String productName;
  final String batchNumber;
  final DateTime expiryDate;
  final int quantity;

  bool get expired => expiryDate.isBefore(
      DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day));

  int get daysLeft =>
      DateTime(expiryDate.year, expiryDate.month, expiryDate.day)
          .difference(DateTime(
              DateTime.now().year, DateTime.now().month, DateTime.now().day))
          .inDays;
}

class AuditRow {
  const AuditRow({
    required this.when,
    required this.action,
    required this.actor,
    required this.branch,
    required this.detail,
  });

  final DateTime when;
  final String action;
  final String actor;
  final String branch;
  final String detail;
}

class SmartInsight {
  const SmartInsight({
    required this.tone,
    required this.title,
    required this.body,
    required this.icon,
  });

  final Tone tone;
  final String title;
  final String body;
  final IconData icon;
}

class SaleVoidRecord {
  SaleVoidRecord({
    required this.id,
    required this.saleId,
    required this.branchId,
    required this.type,
    required this.reason,
    required this.userName,
    required this.totalCents,
    required this.lines,
    required this.createdAt,
  });

  String id;
  String saleId;
  String branchId;
  String type;
  String reason;
  String userName;
  int totalCents;
  List<ReceiptLineSnapshot> lines;
  DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'saleId': saleId,
        'branchId': branchId,
        'type': type,
        'reason': reason,
        'userName': userName,
        'totalCents': totalCents,
        'lines': lines.map((line) => line.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory SaleVoidRecord.fromJson(Map<String, dynamic> json) => SaleVoidRecord(
        id: json['id'] ?? newId(),
        saleId: json['saleId'] ?? '',
        branchId: json['branchId'] ?? '',
        type: json['type'] ?? 'partial_void',
        reason: json['reason'] ?? '',
        userName: json['userName'] ?? 'User',
        totalCents: json['totalCents'] ?? 0,
        lines: ((json['lines'] ?? []) as List)
            .map((line) =>
                ReceiptLineSnapshot.fromJson(Map<String, dynamic>.from(line)))
            .toList(),
        createdAt: DateTime.tryParse('${json['createdAt']}') ?? DateTime.now(),
      );

  factory SaleVoidRecord.fromApi(Map<String, dynamic> json) => SaleVoidRecord(
        id: '${json['id'] ?? newId()}',
        saleId: '${json['sale_id'] ?? ''}',
        branchId: '${json['branch_id'] ?? ''}',
        type: '${json['void_type'] ?? 'partial_void'}',
        reason: json['reason'] ?? '',
        userName: json['user_name'] ?? 'User',
        totalCents: json['total_cents'] ?? 0,
        lines: ((json['lines'] ?? []) as List)
            .map((line) =>
                ReceiptLineSnapshot.fromJson(Map<String, dynamic>.from(line)))
            .toList(),
        createdAt: DateTime.tryParse('${json['created_at']}')?.toLocal() ??
            DateTime.now(),
      );
}

class StockTransferRecord {
  StockTransferRecord({
    required this.id,
    required this.productId,
    required this.productName,
    required this.fromBranchId,
    required this.fromBranchName,
    required this.toBranchId,
    required this.toBranchName,
    required this.quantity,
    required this.userName,
    required this.createdAt,
  });

  String id;
  String productId;
  String productName;
  String fromBranchId;
  String fromBranchName;
  String toBranchId;
  String toBranchName;
  int quantity;
  String userName;
  DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'productId': productId,
        'productName': productName,
        'fromBranchId': fromBranchId,
        'fromBranchName': fromBranchName,
        'toBranchId': toBranchId,
        'toBranchName': toBranchName,
        'quantity': quantity,
        'userName': userName,
        'createdAt': createdAt.toIso8601String(),
      };

  factory StockTransferRecord.fromJson(Map<String, dynamic> json) =>
      StockTransferRecord(
        id: json['id'] ?? newId(),
        productId: json['productId'] ?? '',
        productName: json['productName'] ?? 'Stock item',
        fromBranchId: json['fromBranchId'] ?? '',
        fromBranchName: json['fromBranchName'] ?? 'Source branch',
        toBranchId: json['toBranchId'] ?? '',
        toBranchName: json['toBranchName'] ?? 'Target branch',
        quantity: json['quantity'] ?? 0,
        userName: json['userName'] ?? 'User',
        createdAt: DateTime.tryParse('${json['createdAt']}') ?? DateTime.now(),
      );

  factory StockTransferRecord.fromApi(Map<String, dynamic> json) =>
      StockTransferRecord(
        id: '${json['id'] ?? newId()}',
        productId: '${json['product_id'] ?? ''}',
        productName: json['product_name'] ?? 'Stock item',
        fromBranchId: '${json['from_branch_id'] ?? ''}',
        fromBranchName: json['from_branch_name'] ?? 'Source branch',
        toBranchId: '${json['to_branch_id'] ?? ''}',
        toBranchName: json['to_branch_name'] ?? 'Target branch',
        quantity: json['quantity'] ?? 0,
        userName: json['user_name'] ?? 'User',
        createdAt: DateTime.tryParse('${json['created_at']}') ?? DateTime.now(),
      );
}

class ReceiptLineSnapshot {
  ReceiptLineSnapshot({
    this.productId = '',
    required this.name,
    required this.quantity,
    required this.unitPriceCents,
    required this.lineTotalCents,
    this.unitCostCents = 0,
    int? lineCostCents,
  }) : _lineCostCents = lineCostCents;

  String productId;
  String name;
  int quantity;
  int unitPriceCents;
  int lineTotalCents;
  int unitCostCents;
  int? _lineCostCents;
  int get lineCostCents => _lineCostCents ?? unitCostCents * quantity;
  set lineCostCents(int value) => _lineCostCents = value;

  Map<String, dynamic> toJson() => {
        'productId': productId,
        'name': name,
        'quantity': quantity,
        'unitPriceCents': unitPriceCents,
        'lineTotalCents': lineTotalCents,
        'unitCostCents': unitCostCents,
        'lineCostCents': lineCostCents,
      };

  factory ReceiptLineSnapshot.fromJson(Map<String, dynamic> json) =>
      ReceiptLineSnapshot(
        productId: json['productId'] ?? json['product_id'] ?? '',
        name: json['name'] ??
            json['productName'] ??
            json['product_name'] ??
            json['description'] ??
            '',
        quantity: json['quantity'] ?? 1,
        unitPriceCents: json['unitPriceCents'] ?? json['unit_price_cents'] ?? 0,
        lineTotalCents: json['lineTotalCents'] ?? json['line_total_cents'] ?? 0,
        unitCostCents: json['unitCostCents'] ?? json['unit_cost_cents'] ?? 0,
        lineCostCents: json['lineCostCents'] ?? json['line_cost_cents'],
      );

  bool matches(ReceiptLineSnapshot other) {
    if (productId.isNotEmpty && other.productId.isNotEmpty) {
      return productId == other.productId;
    }
    return name == other.name && unitPriceCents == other.unitPriceCents;
  }
}

class ApiClient {
  ApiClient(String baseUrl) : baseUrl = baseUrl.replaceAll(RegExp(r'/$'), '');
  final String baseUrl;
  bool get usesSupabase => isSupabaseUrl(baseUrl);
  SupabaseRetailApi get _supabase =>
      SupabaseRetailApi(baseUrl, runtimeSupabaseAnonKey);

  Future<Map<String, dynamic>> createShop({
    required String shopName,
    required BranchProfile mainBranch,
    required bool fiscalMode,
    required AppUser owner,
    required List<AppUser> users,
    required List<BranchProfile> branches,
    required String deviceUid,
  }) {
    if (usesSupabase) {
      return _supabase.createShop(
        shopName: shopName,
        mainBranch: mainBranch,
        fiscalMode: fiscalMode,
        owner: owner,
        users: users,
        branches: branches,
        deviceUid: deviceUid,
      );
    }
    return _post('/api/app/create-shop', {
      'shop_name': shopName,
      'main_branch': _branchBody(mainBranch),
      'fiscal_mode': fiscalMode ? 'fiscal' : 'non_fiscal',
      'owner': _userBody(owner),
      'users': users.map(_userBody).toList(),
      'branches': branches.map(_branchBody).toList(),
      'device_uid': deviceUid,
      'device_name': 'Light Winter POS Device',
      'platform': Platform.isAndroid
          ? 'sunmi'
          : Platform.isWindows
              ? 'windows'
              : Platform.isIOS
                  ? 'ios'
                  : 'android',
    });
  }

  Future<void> testSupabase() => _supabase.testConnection();
  Future<void> healthCheck() async {
    final response = await http
        .get(Uri.parse('$baseUrl/health'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw StateError('${response.statusCode}: ${response.body}');
  }

  Future<Map<String, dynamic>> joinShop(
      {required String activationCode, required String deviceUid}) {
    if (usesSupabase)
      return _supabase.joinShop(
          activationCode: activationCode, deviceUid: deviceUid);
    return _post('/api/app/join-shop', {
      'activation_code': activationCode,
      'device_uid': deviceUid,
      'device_name': 'Light Winter POS Device',
      'platform': Platform.isAndroid
          ? 'sunmi'
          : Platform.isWindows
              ? 'windows'
              : Platform.isIOS
                  ? 'ios'
                  : 'android',
    });
  }

  Future<Map<String, dynamic>> recoverShop(String recoveryCode,
      String ownerUsername, String ownerPin, String deviceUid) {
    if (usesSupabase) {
      return _supabase.recoverShop(
          recoveryCode, ownerUsername, ownerPin, deviceUid);
    }
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> resetOwnerAccess(String recoveryCode,
      String deviceUid, String resetVoucher, String newPin) {
    if (usesSupabase) {
      return _supabase.resetOwnerAccess(
          recoveryCode, deviceUid, resetVoucher, newPin);
    }
    throw StateError('Owner reset vouchers require Supabase.');
  }

  Future<Map<String, dynamic>> bootstrap(String deviceUid) => usesSupabase
      ? _supabase.bootstrap(deviceUid)
      : _get('/api/app/bootstrap/$deviceUid');
  Future<Map<String, dynamic>> applyLicense(String deviceUid, String token,
          {String? organizationId, String? branchId}) =>
      usesSupabase
          ? _supabase.applyLicense(deviceUid, token)
          : _post('/api/app/devices/$deviceUid/license',
              {'device_uid': deviceUid, 'token': token});
  Future<Map<String, dynamic>> createUser(
          String orgId, String deviceUid, AppUser user) =>
      usesSupabase
          ? _supabase.createUser(orgId, deviceUid, user)
          : _post('/api/app/organizations/$orgId/users?device_uid=$deviceUid',
              _userBody(user));
  Future<Map<String, dynamic>> updateCompany(
          String orgId, String deviceUid, Company company) =>
      usesSupabase
          ? _supabase.updateCompany(orgId, deviceUid, company)
          : bootstrap(deviceUid);
  Future<Map<String, dynamic>> updateUser(
          String userId, String deviceUid, AppUser user) =>
      usesSupabase
          ? _supabase.updateUser(userId, deviceUid, user)
          : _put('/api/app/users/$userId?device_uid=$deviceUid',
              {..._userBody(user), 'active': true});
  Future<Map<String, dynamic>> deleteUser(String userId, String deviceUid) =>
      usesSupabase
          ? _supabase.deleteUser(userId, deviceUid)
          : _delete('/api/app/users/$userId?device_uid=$deviceUid');
  Future<Map<String, dynamic>> createBranch(
          String orgId, String deviceUid, BranchDraft branch) =>
      usesSupabase
          ? _supabase.createBranch(orgId, deviceUid, branch)
          : _post(
              '/api/app/organizations/$orgId/branches?device_uid=$deviceUid', {
              'name': branch.name,
              'phone': branch.phone,
              'address': branch.address
            });
  Future<Map<String, dynamic>> updateBranch(
          String branchId, String deviceUid, BranchDraft branch) =>
      usesSupabase
          ? _supabase.updateBranch(branchId, deviceUid, branch)
          : _put('/api/app/branches/$branchId?device_uid=$deviceUid', {
              'name': branch.name,
              'phone': branch.phone,
              'address': branch.address,
              'active': true
            });
  Future<Map<String, dynamic>> deleteBranch(
          String branchId, String deviceUid) =>
      usesSupabase
          ? _supabase.deleteBranch(branchId, deviceUid)
          : _delete('/api/app/branches/$branchId?device_uid=$deviceUid');
  Future<Map<String, dynamic>> assignDeviceToBranch(
          String deviceUid, String branchId) =>
      usesSupabase
          ? _supabase.assignDeviceToBranch(deviceUid, branchId)
          : _put('/api/app/devices/$deviceUid/branch', {'branch_id': branchId});
  Future<Map<String, dynamic>> loadBranchView(
          String deviceUid, String branchId) =>
      usesSupabase
          ? _supabase.loadBranchView(deviceUid, branchId)
          : assignDeviceToBranch(deviceUid, branchId);
  Future<Map<String, dynamic>> transferStock(String deviceUid,
          String fromBranchId, String toBranchId, String productId, int qty,
          {String productName = '', String userName = ''}) =>
      usesSupabase
          ? _supabase.transferStock(
              deviceUid, fromBranchId, toBranchId, productId, qty,
              productName: productName, userName: userName)
          : _post('/api/stock/transfer', {
              'device_uid': deviceUid,
              'from_branch_id': fromBranchId,
              'to_branch_id': toBranchId,
              'product_id': productId,
              'quantity': qty
            });
  Future<Map<String, dynamic>> updateExchangeRates(
          String orgId,
          String deviceUid,
          Map<String, double> rates,
          String displayCurrency) =>
      usesSupabase
          ? _supabase.updateExchangeRates(
              orgId, deviceUid, rates, displayCurrency)
          : bootstrap(deviceUid);
  Future<Map<String, dynamic>> openFiscalDay(
          String deviceUid, String? userId, int dayNo) =>
      usesSupabase
          ? _supabase.openFiscalDay(deviceUid, userId, dayNo)
          : bootstrap(deviceUid);
  Future<Map<String, dynamic>> closeFiscalDay(
          String deviceUid, String? userId, int dayNo) =>
      usesSupabase
          ? _supabase.closeFiscalDay(deviceUid, userId, dayNo)
          : bootstrap(deviceUid);
  Future<Map<String, dynamic>> createCustomer(
          String orgId, String deviceUid, Customer customer) =>
      usesSupabase
          ? _supabase.createCustomer(orgId, deviceUid, customer)
          : _post(
              '/api/app/organizations/$orgId/customers?device_uid=$deviceUid',
              {'name': customer.name, 'phone': customer.phone});
  Future<Map<String, dynamic>> adjustStock(
          String deviceUid, String branchId, String productId, int delta) =>
      usesSupabase
          ? _supabase.adjustStock(deviceUid, branchId, productId, delta)
          : _post('/api/stock/adjust', {
              'branch_id': branchId,
              'product_id': productId,
              'movement_type': 'adjustment',
              'quantity_delta': delta,
              'reason': 'Device stock adjustment'
            });

  Future<Map<String, dynamic>> createProduct(
      String orgId, String branchId, String deviceUid, Product product) async {
    if (usesSupabase)
      return _supabase.createProduct(orgId, branchId, deviceUid, product);
    final productResponse = await _post('/api/products', {
      'organization_id': orgId,
      'sku': product.sku,
      'barcode': product.barcode,
      'name': product.name,
      'selling_price_cents': product.priceCents,
      'buying_cost_cents': product.costCents,
      'reorder_threshold': product.reorderLevel,
    });
    await _post('/api/stock/adjust', {
      'branch_id': branchId,
      'product_id': productResponse['id'],
      'movement_type': 'opening',
      'quantity_delta': product.stock,
      'reason': 'Opening stock from device',
    });
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> updateProduct(
          String deviceUid, String branchId, Product product) =>
      usesSupabase
          ? _supabase.updateProduct(deviceUid, branchId, product)
          : bootstrap(deviceUid);

  Future<Map<String, dynamic>> deleteProduct(
          String deviceUid, String productId) =>
      usesSupabase
          ? _supabase.deleteProduct(deviceUid, productId)
          : bootstrap(deviceUid);

  Future<Map<String, dynamic>> upsertProduct(
          String orgId, String branchId, String deviceUid, Product product) =>
      usesSupabase
          ? _supabase.upsertProduct(orgId, branchId, deviceUid, product)
          : updateProduct(deviceUid, branchId, product);

  Future<Map<String, dynamic>> upsertProducts(String orgId, String branchId,
          String deviceUid, List<Product> products) =>
      usesSupabase
          ? _supabase.upsertProducts(orgId, branchId, deviceUid, products)
          : bootstrap(deviceUid);

  Future<Map<String, dynamic>> upsertSupplier(
          String orgId, String deviceUid, Supplier supplier,
          {bool refresh = true}) =>
      usesSupabase
          ? _supabase.upsertSupplier(orgId, deviceUid, supplier,
              refresh: refresh)
          : bootstrap(deviceUid);

  Future<Map<String, dynamic>> deleteSupplier(
          String deviceUid, String supplierId) =>
      usesSupabase
          ? _supabase.deleteSupplier(deviceUid, supplierId)
          : bootstrap(deviceUid);

  Future<void> createSale(
      String deviceUid,
      String? cashierId,
      String? customerId,
      String paymentMethod,
      List<CartItem> lines,
      int totalCents,
      {String? saleId,
      int discountCents = 0,
      int paidCents = 0,
      int changeCents = 0,
      int debtCents = 0}) async {
    if (usesSupabase) {
      await _supabase.createSale(
          deviceUid, cashierId, customerId, paymentMethod, lines, totalCents,
          saleId: saleId,
          discountCents: discountCents,
          paidCents: paidCents,
          changeCents: changeCents,
          debtCents: debtCents);
      return;
    }
    await _post('/api/sales', {
      'device_uid': deviceUid,
      'cashier_user_id': cashierId,
      'customer_id': customerId,
      'payment_method': paymentMethod.toLowerCase() == 'debt'
          ? 'debt'
          : paymentMethod.toLowerCase() == 'card'
              ? 'card'
              : 'cash',
      'paid_cents': totalCents,
      'lines': lines
          .map((item) => {
                'product_id': item.product.id,
                'quantity': item.quantity,
                'unit_price_cents': item.product.priceCents,
                'discount_cents': 0
              })
          .toList(),
    });
  }

  Future<void> updateSaleDebt(
          String deviceUid, String saleId, int paidCents, int debtCents) =>
      usesSupabase
          ? _supabase.updateSaleDebt(deviceUid, saleId, paidCents, debtCents)
          : Future.value();

  Future<Map<String, dynamic>> voidSale(
          String deviceUid, String? userId, SaleVoidRecord record) =>
      usesSupabase
          ? _supabase.voidSale(deviceUid, userId, record)
          : bootstrap(deviceUid);

  Future<void> createAccountingEntry(String orgId, String branchId,
      String deviceUid, AccountingEntry entry) async {
    if (usesSupabase) {
      await _supabase.createAccountingEntry(orgId, branchId, deviceUid, entry);
    }
  }

  Future<void> deleteAccountingEntry(String deviceUid, String entryId) async {
    if (usesSupabase) {
      await _supabase.deleteAccountingEntry(deviceUid, entryId);
    }
  }

  Future<void> deleteSales(String deviceUid, List<String> saleIds) async {
    if (usesSupabase) {
      await _supabase.deleteSales(deviceUid, saleIds);
    }
  }

  Future<void> deleteCustomers(
      String deviceUid, List<String> customerIds) async {
    if (usesSupabase) {
      await _supabase.deleteCustomers(deviceUid, customerIds);
    }
  }

  Future<void> deleteStockTransfers(
      String deviceUid, List<String> transferIds) async {
    if (usesSupabase) {
      await _supabase.deleteStockTransfers(deviceUid, transferIds);
    }
  }

  Future<void> deleteSaleVoids(String deviceUid, List<String> voidIds) async {
    if (usesSupabase) {
      await _supabase.deleteSaleVoids(deviceUid, voidIds);
    }
  }

  Map<String, dynamic> _userBody(AppUser user) => {
        'name': user.name,
        'username': user.username,
        'pin': user.pin.isEmpty ? '0000' : user.pin,
        'role': roleApiValue(user.role),
        'permissions': user.cloudPermissions
      };
  Map<String, dynamic> _branchBody(BranchProfile branch) =>
      {'name': branch.name, 'phone': branch.phone, 'address': branch.address};

  Future<Map<String, dynamic>> _get(String path) async => _handle(await http
      .get(Uri.parse('$baseUrl$path'))
      .timeout(const Duration(seconds: 10)));
  Future<Map<String, dynamic>> _post(
          String path, Map<String, dynamic> body) async =>
      _handle(await http
          .post(Uri.parse('$baseUrl$path'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 10)));
  Future<Map<String, dynamic>> _put(
          String path, Map<String, dynamic> body) async =>
      _handle(await http
          .put(Uri.parse('$baseUrl$path'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 10)));
  Future<Map<String, dynamic>> _delete(String path) async => _handle(await http
      .delete(Uri.parse('$baseUrl$path'))
      .timeout(const Duration(seconds: 10)));

  Map<String, dynamic> _handle(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('${response.statusCode}: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

class SupabaseRetailApi {
  SupabaseRetailApi(String url, this.anonKey)
      : url = _projectUrl(url),
        restUrl = '${_projectUrl(url)}/rest/v1';
  static const requestTimeout = Duration(seconds: 8);
  final String url;
  final String restUrl;
  final String anonKey;

  Map<String, String> get _headers {
    if (anonKey.isEmpty) {
      throw StateError(
          'Cloud license key is missing from this APK. Contact Light Winter Technologies for a corrected installer.');
    }
    return {
      'apikey': anonKey,
      'authorization': 'Bearer $anonKey',
      'content-type': 'application/json',
      'prefer': 'return=representation',
    };
  }

  String get _platform => Platform.isAndroid
      ? 'sunmi_android'
      : Platform.isWindows
          ? 'windows'
          : Platform.isIOS
              ? 'ios'
              : 'android';

  Future<Map<String, dynamic>> createShop({
    required String shopName,
    required BranchProfile mainBranch,
    required bool fiscalMode,
    required AppUser owner,
    required List<AppUser> users,
    required List<BranchProfile> branches,
    required String deviceUid,
  }) async {
    await _rpc('lwr_create_shop', {
      'p_shop_name': shopName,
      'p_main_branch': _branchRow(mainBranch),
      'p_fiscal_mode': fiscalMode,
      'p_owner': _userRow('', owner),
      'p_users': users.map((user) => _userRow('', user)).toList(),
      'p_branches': branches.map(_branchRow).toList(),
      'p_device_uid': deviceUid,
      'p_platform': _platform,
    });
    final data = await bootstrap(deviceUid);
    return data;
  }

  Future<void> testConnection() async {
    await _select('lwr_organizations', {'limit': '1'});
  }

  Future<Map<String, dynamic>> joinShop(
      {required String activationCode, required String deviceUid}) async {
    final codes = await _select('lwr_activation_codes', {
      'code': 'eq.${activationCode.trim().toUpperCase()}',
      'active': 'eq.true'
    });
    if (codes.isEmpty)
      throw StateError('Activation code not found or inactive.');
    final code = codes.first;
    final orgId = code['organization_id'];
    final branchId = code['branch_id'];
    final existing =
        await _select('lwr_devices', {'device_uid': 'eq.$deviceUid'});
    if (existing.isEmpty) {
      await _insert('lwr_devices', {
        'device_uid': deviceUid,
        'organization_id': orgId,
        'branch_id': branchId,
        'device_name': 'Light Winter POS Device',
        'platform': _platform,
        'active': true
      });
    } else {
      await _patch('lwr_devices', {
        'device_uid': 'eq.$deviceUid'
      }, {
        'organization_id': orgId,
        'branch_id': branchId,
        'platform': _platform,
        'active': true
      });
    }
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> recoverShop(String recoveryCode,
      String ownerUsername, String ownerPin, String deviceUid) async {
    final normalized =
        recoveryCode.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (normalized.isEmpty) {
      throw StateError('Enter the owner recovery code.');
    }
    final orgs = await _select('lwr_organizations',
        {'recovery_code': 'eq.$normalized', 'active': 'eq.true'});
    if (orgs.isEmpty) {
      throw StateError('Recovery code not found.');
    }
    final org = orgs.first;
    final users = await _select('lwr_users', {
      'organization_id': 'eq.${org['id']}',
      'username': 'eq.${ownerUsername.trim()}',
      'pin_plain': 'eq.${ownerPin.trim()}',
      'active': 'eq.true'
    });
    final owner = users.where((user) {
      final role = '${user['role']}'.toLowerCase();
      final permissions = user['permissions'] ?? [];
      return role == 'owner' || '${permissions}'.contains('all');
    }).firstOrNull;
    if (owner == null) {
      throw StateError('Owner username or PIN is incorrect.');
    }
    final branches = await _select('lwr_branches', {
      'organization_id': 'eq.${org['id']}',
      'active': 'eq.true',
      'order': 'created_at.asc',
      'limit': '1'
    });
    if (branches.isEmpty)
      throw StateError('No active branch found for recovery.');
    final branchId = branches.first['id'];
    final existing =
        await _select('lwr_devices', {'device_uid': 'eq.$deviceUid'});
    final deviceBody = {
      'organization_id': org['id'],
      'branch_id': branchId,
      'device_name': 'Recovered Light Winter POS Device',
      'platform': _platform,
      'active': true,
      'last_seen_at': DateTime.now().toUtc().toIso8601String()
    };
    if (existing.isEmpty) {
      await _insert('lwr_devices', {'device_uid': deviceUid, ...deviceBody});
    } else {
      await _patch('lwr_devices', {'device_uid': 'eq.$deviceUid'}, deviceBody);
    }
    await _insertOptional('lwr_audit_events', {
      'organization_id': org['id'],
      'branch_id': branchId,
      'device_uid': deviceUid,
      'actor_user_id': owner['id'],
      'action': 'device_recovery',
      'details': {'recovered_device_uid': deviceUid}
    });
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> resetOwnerAccess(String recoveryCode,
      String deviceUid, String resetVoucher, String newPin) async {
    final result = await _rpc('lwr_reset_owner_access', {
      'p_recovery_code': recoveryCode,
      'p_device_uid': deviceUid,
      'p_token': resetVoucher,
      'p_new_pin': newPin.trim().isEmpty ? null : newPin.trim(),
    });
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> bootstrap(String deviceUid) async {
    final allDevices = await _select(
        'lwr_devices', {'device_uid': 'eq.$deviceUid', 'limit': '1'});
    if (allDevices.isEmpty) {
      throw StateError('This device is not activated in Supabase yet.');
    }
    if (allDevices.first['active'] != true) {
      throw StateError(
          'This device has been deactivated. Contact Light Winter Technologies.');
    }
    final devices = allDevices;
    final device = devices.first;
    final orgId = device['organization_id'];
    final branchId = device['branch_id'];
    final org = (await _select('lwr_organizations', {'id': 'eq.$orgId'})).first;
    var recoveryCode = '${org['recovery_code'] ?? ''}';
    if (recoveryCode.trim().isEmpty) {
      recoveryCode = _activationCode().replaceAll('-', '');
      await _patchOptional('lwr_organizations', {'id': 'eq.$orgId'},
          {'recovery_code': recoveryCode});
    }
    final branches = await _select(
        'lwr_branches', {'organization_id': 'eq.$orgId', 'active': 'eq.true'});
    final users = await _select(
        'lwr_users', {'organization_id': 'eq.$orgId', 'active': 'eq.true'});
    final products = await _select(
        'lwr_products', {'organization_id': 'eq.$orgId', 'active': 'eq.true'});
    final productNameRows =
        await _selectOptional('lwr_products', {'organization_id': 'eq.$orgId'});
    final stock = <Map<String, dynamic>>[];
    for (final branch in branches) {
      stock.addAll(await _select(
          'lwr_branch_stock', {'branch_id': 'eq.${branch['id']}'}));
    }
    final customers =
        await _select('lwr_customers', {'organization_id': 'eq.$orgId'});
    List<Map<String, dynamic>>? suppliers;
    try {
      suppliers = await _select('lwr_suppliers',
          {'organization_id': 'eq.$orgId', 'active': 'eq.true'});
    } catch (_) {
      suppliers = null;
    }
    final activationCodes = await _select('lwr_activation_codes',
        {'organization_id': 'eq.$orgId', 'active': 'eq.true'});
    final licenses = await _select('lwr_licenses', {
      'device_uid': 'eq.$deviceUid',
      'status': 'eq.active',
      'order': 'expires_at.desc'
    });
    final serverNow = await _serverNow();
    final sales = await _selectAll('lwr_sales', {
      'organization_id': 'eq.$orgId',
      'order': 'created_at.desc',
    });
    final saleIds = sales.map((sale) => '${sale['id']}').toList();
    final saleLineRows = saleIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await _selectByIdsInChunks('lwr_sale_lines', 'sale_id', saleIds);
    final exchangeRows = await _selectOptional(
        'lwr_exchange_rates', {'organization_id': 'eq.$orgId'});
    final transferRows = await _selectOptional('lwr_stock_transfers', {
      'organization_id': 'eq.$orgId',
      'order': 'created_at.desc',
      'limit': '100'
    });
    final voidRows = await _selectAllOptional('lwr_sale_voids', {
      'organization_id': 'eq.$orgId',
      'order': 'created_at.desc',
    });
    final voidIds = voidRows.map((row) => '${row['id']}').toList();
    final voidLineRows = voidIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await _selectByIdsInChunks('lwr_sale_void_lines', 'void_id', voidIds);
    final accountingRows = await _selectAllOptional('lwr_accounting_entries', {
      'organization_id': 'eq.$orgId',
      'active': 'eq.true',
      'order': 'created_at.desc',
    });
    final fiscalDays = await _selectOptional('lwr_fiscal_days', {
      'organization_id': 'eq.$orgId',
      'branch_id': 'eq.$branchId',
      'order': 'opened_at.desc',
      'limit': '1'
    });
    final branchNames = {
      for (final branch in branches) '${branch['id']}': '${branch['name']}'
    };
    final userNames = {
      for (final user in users) '${user['id']}': '${user['name']}'
    };
    final customerNames = {
      for (final customer in customers)
        '${customer['id']}': '${customer['name']}'
    };
    final productNames = {
      for (final product in productNameRows)
        '${product['id']}': '${product['name']}',
      for (final product in products) '${product['id']}': '${product['name']}',
    };
    String productNameForLine(Map<String, dynamic> line) {
      final explicit = '${line['name'] ?? line['product_name'] ?? ''}'.trim();
      if (explicit.isNotEmpty && explicit.toLowerCase() != 'null') {
        return explicit;
      }
      final productId = '${line['product_id'] ?? ''}';
      return productNames[productId] ?? 'Unknown product';
    }

    final linesBySale = <String, List<Map<String, dynamic>>>{};
    for (final line in saleLineRows) {
      final saleId = '${line['sale_id']}';
      final lineName = productNameForLine(line);
      linesBySale.putIfAbsent(saleId, () => []).add({
        'productId': '${line['product_id'] ?? ''}',
        'name': lineName,
        'quantity': line['quantity'] ?? 0,
        'unitPriceCents': line['unit_price_cents'] ?? 0,
        'lineTotalCents': line['line_total_cents'] ?? 0,
        'unitCostCents': line['unit_cost_cents'] ?? 0,
        'lineCostCents': line['line_cost_cents'] ?? 0,
      });
    }
    final linesByVoid = <String, List<Map<String, dynamic>>>{};
    for (final line in voidLineRows) {
      final voidId = '${line['void_id']}';
      final lineName = productNameForLine(line);
      linesByVoid.putIfAbsent(voidId, () => []).add({
        'productId': '${line['product_id'] ?? ''}',
        'name': lineName,
        'quantity': line['quantity'] ?? 0,
        'unitPriceCents': line['unit_price_cents'] ?? 0,
        'lineTotalCents': line['line_total_cents'] ?? 0,
        'unitCostCents': line['unit_cost_cents'] ?? 0,
        'lineCostCents': line['line_cost_cents'] ?? 0,
      });
    }
    final licenseLabel = licenses.isEmpty ? 'Not licensed' : 'Licensed';
    return {
      'organization_id': orgId,
      'shop_name': org['name'],
      'shop_phone': org['phone'] ?? '',
      'shop_address': org['address'] ?? '',
      'recovery_code': recoveryCode,
      'fiscal_mode': (org['fiscal_mode'] == true) ? 'fiscal' : 'non_fiscal',
      'registered_name': org['registered_name'] ?? '',
      'tin': org['tin'] ?? '',
      'vat_number': org['vat_number'] ?? '',
      'zimra_device_id': org['zimra_device_id'] ?? '',
      'fiscal_serial_number': org['fiscal_serial_number'] ?? '',
      'fiscal_qr_url': org['fiscal_qr_url'] ?? '',
      'fiscal_day_no': fiscalDays.isEmpty ? 0 : fiscalDays.first['day_no'] ?? 0,
      'fiscal_day_open':
          fiscalDays.isNotEmpty && fiscalDays.first['status'] == 'open',
      'fiscal_day_opened_at':
          fiscalDays.isEmpty ? null : fiscalDays.first['opened_at'],
      'device_id': device['id']?.toString() ?? deviceUid,
      'device_active': device['active'] == true,
      'device_lock_message': '',
      'device_uid': deviceUid,
      'assigned_branch_id': branchId,
      'license_label': licenseLabel,
      'license_expires_at':
          licenses.isEmpty ? null : licenses.first['expires_at'],
      'server_now': serverNow.toIso8601String(),
      'branches': branches
          .map((b) => {
                'id': b['id'],
                'name': b['name'],
                'phone': b['phone'] ?? '',
                'address': b['address'] ?? ''
              })
          .toList(),
      'users': users
          .map((u) => {
                'id': u['id'],
                'name': u['name'],
                'username': u['username'],
                'role': u['role'],
                'pin': u['pin_plain'],
                'permissions': u['permissions'] ?? []
              })
          .toList(),
      'products': products
          .map((p) => {
                'id': p['id'],
                'name': p['name'],
                'sku': p['sku'],
                'barcode': p['barcode'] ?? '',
                'category': p['category'] ?? '',
                'price_cents': p['price_cents'],
                'cost_price_cents': p['cost_price_cents'] ?? 0,
                'reorder_level': p['reorder_level'],
                'supplier_id': p['supplier_id'] ?? ''
              })
          .toList(),
      'stock': stock
          .map((s) => {
                'branch_id': s['branch_id'],
                'product_id': s['product_id'],
                'quantity': s['quantity']
              })
          .toList(),
      'customers': customers
          .map((c) =>
              {'id': c['id'], 'name': c['name'], 'phone': c['phone'] ?? ''})
          .toList(),
      if (suppliers != null)
        'suppliers': suppliers
            .map((s) => {
                  'id': s['id'],
                  'name': s['name'],
                  'phone': s['phone'] ?? '',
                  'notes': s['notes'] ?? ''
                })
            .toList(),
      'sales': sales
          .map((s) => {
                'id': s['id'],
                'branch_id': s['branch_id'] ?? '',
                'total_cents': s['total_cents'],
                'discount_cents': s['discount_cents'] ?? 0,
                'paid_cents': s['paid_cents'] ?? 0,
                'change_cents': s['change_cents'] ?? 0,
                'debt_cents': s['debt_cents'] ?? 0,
                'payment_method': s['payment_method'],
                'cashier_name':
                    userNames['${s['cashier_user_id']}'] ?? 'Synced user',
                'customer_name': s['customer_id'] == null
                    ? ''
                    : customerNames['${s['customer_id']}'] ?? '',
                'lines': linesBySale['${s['id']}'] ?? [],
                'created_at': s['created_at']
              })
          .toList(),
      'exchange_rates': {
        for (final row in exchangeRows)
          if (row['currency_code'] != null)
            '${row['currency_code']}': row['rate']
      },
      'display_currency': exchangeRows.isEmpty
          ? null
          : exchangeRows
                  .where((row) => row['is_default'] == true)
                  .firstOrNull?['currency_code'] ??
              'USD',
      'stock_transfers': transferRows
          .map((row) => {
                ...row,
                'from_branch_name':
                    branchNames['${row['from_branch_id']}'] ?? 'Source branch',
                'to_branch_name':
                    branchNames['${row['to_branch_id']}'] ?? 'Target branch',
              })
          .toList(),
      'sale_voids': voidRows
          .map((row) => {
                ...row,
                'lines': linesByVoid['${row['id']}'] ?? [],
                'user_name': userNames['${row['user_id']}'] ??
                    row['user_name'] ??
                    'User',
              })
          .toList(),
      'accounting_entries': accountingRows,
      'activation_codes': activationCodes
          .map((c) => {'branch_id': c['branch_id'], 'code': c['code']})
          .toList(),
    };
  }

  Future<Map<String, dynamic>> applyLicense(
      String deviceUid, String token) async {
    final normalized = token.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    await _rpc('lwr_activate_device_license', {
      'p_device_uid': deviceUid,
      'p_token': normalized,
      'p_platform': _platform,
    });
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> loadBranchView(
      String deviceUid, String branchId) async {
    final devices = await _select(
        'lwr_devices', {'device_uid': 'eq.$deviceUid', 'active': 'eq.true'});
    if (devices.isEmpty)
      throw StateError('This device is not activated in Supabase yet.');
    final device = devices.first;
    final orgId = device['organization_id'];
    final branch = await _select('lwr_branches', {
      'id': 'eq.$branchId',
      'organization_id': 'eq.$orgId',
      'active': 'eq.true'
    });
    if (branch.isEmpty)
      throw StateError('Branch does not belong to this shop.');
    await _patch('lwr_devices', {
      'device_uid': 'eq.$deviceUid'
    }, {
      'branch_id': branchId,
      'last_seen_at': DateTime.now().toUtc().toIso8601String()
    });
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> createUser(
      String orgId, String deviceUid, AppUser user) async {
    await _insert('lwr_users', _userRow(orgId, user));
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> updateCompany(
      String orgId, String deviceUid, Company company) async {
    await _patchOptional('lwr_organizations', {
      'id': 'eq.$orgId'
    }, {
      'name': company.shopName,
      'phone': company.phone,
      'address': company.address,
      'fiscal_mode': company.fiscalMode,
      'registered_name': company.registeredName,
      'tin': company.tin,
      'vat_number': company.vatNumber,
      'zimra_device_id': company.zimraDeviceId,
      'fiscal_serial_number': company.fiscalSerialNumber,
      'fiscal_qr_url': company.fiscalQrUrl,
    });
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> updateUser(
      String userId, String deviceUid, AppUser user) async {
    await _patch('lwr_users', {
      'id': 'eq.$userId'
    }, {
      'name': user.name,
      'username': user.username,
      'role': roleApiValue(user.role),
      'pin_plain': user.pin,
      'permissions': user.cloudPermissions,
      'active': true
    });
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> deleteUser(
      String userId, String deviceUid) async {
    await _patch('lwr_users', {'id': 'eq.$userId'}, {'active': false});
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> createBranch(
      String orgId, String deviceUid, BranchDraft branch) async {
    var branchId = newId();
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _insert('lwr_branches', {
          'id': branchId,
          'organization_id': orgId,
          'name': branch.name,
          'phone': branch.phone,
          'address': branch.address,
          'active': true
        });
        break;
      } catch (error) {
        if (attempt == 1 || !isDuplicateKeyError(error)) rethrow;
        branchId = newId();
      }
    }
    await _insert('lwr_activation_codes', {
      'code': _activationCode(),
      'organization_id': orgId,
      'branch_id': branchId,
      'active': true
    });
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> updateBranch(
      String branchId, String deviceUid, BranchDraft branch) async {
    await _patch('lwr_branches', {
      'id': 'eq.$branchId'
    }, {
      'name': branch.name,
      'phone': branch.phone,
      'address': branch.address,
      'active': true
    });
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> deleteBranch(
      String branchId, String deviceUid) async {
    await _patch('lwr_branches', {'id': 'eq.$branchId'}, {'active': false});
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> assignDeviceToBranch(
      String deviceUid, String branchId) async {
    final devices = await _select(
        'lwr_devices', {'device_uid': 'eq.$deviceUid', 'active': 'eq.true'});
    if (devices.isEmpty) throw StateError('Device not activated.');
    final orgId = devices.first['organization_id'];
    final branch = await _select('lwr_branches', {
      'id': 'eq.$branchId',
      'organization_id': 'eq.$orgId',
      'active': 'eq.true'
    });
    if (branch.isEmpty)
      throw StateError('Branch does not belong to this shop.');
    await _patch('lwr_devices', {
      'device_uid': 'eq.$deviceUid'
    }, {
      'branch_id': branchId,
      'last_seen_at': DateTime.now().toUtc().toIso8601String()
    });
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> transferStock(String deviceUid,
      String fromBranchId, String toBranchId, String productId, int qty,
      {String productName = '', String userName = ''}) async {
    if (qty <= 0)
      throw StateError('Transfer quantity must be greater than zero.');
    final devices = await _select(
        'lwr_devices', {'device_uid': 'eq.$deviceUid', 'active': 'eq.true'});
    if (devices.isEmpty) throw StateError('Device not activated.');
    final orgId = devices.first['organization_id'];
    final branches = await _select(
        'lwr_branches', {'organization_id': 'eq.$orgId', 'active': 'eq.true'});
    final branchIds = branches.map((branch) => '${branch['id']}').toSet();
    if (!branchIds.contains(fromBranchId) || !branchIds.contains(toBranchId)) {
      throw StateError('Both branches must belong to this shop.');
    }
    await _rpcAdjustStock(fromBranchId, productId, -qty);
    await _rpcAdjustStock(toBranchId, productId, qty);
    await _insertOptional('lwr_stock_transfers', {
      'id': newId(),
      'organization_id': orgId,
      'product_id': productId,
      'product_name': productName,
      'from_branch_id': fromBranchId,
      'to_branch_id': toBranchId,
      'quantity': qty,
      'device_uid': deviceUid,
      'user_name': userName
    });
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> updateExchangeRates(
      String orgId,
      String deviceUid,
      Map<String, double> rates,
      String displayCurrency) async {
    for (final entry in rates.entries) {
      final existing = await _selectOptional('lwr_exchange_rates',
          {'organization_id': 'eq.$orgId', 'currency_code': 'eq.${entry.key}'});
      final body = {
        'organization_id': orgId,
        'currency_code': entry.key,
        'rate': entry.value,
        'is_default': entry.key == displayCurrency,
        'updated_by_device_uid': deviceUid,
        'updated_at': DateTime.now().toUtc().toIso8601String()
      };
      if (existing.isEmpty) {
        await _insertOptional('lwr_exchange_rates', body);
      } else {
        await _patchOptional(
            'lwr_exchange_rates',
            {
              'organization_id': 'eq.$orgId',
              'currency_code': 'eq.${entry.key}'
            },
            body);
      }
    }
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> openFiscalDay(
      String deviceUid, String? userId, int dayNo) async {
    final devices = await _select(
        'lwr_devices', {'device_uid': 'eq.$deviceUid', 'active': 'eq.true'});
    if (devices.isEmpty) throw StateError('Device not activated.');
    final device = devices.first;
    final existingOpen = await _selectOptional('lwr_fiscal_days', {
      'organization_id': 'eq.${device['organization_id']}',
      'branch_id': 'eq.${device['branch_id']}',
      'status': 'eq.open'
    });
    if (existingOpen.isEmpty) {
      await _insertOptional('lwr_fiscal_days', {
        'id': newId(),
        'organization_id': device['organization_id'],
        'branch_id': device['branch_id'],
        'device_uid': deviceUid,
        'day_no': dayNo,
        'status': 'open',
        'opened_by_user_id': userId,
        'opened_at': DateTime.now().toUtc().toIso8601String()
      });
    }
    await _insertOptional('lwr_audit_events', {
      'organization_id': device['organization_id'],
      'branch_id': device['branch_id'],
      'device_uid': deviceUid,
      'actor_user_id': userId,
      'action': 'fiscal_day_open',
      'details': {'day_no': dayNo}
    });
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> closeFiscalDay(
      String deviceUid, String? userId, int dayNo) async {
    final devices = await _select(
        'lwr_devices', {'device_uid': 'eq.$deviceUid', 'active': 'eq.true'});
    if (devices.isEmpty) throw StateError('Device not activated.');
    final device = devices.first;
    final openDays = await _selectOptional('lwr_fiscal_days', {
      'organization_id': 'eq.${device['organization_id']}',
      'branch_id': 'eq.${device['branch_id']}',
      'status': 'eq.open',
      'order': 'opened_at.desc',
      'limit': '1'
    });
    if (openDays.isNotEmpty) {
      await _patchOptional('lwr_fiscal_days', {
        'id': 'eq.${openDays.first['id']}'
      }, {
        'status': 'closed',
        'closed_by_user_id': userId,
        'closed_at': DateTime.now().toUtc().toIso8601String()
      });
    }
    await _insertOptional('lwr_audit_events', {
      'organization_id': device['organization_id'],
      'branch_id': device['branch_id'],
      'device_uid': deviceUid,
      'actor_user_id': userId,
      'action': 'fiscal_day_close',
      'details': {'day_no': dayNo}
    });
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> createProduct(
      String orgId, String branchId, String deviceUid, Product product) async {
    final existing = await _findExistingProductById(orgId, product.id);
    if (existing != null) {
      product.id = '${existing['id']}';
      return updateProduct(deviceUid, branchId, product);
    }
    await _insert('lwr_products', {
      'id': product.id,
      'organization_id': orgId,
      'name': product.name,
      'category': product.category,
      'sku': product.sku,
      'barcode': product.barcode,
      'price_cents': product.priceCents,
      'cost_price_cents': product.costCents,
      'reorder_level': product.reorderLevel,
      'supplier_id':
          product.supplierId.trim().isEmpty ? null : product.supplierId,
      'active': true
    }).catchError((_) => _insert('lwr_products', {
          'id': product.id,
          'organization_id': orgId,
          'name': product.name,
          'sku': product.sku,
          'barcode': product.barcode,
          'price_cents': product.priceCents,
          'reorder_level': product.reorderLevel,
          'active': true
        }));
    await _upsertBranchStock(branchId, product.id, product.stock);
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> upsertProduct(
      String orgId, String branchId, String deviceUid, Product product) async {
    final existing = await _findExistingProductById(orgId, product.id);
    if (existing == null) {
      return createProduct(orgId, branchId, deviceUid, product);
    }
    product.id = '${existing['id']}';
    return updateProduct(deviceUid, branchId, product);
  }

  Future<Map<String, dynamic>> upsertProducts(String orgId, String branchId,
      String deviceUid, List<Product> products) async {
    if (products.isEmpty) return <String, dynamic>{};
    final existingRows =
        await _selectOptional('lwr_products', {'organization_id': 'eq.$orgId'});
    final byId = <String, Map<String, dynamic>>{};
    for (final row in existingRows) {
      final id = '${row['id'] ?? ''}';
      if (id.isNotEmpty) byId[id] = row;
    }
    for (final product in products) {
      final existing = byId[product.id];
      if (existing == null) {
        await _insertProductRow(orgId, product);
        byId[product.id] = {
          'id': product.id,
          'sku': product.sku,
          'name': product.name
        };
      } else {
        product.id = '${existing['id']}';
        await _patchProductRow(product);
      }
      await _upsertBranchStock(branchId, product.id, product.stock);
    }
    return <String, dynamic>{};
  }

  Future<void> _insertProductRow(String orgId, Product product) async {
    await _insert('lwr_products', {
      'id': product.id,
      'organization_id': orgId,
      'name': product.name,
      'category': product.category,
      'sku': product.sku,
      'barcode': product.barcode,
      'price_cents': product.priceCents,
      'cost_price_cents': product.costCents,
      'reorder_level': product.reorderLevel,
      'supplier_id':
          product.supplierId.trim().isEmpty ? null : product.supplierId,
      'active': true
    }).catchError((_) => _insert('lwr_products', {
          'id': product.id,
          'organization_id': orgId,
          'name': product.name,
          'sku': product.sku,
          'barcode': product.barcode,
          'price_cents': product.priceCents,
          'reorder_level': product.reorderLevel,
          'active': true
        }));
  }

  Future<void> _patchProductRow(Product product) async {
    await _patch('lwr_products', {
      'id': 'eq.${product.id}'
    }, {
      'name': product.name,
      'category': product.category,
      'sku': product.sku,
      'barcode': product.barcode,
      'price_cents': product.priceCents,
      'cost_price_cents': product.costCents,
      'reorder_level': product.reorderLevel,
      'supplier_id':
          product.supplierId.trim().isEmpty ? null : product.supplierId,
      'active': true
    }).catchError((_) => _patch('lwr_products', {
          'id': 'eq.${product.id}'
        }, {
          'name': product.name,
          'sku': product.sku,
          'barcode': product.barcode,
          'price_cents': product.priceCents,
          'reorder_level': product.reorderLevel,
          'active': true
        }));
  }

  Future<Map<String, dynamic>?> _findExistingProductById(
      String orgId, String productId) async {
    final byId = await _selectOptional('lwr_products',
        {'organization_id': 'eq.$orgId', 'id': 'eq.$productId', 'limit': '1'});
    if (byId.isNotEmpty) return byId.first;
    return null;
  }

  Future<Map<String, dynamic>> updateProduct(
      String deviceUid, String branchId, Product product) async {
    await _patch('lwr_products', {
      'id': 'eq.${product.id}'
    }, {
      'name': product.name,
      'category': product.category,
      'sku': product.sku,
      'barcode': product.barcode,
      'price_cents': product.priceCents,
      'cost_price_cents': product.costCents,
      'reorder_level': product.reorderLevel,
      'supplier_id':
          product.supplierId.trim().isEmpty ? null : product.supplierId,
      'active': true
    }).catchError((_) => _patch('lwr_products', {
          'id': 'eq.${product.id}'
        }, {
          'name': product.name,
          'sku': product.sku,
          'barcode': product.barcode,
          'price_cents': product.priceCents,
          'reorder_level': product.reorderLevel,
          'active': true
        }));
    await _upsertBranchStock(branchId, product.id, product.stock);
    return <String, dynamic>{};
  }

  Future<void> _upsertBranchStock(
      String branchId, String productId, int quantity) async {
    final existing = await _selectOptional('lwr_branch_stock',
        {'branch_id': 'eq.$branchId', 'product_id': 'eq.$productId'});
    final row = {
      'branch_id': branchId,
      'product_id': productId,
      'quantity': quantity,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (existing.isEmpty) {
      await _insert('lwr_branch_stock', row);
    } else {
      await _patch('lwr_branch_stock',
          {'branch_id': 'eq.$branchId', 'product_id': 'eq.$productId'}, row);
    }
  }

  Future<Map<String, dynamic>> upsertSupplier(
      String orgId, String deviceUid, Supplier supplier,
      {bool refresh = true}) async {
    final row = {
      'id': supplier.id,
      'organization_id': orgId,
      'name': supplier.name,
      'phone': supplier.phone,
      'notes': supplier.notes,
      'active': true,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    final existing =
        await _selectOptional('lwr_suppliers', {'id': 'eq.${supplier.id}'});
    if (existing.isEmpty) {
      await _insert('lwr_suppliers', row);
    } else {
      await _patch('lwr_suppliers', {'id': 'eq.${supplier.id}'}, row);
    }
    return refresh ? bootstrap(deviceUid) : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> deleteSupplier(
      String deviceUid, String supplierId) async {
    await _patchOptional('lwr_suppliers', {
      'id': 'eq.$supplierId'
    }, {
      'active': false,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> deleteProduct(
      String deviceUid, String productId) async {
    await _deleteRows('lwr_branch_stock', {'product_id': 'eq.$productId'});
    await _patch('lwr_products', {'id': 'eq.$productId'}, {'active': false});
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> createCustomer(
      String orgId, String deviceUid, Customer customer) async {
    final existing = await _select('lwr_customers',
        {'organization_id': 'eq.$orgId', 'name': 'eq.${customer.name}'});
    if (existing.isEmpty) {
      await _insert('lwr_customers', {
        'id': customer.id,
        'organization_id': orgId,
        'name': customer.name,
        'phone': customer.phone
      });
    }
    return bootstrap(deviceUid);
  }

  Future<Map<String, dynamic>> adjustStock(
      String deviceUid, String branchId, String productId, int delta) async {
    await _rpcAdjustStock(branchId, productId, delta);
    return bootstrap(deviceUid);
  }

  Future<void> createSale(
      String deviceUid,
      String? cashierId,
      String? customerId,
      String paymentMethod,
      List<CartItem> lines,
      int totalCents,
      {String? saleId,
      int discountCents = 0,
      int paidCents = 0,
      int changeCents = 0,
      int debtCents = 0}) async {
    final devices = await _select(
        'lwr_devices', {'device_uid': 'eq.$deviceUid', 'active': 'eq.true'});
    if (devices.isEmpty) throw StateError('Device not activated.');
    final device = devices.first;
    final orgRows = await _select(
        'lwr_organizations', {'id': 'eq.${device['organization_id']}'});
    final fiscalMode =
        orgRows.isNotEmpty && orgRows.first['fiscal_mode'] == true;
    final actualSaleId = saleId ?? newId();
    final existingSale =
        await _selectOptional('lwr_sales', {'id': 'eq.$actualSaleId'});
    if (existingSale.isNotEmpty) return;
    await _insert('lwr_sales', {
      'id': actualSaleId,
      'organization_id': device['organization_id'],
      'branch_id': device['branch_id'],
      'device_uid': deviceUid,
      'cashier_user_id': cashierId,
      'customer_id': customerId,
      'payment_method': paymentMethod.toLowerCase(),
      'total_cents': totalCents,
      'discount_cents': discountCents,
      'paid_cents': paidCents,
      'change_cents': changeCents,
      'debt_cents': debtCents,
      'fiscal_status': fiscalMode ? 'pending' : 'not_required'
    });
    for (final item in lines) {
      if (item.product.isCustom) {
        await _insertOptional('lwr_products', {
          'id': item.product.id,
          'organization_id': device['organization_id'],
          'name': item.product.name,
          'category': item.product.category,
          'sku': '',
          'barcode': '',
          'price_cents': item.product.priceCents,
          'cost_price_cents': item.product.costCents,
          'reorder_level': 0,
          'active': false
        });
      }
      final saleLineBody = {
        'id': newId(),
        'sale_id': actualSaleId,
        'product_id': item.product.id,
        'product_name': item.product.name,
        'quantity': item.quantity,
        'unit_price_cents': item.product.priceCents,
        'line_total_cents': item.product.priceCents * item.quantity,
        'unit_cost_cents': item.product.costCents,
        'line_cost_cents': item.product.costCents * item.quantity,
      };
      try {
        await _insert('lwr_sale_lines', saleLineBody);
      } catch (_) {
        await _insert(
            'lwr_sale_lines',
            {
              ...saleLineBody,
            }..removeWhere((key, value) =>
                key == 'unit_cost_cents' ||
                key == 'line_cost_cents' ||
                key == 'product_name'));
      }
      if (!item.product.isCustom) {
        await _rpcAdjustStock(
            device['branch_id'], item.product.id, -item.quantity);
      }
    }
    if (fiscalMode) {
      await _insertOptional('lwr_fiscal_submissions', {
        'id': newId(),
        'organization_id': device['organization_id'],
        'branch_id': device['branch_id'],
        'sale_id': actualSaleId,
        'submission_type': 'fiscal_invoice',
        'status': 'pending',
        'attempt_count': 0,
        'last_error': '',
        'created_at': DateTime.now().toUtc().toIso8601String()
      });
    }
  }

  Future<void> updateSaleDebt(
      String deviceUid, String saleId, int paidCents, int debtCents) async {
    final devices = await _select(
        'lwr_devices', {'device_uid': 'eq.$deviceUid', 'active': 'eq.true'});
    if (devices.isEmpty) throw StateError('Device not activated.');
    await _patch('lwr_sales', {
      'id': 'eq.$saleId'
    }, {
      'paid_cents': paidCents,
      'debt_cents': debtCents,
    });
  }

  Future<Map<String, dynamic>> voidSale(
      String deviceUid, String? userId, SaleVoidRecord record) async {
    final devices = await _select(
        'lwr_devices', {'device_uid': 'eq.$deviceUid', 'active': 'eq.true'});
    if (devices.isEmpty) throw StateError('Device not activated.');
    final device = devices.first;
    await _insertOptional('lwr_sale_voids', {
      'id': record.id,
      'organization_id': device['organization_id'],
      'branch_id':
          record.branchId.isEmpty ? device['branch_id'] : record.branchId,
      'sale_id': record.saleId,
      'device_uid': deviceUid,
      'user_id': userId,
      'user_name': record.userName,
      'void_type': record.type,
      'reason': record.reason,
      'total_cents': record.totalCents,
      'created_at': record.createdAt.toUtc().toIso8601String()
    });
    for (final line in record.lines) {
      if (line.productId.trim().isEmpty) continue;
      final voidLineBody = {
        'id': newId(),
        'void_id': record.id,
        'product_id': line.productId,
        'product_name': line.name,
        'quantity': line.quantity,
        'unit_price_cents': line.unitPriceCents,
        'line_total_cents': line.lineTotalCents,
        'unit_cost_cents': line.unitCostCents,
        'line_cost_cents': line.lineCostCents,
      };
      try {
        await _insert('lwr_sale_void_lines', voidLineBody);
      } catch (_) {
        await _insertOptional(
            'lwr_sale_void_lines',
            {
              ...voidLineBody,
            }..removeWhere((key, value) =>
                key == 'unit_cost_cents' ||
                key == 'line_cost_cents' ||
                key == 'product_name'));
      }
      await _rpcAdjustStock(
          record.branchId.isEmpty ? device['branch_id'] : record.branchId,
          line.productId,
          line.quantity);
    }
    await _insertOptional('lwr_audit_events', {
      'organization_id': device['organization_id'],
      'branch_id':
          record.branchId.isEmpty ? device['branch_id'] : record.branchId,
      'device_uid': deviceUid,
      'actor_user_id': userId,
      'action': record.type,
      'details': {
        'sale_id': record.saleId,
        'reason': record.reason,
        'total_cents': record.totalCents,
        'lines': record.lines.map((line) => line.toJson()).toList(),
      }
    });
    return bootstrap(deviceUid);
  }

  Future<void> createAccountingEntry(String orgId, String branchId,
      String deviceUid, AccountingEntry entry) async {
    await _insertOptional('lwr_accounting_entries', {
      'id': entry.id,
      'organization_id': orgId,
      'branch_id': branchId.trim().isEmpty ? null : branchId,
      'device_uid': deviceUid,
      'type': entry.typeText,
      'category': entry.category,
      'description': entry.description,
      'amount_cents': entry.amountCents,
      'payment_method': entry.paymentMethod,
      'counterparty': entry.counterparty,
      'active': true,
      'created_at': entry.createdAt.toUtc().toIso8601String(),
    });
  }

  Future<void> deleteAccountingEntry(String deviceUid, String entryId) async {
    await _patchOptional('lwr_accounting_entries', {
      'id': 'eq.$entryId'
    }, {
      'active': false,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> deleteSales(String deviceUid, List<String> saleIds) async {
    await _deleteIdsInChunks('lwr_sales', saleIds);
  }

  Future<void> deleteCustomers(
      String deviceUid, List<String> customerIds) async {
    await _deleteIdsInChunks('lwr_customers', customerIds);
  }

  Future<void> deleteStockTransfers(
      String deviceUid, List<String> transferIds) async {
    await _deleteIdsInChunks('lwr_stock_transfers', transferIds);
  }

  Future<void> deleteSaleVoids(String deviceUid, List<String> voidIds) async {
    await _deleteIdsInChunks('lwr_sale_voids', voidIds);
  }

  Map<String, dynamic> _userRow(String orgId, AppUser user) => {
        'id': user.id ?? newId(),
        'organization_id': orgId,
        'name': user.name,
        'username': user.username,
        'role': roleApiValue(user.role),
        'pin_plain': user.pin.isEmpty ? '0000' : user.pin,
        'permissions': user.cloudPermissions,
        'active': true
      };
  Map<String, dynamic> _branchRow(BranchProfile branch) => {
        'id': branch.id,
        'name': branch.name,
        'phone': branch.phone,
        'address': branch.address
      };

  Future<void> _rpcAdjustStock(
      String branchId, String productId, int delta) async {
    final current = await _select('lwr_branch_stock',
        {'branch_id': 'eq.$branchId', 'product_id': 'eq.$productId'});
    if (current.isEmpty) {
      await _insert('lwr_branch_stock',
          {'branch_id': branchId, 'product_id': productId, 'quantity': delta});
      return;
    }
    final quantity = (current.first['quantity'] as int) + delta;
    await _patch(
        'lwr_branch_stock',
        {'branch_id': 'eq.$branchId', 'product_id': 'eq.$productId'},
        {'quantity': quantity});
  }

  Future<List<Map<String, dynamic>>> _select(
      String table, Map<String, String> query) async {
    final uri = Uri.parse('$restUrl/$table')
        .replace(queryParameters: {'select': '*', ...query});
    final response =
        await http.get(uri, headers: _headers).timeout(requestTimeout);
    return _list(response);
  }

  Future<List<Map<String, dynamic>>> _selectOptional(
      String table, Map<String, String> query) async {
    try {
      return await _select(table, query);
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _selectAll(
      String table, Map<String, String> query,
      {int pageSize = 1000}) async {
    final rows = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final page = await _select(table, {
        ...query,
        'limit': '$pageSize',
        'offset': '$offset',
      });
      rows.addAll(page);
      if (page.length < pageSize) break;
      offset += pageSize;
    }
    return rows;
  }

  Future<List<Map<String, dynamic>>> _selectAllOptional(
      String table, Map<String, String> query,
      {int pageSize = 1000}) async {
    try {
      return await _selectAll(table, query, pageSize: pageSize);
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _selectByIdsInChunks(
      String table, String column, List<String> ids,
      {Map<String, String> query = const {}, int chunkSize = 80}) async {
    final rows = <Map<String, dynamic>>[];
    for (var start = 0; start < ids.length; start += chunkSize) {
      final chunk = ids.skip(start).take(chunkSize).toList();
      rows.addAll(await _selectOptional(table, {
        ...query,
        column: 'in.(${chunk.join(',')})',
      }));
    }
    return rows;
  }

  Future<Map<String, dynamic>> _insert(
      String table, Map<String, dynamic> body) async {
    final response = await http
        .post(Uri.parse('$restUrl/$table'),
            headers: _headers, body: jsonEncode(body))
        .timeout(requestTimeout);
    return _one(response);
  }

  Future<void> _insertOptional(String table, Map<String, dynamic> body) async {
    try {
      await _insert(table, body);
    } catch (_) {}
  }

  Future<void> _patch(String table, Map<String, String> query,
      Map<String, dynamic> body) async {
    final uri = Uri.parse('$restUrl/$table').replace(queryParameters: query);
    final response = await http
        .patch(uri, headers: _headers, body: jsonEncode(body))
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw StateError('${response.statusCode}: ${response.body}');
  }

  Future<void> _patchOptional(String table, Map<String, String> query,
      Map<String, dynamic> body) async {
    try {
      await _patch(table, query, body);
    } catch (_) {}
  }

  Future<void> _deleteRows(String table, Map<String, String> query) async {
    final uri = Uri.parse('$restUrl/$table').replace(queryParameters: query);
    final response =
        await http.delete(uri, headers: _headers).timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('${response.statusCode}: ${response.body}');
    }
  }

  Future<void> _deleteIdsInChunks(String table, List<String> ids,
      {int chunkSize = 80}) async {
    final cleanIds =
        ids.map((id) => id.trim()).where((id) => id.isNotEmpty).toList();
    for (var start = 0; start < cleanIds.length; start += chunkSize) {
      final chunk = cleanIds.skip(start).take(chunkSize).toList();
      await _deleteRows(table, {'id': 'in.(${chunk.join(',')})'});
    }
  }

  Future<dynamic> _rpc(String functionName, Map<String, dynamic> body) async {
    final response = await http
        .post(Uri.parse('$restUrl/rpc/$functionName'),
            headers: _headers, body: jsonEncode(body))
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw StateError(_supabaseError(response));
    return response.body.trim().isEmpty ? null : jsonDecode(response.body);
  }

  Future<DateTime> _serverNow() async {
    try {
      final value = await _rpc('lwr_server_now', {});
      final parsed = DateTime.tryParse('$value')?.toUtc();
      if (parsed != null) return parsed;
    } catch (_) {}
    return DateTime.now().toUtc();
  }

  String _supabaseError(http.Response response) {
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return 'Supabase ${response.statusCode}: ${data['message'] ?? response.body}';
    } catch (_) {
      return 'Supabase ${response.statusCode}: ${response.body}';
    }
  }

  List<Map<String, dynamic>> _list(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw StateError('${response.statusCode}: ${response.body}');
    return (jsonDecode(response.body) as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  Map<String, dynamic> _one(http.Response response) {
    final items = _list(response);
    return items.isEmpty ? <String, dynamic>{} : items.first;
  }

  String _activationCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(10, (_) => chars[random.nextInt(chars.length)]).join();
  }

  static String _projectUrl(String value) {
    var normalized = value.trim().replaceAll(RegExp(r'/$'), '');
    if (normalized.endsWith('/rest/v1')) {
      normalized =
          normalized.substring(0, normalized.length - '/rest/v1'.length);
    }
    return normalized;
  }
}

extension FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

String newId() {
  final timePart = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final randomPart = Random.secure().nextInt(0x7fffffff).toRadixString(36);
  return '${timePart}_$randomPart';
}

bool isDuplicateKeyError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('409') ||
      message.contains('duplicate') ||
      message.contains('unique constraint');
}

String _newDeviceUid() => 'LWR-${Random.secure().nextInt(900000) + 100000}';
String money(int cents) => '\$${(cents / 100).toStringAsFixed(2)}';

extension ListFallback<T> on List<T> {
  List<T> ifEmpty(List<T> fallback) => isEmpty ? [...fallback] : this;
}

List<T> mergeById<T>(
    List<T> localItems, List<T> cloudItems, String Function(T item) idOf) {
  final merged = <String, T>{};
  for (final item in localItems) {
    final id = idOf(item);
    if (id.trim().isNotEmpty) merged[id] = item;
  }
  for (final item in cloudItems) {
    final id = idOf(item);
    if (id.trim().isNotEmpty) merged[id] = item;
  }
  return merged.values.toList();
}

String localDateKey(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}

DateTime businessTime(DateTime value) =>
    value.toUtc().add(const Duration(hours: 2));

DateTime businessDate(DateTime value) {
  final business = businessTime(value);
  return DateTime(business.year, business.month, business.day);
}

bool sameBusinessDay(DateTime a, DateTime b) =>
    businessDate(a) == businessDate(b);

String formatReceiptDate(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String shortDate(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}

String shortDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

bool sameLocalDay(DateTime a, DateTime b) {
  final left = a.toLocal();
  final right = b.toLocal();
  return left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

String normalizeWhatsAppNumber(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw StateError('Enter the customer WhatsApp number with country code.');
  }
  if (!RegExp(r'^\+?[0-9 ()-]+$').hasMatch(trimmed)) {
    throw StateError('Phone number contains invalid characters.');
  }
  final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length < 8 || digits.length > 15) {
    throw StateError(
        'Phone number must include country code and be 8 to 15 digits.');
  }
  if (digits.startsWith('0')) {
    throw StateError(
        'Use country code instead of a leading zero, for example +263...');
  }
  return digits;
}

int parseMoneyCents(String value) =>
    ((double.tryParse(value.trim().replaceAll(',', '')) ?? 0) * 100).round();
String cleanError(Object error) {
  final raw = error
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('Exception: ', '');
  final lower = raw.toLowerCase();
  if (lower.contains('failed host lookup') ||
      lower.contains('no address associated with hostname') ||
      lower.contains('socketexception')) {
    return 'Cloud connection failed. Check that this device has working internet, Wi-Fi/mobile data can open websites, and the Supabase project URL is correct. Then try again.';
  }
  if (lower.contains('connection timed out') ||
      lower.contains('timed out') ||
      lower.contains('connection closed')) {
    return 'Cloud connection timed out. Check internet signal and try again.';
  }
  if (lower.contains('permission denied') && lower.contains('internet')) {
    return 'This app build was blocked from internet access. Install the latest Light Winter APK and try again.';
  }
  return raw;
}

String paymentMethodLabel(String value) {
  return switch (value.toLowerCase().replaceAll('_', ' ')) {
    'card' => 'Card',
    'mobile money' => 'Mobile Money',
    'mobile' => 'Mobile Money',
    'debt' => 'Debt',
    _ => 'Cash',
  };
}

String customerShortCode(String value) {
  final clean =
      value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '').padRight(6, '0');
  return 'C-${clean.substring(max(0, clean.length - 6))}';
}

String formatLicenseCountdown(DateTime? expiresAt, {DateTime? nowUtc}) {
  if (expiresAt == null) return 'Not licensed';
  final remaining =
      expiresAt.toUtc().difference(nowUtc ?? DateTime.now().toUtc());
  if (remaining.isNegative || remaining.inSeconds <= 0) return 'Expired';
  final days = remaining.inDays;
  final hours = remaining.inHours.remainder(24);
  final minutes = remaining.inMinutes.remainder(60);
  final seconds = remaining.inSeconds.remainder(60);
  String two(int value) => value.toString().padLeft(2, '0');
  if (days > 0) return '${days}d ${two(hours)}h ${two(minutes)}m left';
  if (hours > 0) return '${two(hours)}h ${two(minutes)}m left';
  return '${two(minutes)}:${two(seconds)} left';
}

class LoadingScreen extends StatelessWidget {
  const LoadingScreen({super.key});
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class BusyOverlay extends StatelessWidget {
  const BusyOverlay({required this.store, required this.child, super.key});
  final AppStore store;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      child,
      if (store.isBusy)
        Positioned.fill(
          child: AbsorbPointer(
            absorbing: true,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.28),
              child: SafeArea(
                child: Stack(children: [
                  Align(
                    alignment: Alignment.topCenter,
                    child: LinearProgressIndicator(
                      minHeight: 4,
                      backgroundColor: Colors.white.withValues(alpha: 0.35),
                    ),
                  ),
                  Center(
                    child: Container(
                      width: min(MediaQuery.sizeOf(context).width - 32, 420),
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF0B7D72)),
                        boxShadow: const [
                          BoxShadow(
                              color: Color(0x33000000),
                              blurRadius: 24,
                              offset: Offset(0, 12))
                        ],
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                store.busyMessage ?? 'Working...',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w900, fontSize: 16),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Please wait. Do not tap again.',
                                style: TextStyle(
                                    fontSize: 12, color: Color(0xFF4B5A57)),
                              ),
                            ],
                          ),
                        ),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}

class StartScreen extends StatefulWidget {
  const StartScreen({required this.store, super.key});
  final AppStore store;

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  String status =
      'If this device was already in a shop, recover it from cloud first. Do not create a new shop unless this is a brand-new customer.';
  Tone tone = Tone.warning;

  Future<void> _recoverPreviousDeviceId() async {
    final controller = TextEditingController(text: 'LWR-');
    final previousId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use Previous Device ID'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Old Device ID',
            hintText: 'LWR-123456',
            helperText: 'Use the licensed ID already saved in Supabase.',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Recover')),
        ],
      ),
    );
    controller.dispose();
    if (previousId == null || previousId.trim().isEmpty) return;
    setState(() {
      status = 'Recovering ${previousId.trim().toUpperCase()}...';
      tone = Tone.warning;
    });
    try {
      await widget.store.recoverPreviousDeviceIdFromCloud(previousId);
      if (!mounted) return;
      setState(() {
        status = 'Previous Device ID restored. Continue with login.';
        tone = Tone.good;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        status = 'Could not recover previous ID: ${cleanError(error)}';
        tone = Tone.danger;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: DecoratedPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset('assets/brand/light_winter_logo.png',
                        width: 58, height: 58),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('Light Winter RetailOS',
                        style: TextStyle(
                            fontSize: 30, fontWeight: FontWeight.w900)),
                  ),
                ]),
                const Text(
                    'Choose how this device should enter the shop system.'),
                const SizedBox(height: 18),
                DeviceIdCard(deviceUid: store.deviceUid),
                const SizedBox(height: 12),
                SetupStatusBanner(text: status, tone: tone, busy: false),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () async {
                    setState(() {
                      status = 'Checking Supabase for this device...';
                      tone = Tone.warning;
                    });
                    try {
                      await store.recoverCurrentDeviceFromCloud();
                      if (!mounted) return;
                      setState(() {
                        status = 'Device recovered. Continue with login.';
                        tone = Tone.good;
                      });
                    } catch (error) {
                      if (!mounted) return;
                      setState(() {
                        status =
                            'Could not recover this device ID: ${cleanError(error)}';
                        tone = Tone.danger;
                      });
                    }
                  },
                  icon: const Icon(Icons.cloud_sync),
                  label: const Text('Recover This Device From Cloud'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _recoverPreviousDeviceId,
                  icon: const Icon(Icons.badge),
                  label: const Text('Use Previous Device ID'),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SetupScreen(store: widget.store))),
                  icon: const Icon(Icons.storefront),
                  label: const Text('Create New Shop as Owner'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => JoinShopScreen(store: widget.store))),
                  icon: const Icon(Icons.link),
                  label: const Text('Join Existing Shop / Branch'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => RecoverShopScreen(store: widget.store))),
                  icon: const Icon(Icons.restore),
                  label: const Text('Recover Existing Shop as Owner'),
                ),
                const SizedBox(height: 12),
                const InfoPanel(
                  icon: Icons.info,
                  title: 'Correct rollout',
                  body:
                      'Only the owner or main admin creates the shop. Other phones, SUNMI devices, iPhones, and Windows tills join the existing shop, get assigned to a branch, then users log in with accounts created by the owner.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class JoinShopScreen extends StatefulWidget {
  const JoinShopScreen({required this.store, super.key});
  final AppStore store;

  @override
  State<JoinShopScreen> createState() => _JoinShopScreenState();
}

class _JoinShopScreenState extends State<JoinShopScreen> {
  final formKey = GlobalKey<FormState>();
  final shop = TextEditingController();
  final branch = TextEditingController();
  final code = TextEditingController();
  final backend = TextEditingController(
      text: defaultSupabaseUrl == '' ? defaultBackendUrl : defaultSupabaseUrl);
  final anonKey = TextEditingController(text: defaultSupabaseAnonKey);
  bool fiscalMode = false;
  bool busy = false;
  String status =
      'Enter the invite details, test cloud, then join this device.';
  Tone statusTone = Tone.neutral;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join Existing Shop')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: DecoratedPanel(
              child: Form(
                key: formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Device Enrollment',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w900)),
                    const Text(
                        'Use the activation/invite details supplied by the owner or Light Winter Technologies.'),
                    const SizedBox(height: 14),
                    SetupStatusBanner(
                        text: status, tone: statusTone, busy: busy),
                    const SizedBox(height: 12),
                    Field(
                        controller: shop,
                        label: 'Shop name',
                        icon: Icons.storefront,
                        required: true),
                    Field(
                        controller: branch,
                        label: 'Assigned branch',
                        icon: Icons.account_tree,
                        required: true),
                    Field(
                        controller: code,
                        label: 'Activation / branch invite code',
                        icon: Icons.key,
                        required: true),
                    Field(
                        controller: backend,
                        label: 'Backend server URL',
                        icon: Icons.cloud,
                        required: true),
                    Field(
                        controller: anonKey,
                        label: 'Supabase anon public key',
                        icon: Icons.vpn_key,
                        obscure: true,
                        required: isSupabaseUrl(backend.text.trim())),
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              setState(() {
                                busy = true;
                                status = 'Testing cloud connection...';
                                statusTone = Tone.warning;
                              });
                              try {
                                await widget.store.testCloudConnection(
                                    backend.text.trim(),
                                    serverAnonKey: anonKey.text.trim());
                                setState(() {
                                  status =
                                      'Cloud connection OK. You can join this device.';
                                  statusTone = Tone.good;
                                });
                              } catch (error) {
                                setState(() {
                                  status = error
                                      .toString()
                                      .replaceFirst('Bad state: ', '');
                                  statusTone = Tone.danger;
                                });
                              } finally {
                                if (mounted) setState(() => busy = false);
                              }
                            },
                      icon: const Icon(Icons.cloud_done),
                      label: const Text('Test Cloud Connection'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: fiscalMode,
                      onChanged: (value) => setState(() => fiscalMode = value),
                      title: const Text('This branch/device uses fiscal mode'),
                    ),
                    FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              if (!formKey.currentState!.validate()) return;
                              setState(() {
                                busy = true;
                                status = 'Joining shared shop database...';
                                statusTone = Tone.warning;
                              });
                              try {
                                await widget.store.joinExistingShop(
                                  shopName: shop.text.trim(),
                                  branchName: branch.text.trim(),
                                  activationCode: code.text.trim(),
                                  fiscalMode: fiscalMode,
                                  serverUrl: backend.text.trim(),
                                  serverAnonKey: anonKey.text.trim(),
                                );
                                setState(() {
                                  status =
                                      'Device joined. Continue with login.';
                                  statusTone = Tone.good;
                                });
                                if (context.mounted)
                                  Navigator.of(context).pop();
                              } catch (error) {
                                setState(() {
                                  status = error
                                      .toString()
                                      .replaceFirst('Bad state: ', '');
                                  statusTone = Tone.danger;
                                });
                              } finally {
                                if (mounted) setState(() => busy = false);
                              }
                            },
                      icon: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.check_circle),
                      label: Text(busy ? 'Working...' : 'Join Device'),
                    ),
                    const SizedBox(height: 12),
                    const WarningPanel(
                        text:
                            'After joining, this device needs synced users from the owner/admin account before normal staff can log in. In production this will come from the backend activation service.'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RecoverShopScreen extends StatefulWidget {
  const RecoverShopScreen({required this.store, super.key});
  final AppStore store;

  @override
  State<RecoverShopScreen> createState() => _RecoverShopScreenState();
}

class _RecoverShopScreenState extends State<RecoverShopScreen> {
  final formKey = GlobalKey<FormState>();
  final recovery = TextEditingController();
  final username = TextEditingController();
  final pin = TextEditingController();
  final backend = TextEditingController(
      text: defaultSupabaseUrl == '' ? defaultBackendUrl : defaultSupabaseUrl);
  final anonKey = TextEditingController(text: defaultSupabaseAnonKey);
  bool busy = false;
  String status =
      'Use the owner recovery code plus owner login to restore this shop from Supabase.';
  Tone statusTone = Tone.neutral;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recover Existing Shop')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: DecoratedPanel(
              child: Form(
                key: formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Owner Recovery',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w900)),
                    const Text(
                        'This is for reinstalling or replacing the owner device. Staff devices should use branch invite codes instead.'),
                    const SizedBox(height: 14),
                    SetupStatusBanner(
                        text: status, tone: statusTone, busy: busy),
                    const SizedBox(height: 12),
                    Field(
                        controller: recovery,
                        label: 'Owner recovery code',
                        icon: Icons.restore,
                        required: true),
                    Field(
                        controller: username,
                        label: 'Owner username',
                        icon: Icons.person,
                        required: true),
                    Field(
                        controller: pin,
                        label: 'Owner PIN',
                        icon: Icons.lock,
                        obscure: true,
                        keyboardType: TextInputType.number,
                        required: true),
                    Field(
                        controller: backend,
                        label: 'Supabase URL',
                        icon: Icons.cloud,
                        required: true),
                    Field(
                        controller: anonKey,
                        label: 'Supabase anon public key',
                        icon: Icons.vpn_key,
                        obscure: true,
                        required: isSupabaseUrl(backend.text.trim())),
                    FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              if (!formKey.currentState!.validate()) return;
                              setState(() {
                                busy = true;
                                status = 'Recovering shop from Supabase...';
                                statusTone = Tone.warning;
                              });
                              try {
                                await widget.store.recoverExistingShop(
                                  recoveryCode: recovery.text.trim(),
                                  ownerUsername: username.text.trim(),
                                  ownerPin: pin.text.trim(),
                                  serverUrl: backend.text.trim(),
                                  serverAnonKey: anonKey.text.trim(),
                                );
                                setState(() {
                                  status =
                                      'Recovered. This device still needs its own license if it is new.';
                                  statusTone = Tone.good;
                                });
                                if (context.mounted)
                                  Navigator.of(context).pop();
                              } catch (error) {
                                setState(() {
                                  status = cleanError(error);
                                  statusTone = Tone.danger;
                                });
                              } finally {
                                if (mounted) setState(() => busy = false);
                              }
                            },
                      icon: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.cloud_download),
                      label: Text(busy ? 'Recovering...' : 'Recover Shop'),
                    ),
                    const SizedBox(height: 12),
                    const WarningPanel(
                        text:
                            'Keep the recovery code private. It is for the owner/admin only and is not the same as a branch activation code.'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({required this.store, super.key});
  final AppStore store;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final formKey = GlobalKey<FormState>();
  final shop = TextEditingController();
  final branch = TextEditingController(text: 'Main Branch');
  final owner = TextEditingController();
  final ownerUsername = TextEditingController();
  final pin = TextEditingController();
  final phone = TextEditingController();
  final address = TextEditingController();
  final backend = TextEditingController(
      text: defaultSupabaseUrl == '' ? defaultBackendUrl : defaultSupabaseUrl);
  final anonKey = TextEditingController(text: defaultSupabaseAnonKey);
  final List<UserDraft> extraUsers = [];
  final List<BranchDraft> extraBranches = [];
  bool fiscalMode = false;
  bool busy = false;
  String status =
      'Create the shop in the shared cloud database. This device will still need a license voucher before selling.';
  Tone statusTone = Tone.neutral;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: DecoratedPanel(
              child: Form(
                key: formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Light Winter RetailOS',
                        style: TextStyle(
                            fontSize: 30, fontWeight: FontWeight.w900)),
                    const Text('Create the real shop profile before selling.'),
                    const SizedBox(height: 18),
                    SetupStatusBanner(
                        text: status, tone: statusTone, busy: busy),
                    const SizedBox(height: 12),
                    Field(
                        controller: shop,
                        label: 'Shop name',
                        icon: Icons.storefront,
                        required: true),
                    Field(
                        controller: branch,
                        label: 'Branch name',
                        icon: Icons.account_tree,
                        required: true),
                    Field(
                        controller: phone,
                        label: 'Shop phone',
                        icon: Icons.phone),
                    Field(
                        controller: address,
                        label: 'Shop address',
                        icon: Icons.location_on),
                    Field(
                        controller: backend,
                        label: 'Backend server URL',
                        icon: Icons.cloud,
                        required: true),
                    Field(
                        controller: anonKey,
                        label: 'Supabase anon public key',
                        icon: Icons.vpn_key,
                        obscure: true,
                        required: isSupabaseUrl(backend.text.trim())),
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              setState(() {
                                busy = true;
                                status = 'Testing cloud connection...';
                                statusTone = Tone.warning;
                              });
                              try {
                                await widget.store.testCloudConnection(
                                    backend.text.trim(),
                                    serverAnonKey: anonKey.text.trim());
                                setState(() {
                                  status =
                                      'Cloud connection OK. You can create the shop.';
                                  statusTone = Tone.good;
                                });
                              } catch (error) {
                                setState(() {
                                  status = error
                                      .toString()
                                      .replaceFirst('Bad state: ', '');
                                  statusTone = Tone.danger;
                                });
                              } finally {
                                if (mounted) setState(() => busy = false);
                              }
                            },
                      icon: const Icon(Icons.cloud_done),
                      label: const Text('Test Cloud Connection'),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            final draft = await showBranchEditorDialog(context,
                                title: 'Add Branch During Registration');
                            if (draft != null)
                              setState(() => extraBranches.add(draft));
                          },
                          icon: const Icon(Icons.account_tree),
                          label: const Text('Add Another Branch'),
                        ),
                      ],
                    ),
                    if (extraBranches.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      DataStrip(
                          headers: const ['Branch', 'Phone', 'Address'],
                          rows: extraBranches
                              .map((b) => [b.name, b.phone, b.address])
                              .toList()),
                    ],
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: fiscalMode,
                      onChanged: (value) => setState(() => fiscalMode = value),
                      title: const Text('This shop requires fiscalisation'),
                      subtitle: const Text(
                          'Turn this on only for businesses that must use ZIMRA FDMS fiscal features.'),
                    ),
                    const Divider(height: 28),
                    Field(
                        controller: owner,
                        label: 'Owner name',
                        icon: Icons.admin_panel_settings,
                        required: true),
                    Field(
                        controller: ownerUsername,
                        label: 'Owner username',
                        icon: Icons.alternate_email,
                        required: true),
                    Field(
                        controller: pin,
                        label: 'Owner PIN / password',
                        icon: Icons.pin,
                        required: true,
                        obscure: true,
                        keyboardType: TextInputType.number),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            final draft = await showUserEditorDialog(context,
                                title: 'Add User During Registration',
                                branches: const []);
                            if (draft != null)
                              setState(() => extraUsers.add(draft));
                          },
                          icon: const Icon(Icons.person_add),
                          label: const Text('Add Another User'),
                        ),
                      ],
                    ),
                    if (extraUsers.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      DataStrip(
                          headers: const [
                            'Name',
                            'Username',
                            'Role',
                            'Privileges'
                          ],
                          rows: extraUsers
                              .map((u) => [
                                    u.name,
                                    u.username,
                                    u.role,
                                    '${u.permissions.length} selected'
                                  ])
                              .toList()),
                    ],
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              if (!formKey.currentState!.validate()) return;
                              setState(() {
                                busy = true;
                                status =
                                    'Creating shop, branches, owner, products, and device in Supabase...';
                                statusTone = Tone.warning;
                              });
                              try {
                                await widget.store.setup(
                                  shopName: shop.text.trim(),
                                  branchName: branch.text.trim(),
                                  ownerName: owner.text.trim(),
                                  ownerUsername: ownerUsername.text.trim(),
                                  ownerPin: pin.text.trim(),
                                  fiscalMode: fiscalMode,
                                  extraUsers: extraUsers,
                                  extraBranches: extraBranches,
                                  phone: phone.text.trim(),
                                  address: address.text.trim(),
                                  serverUrl: backend.text.trim(),
                                  serverAnonKey: anonKey.text.trim(),
                                );
                                setState(() {
                                  status =
                                      'Shop created. Continue with owner login and device licensing.';
                                  statusTone = Tone.good;
                                });
                                if (context.mounted)
                                  Navigator.of(context).pop();
                              } catch (error) {
                                setState(() {
                                  status = error
                                      .toString()
                                      .replaceFirst('Bad state: ', '');
                                  statusTone = Tone.danger;
                                });
                              } finally {
                                if (mounted) setState(() => busy = false);
                              }
                            },
                      icon: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.rocket_launch),
                      label: Text(
                          busy ? 'Creating...' : 'Create Shop and Continue'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({required this.store, super.key});
  final AppStore store;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final username = TextEditingController();
  final pin = TextEditingController();
  String? error;

  @override
  Widget build(BuildContext context) {
    final company = widget.store.company!;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: DecoratedPanel(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.asset('assets/brand/light_winter_logo.png',
                            width: 52, height: 52),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(company.shopName,
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w900)),
                    Text('${company.branchName} - Light Winter Technologies'),
                    const SizedBox(height: 12),
                    SetupStatusBanner(
                      text: !widget.store.deviceActive
                          ? (widget.store.deviceLockMessage.isEmpty
                              ? 'This device has been deactivated. Contact Light Winter Technologies.'
                              : widget.store.deviceLockMessage)
                          : widget.store.isLicensed
                              ? 'Device licensed. Login to continue.'
                              : 'Shop profile is ready. Login, then enter the license voucher for Device ID ${widget.store.deviceUid}.',
                      tone: !widget.store.deviceActive
                          ? Tone.danger
                          : widget.store.isLicensed
                              ? Tone.good
                              : Tone.warning,
                      busy: false,
                    ),
                    const SizedBox(height: 8),
                    DecoratedBox(
                      decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8)),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(children: [
                          const Icon(Icons.devices, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SelectableText(
                              'Device ID: ${widget.store.deviceUid}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w900),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Copy Device ID',
                            onPressed: () async {
                              await Clipboard.setData(
                                  ClipboardData(text: widget.store.deviceUid));
                              if (context.mounted) {
                                showMessage(context, 'Device ID copied');
                              }
                            },
                            icon: const Icon(Icons.copy),
                          )
                        ]),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (widget.store.users.isEmpty) ...[
                      const WarningPanel(
                          text:
                              'This device has joined a shop but no user accounts are synced yet. The owner/admin must activate this device and sync users before staff can log in.'),
                      const SizedBox(height: 8),
                    ],
                    Field(
                        controller: username,
                        label: 'Username',
                        icon: Icons.person,
                        required: true),
                    Field(
                        controller: pin,
                        label: 'PIN / password',
                        icon: Icons.lock,
                        obscure: true,
                        required: true,
                        keyboardType: TextInputType.number),
                    if (error != null)
                      Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: !widget.store.deviceActive
                          ? null
                          : () async {
                              final ok = await widget.store
                                  .login(username.text.trim(), pin.text.trim());
                              if (!ok)
                                setState(
                                    () => error = widget.store.lastLoginError);
                            },
                      icon: const Icon(Icons.login),
                      label: const Text('Login'),
                    ),
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => ForgotOwnerAccessScreen(
                                  store: widget.store))),
                      icon: const Icon(Icons.help_outline),
                      label: const Text('Forgot owner username or PIN'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ForgotOwnerAccessScreen extends StatefulWidget {
  const ForgotOwnerAccessScreen({required this.store, super.key});
  final AppStore store;

  @override
  State<ForgotOwnerAccessScreen> createState() =>
      _ForgotOwnerAccessScreenState();
}

class _ForgotOwnerAccessScreenState extends State<ForgotOwnerAccessScreen> {
  final formKey = GlobalKey<FormState>();
  final recovery = TextEditingController();
  final voucher = TextEditingController();
  final newPin = TextEditingController();
  bool resetPin = true;
  String status =
      'Contact Light Winter Technologies with your Device ID and recovery code to receive a reset voucher.';
  Tone tone = Tone.neutral;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Forgot Owner Access')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: DecoratedPanel(
              child: Form(
                key: formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Owner Access Reset',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    SelectableText('Device ID: ${widget.store.deviceUid}',
                        style: const TextStyle(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 10),
                    SetupStatusBanner(text: status, tone: tone, busy: false),
                    const SizedBox(height: 12),
                    Field(
                        controller: recovery,
                        label: 'Owner recovery code',
                        icon: Icons.restore,
                        required: true),
                    Field(
                        controller: voucher,
                        label: 'Light Winter reset voucher',
                        icon: Icons.confirmation_number,
                        required: true),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: resetPin,
                      onChanged: (value) => setState(() => resetPin = value),
                      title: const Text('Reset owner PIN',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: const Text(
                          'Turn off if you only need to reveal the owner username.'),
                    ),
                    if (resetPin)
                      Field(
                          controller: newPin,
                          label: 'New owner PIN',
                          icon: Icons.lock_reset,
                          obscure: true,
                          keyboardType: TextInputType.number,
                          required: true),
                    FilledButton.icon(
                      onPressed: () async {
                        if (!formKey.currentState!.validate()) return;
                        if (resetPin && newPin.text.trim().length < 4) {
                          setState(() {
                            status = 'Use at least 4 digits for the new PIN.';
                            tone = Tone.danger;
                          });
                          return;
                        }
                        try {
                          final result = await widget.store.resetOwnerAccess(
                              recoveryCode: recovery.text.trim(),
                              resetVoucher: voucher.text.trim(),
                              newPin: resetPin ? newPin.text.trim() : '');
                          setState(() {
                            status =
                                'Shop: ${result['shop_name'] ?? ''}. Owner username: ${result['owner_username'] ?? ''}. ${resetPin ? 'PIN reset successfully.' : 'PIN was not changed.'}';
                            tone = Tone.good;
                          });
                        } catch (error) {
                          setState(() {
                            status = cleanError(error);
                            tone = Tone.danger;
                          });
                        }
                      },
                      icon: const Icon(Icons.verified_user),
                      label: const Text('Use Reset Voucher'),
                    ),
                    const SizedBox(height: 12),
                    const WarningPanel(
                        text:
                            'Reset vouchers are one-time codes generated by Light Winter Technologies. Do not give them to staff unless you want owner access reset.'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RetailShell extends StatefulWidget {
  const RetailShell({required this.store, super.key});
  final AppStore store;

  @override
  State<RetailShell> createState() => _RetailShellState();
}

class _RetailShellState extends State<RetailShell> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    if (!store.isLicensed) {
      return LicenseGateScreen(store: store);
    }
    final nav = appNavItems(store);
    if (index >= nav.length) index = 0;
    final wide = MediaQuery.sizeOf(context).width >= 980;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(store.company!.shopName,
                style: const TextStyle(fontWeight: FontWeight.w900)),
            Text(
                '${store.currentBranch?.name ?? store.company!.branchName} - ${store.currentUser!.role} ${store.currentUser!.name}',
                style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          if (wide && store.fiscalMode)
            StatusPill(
                label: store.fiscalDayOpen
                    ? 'Fiscal day open'
                    : 'Fiscal configured',
                icon: Icons.receipt_long,
                tone: Tone.warning),
          if (wide) const SizedBox(width: 8),
          if (wide)
            StatusPill(
                label: store.licenseCountdownLabel,
                icon: Icons.verified_user,
                tone: store.isLicensed ? Tone.good : Tone.danger)
          else
            IconButton(
              onPressed: () =>
                  showMessage(context, store.licenseCountdownLabel),
              icon: Icon(Icons.verified_user,
                  color: store.isLicensed
                      ? const Color(0xFF168354)
                      : const Color(0xFFB3261E)),
              tooltip: store.licenseCountdownLabel,
            ),
          PopupMenuButton<int>(
            tooltip: 'Open section',
            icon: const Icon(Icons.apps),
            onSelected: (value) => setState(() => index = value),
            itemBuilder: (context) => [
              for (var i = 0; i < nav.length; i++)
                PopupMenuItem(
                  value: i,
                  child: Row(
                    children: [
                      Icon(nav[i].icon, size: 20),
                      const SizedBox(width: 10),
                      Text(nav[i].label),
                    ],
                  ),
                ),
            ],
          ),
          IconButton(
              onPressed: store.logout,
              icon: const Icon(Icons.logout),
              tooltip: 'Logout'),
        ],
        bottom: BranchTopSwitcher(store: store),
      ),
      body: Row(
        children: [
          if (wide)
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: (value) => setState(() => index = value),
              labelType: NavigationRailLabelType.all,
              destinations: nav
                  .map((item) => NavigationRailDestination(
                      icon: Icon(item.icon), label: Text(item.label)))
                  .toList(),
            ),
          Expanded(
            child: Column(
              children: [
                if (!wide) LicenseCountdownBar(store: store),
                Expanded(
                    child: AnimatedBuilder(
                        animation: store,
                        builder: (_, __) {
                          final liveNav = appNavItems(store);
                          if (index >= liveNav.length) index = 0;
                          return liveNav[index].page;
                        })),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: wide || nav.length < 2
          ? null
          : NavigationBar(
              selectedIndex: _bottomIndex(nav, index),
              onDestinationSelected: (value) {
                final visible = _bottomNavIndexes(nav);
                setState(() => index = visible[value]);
              },
              destinations: _bottomNavIndexes(nav).map((itemIndex) {
                final item = nav[itemIndex];
                return NavigationDestination(
                    icon: Icon(item.icon), label: item.label);
              }).toList(),
            ),
    );
  }
}

List<int> _bottomNavIndexes(List<AppNavItem> nav) {
  if (nav.length <= 5) return List.generate(nav.length, (index) => index);
  final adminIndex = nav.indexWhere((item) => item.label == 'Admin');
  final indexes =
      <int>[0, 1, 2, 3].where((index) => index < nav.length).toList();
  if (adminIndex >= 0 && !indexes.contains(adminIndex)) {
    indexes.add(adminIndex);
  } else {
    indexes.add(4);
  }
  return indexes.toSet().toList();
}

int _bottomIndex(List<AppNavItem> nav, int selectedIndex) {
  final visible = _bottomNavIndexes(nav);
  final bottomIndex = visible.indexOf(selectedIndex);
  return bottomIndex >= 0 ? bottomIndex : 0;
}

class BranchTopSwitcher extends StatelessWidget implements PreferredSizeWidget {
  const BranchTopSwitcher({required this.store, super.key});
  final AppStore store;

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  Widget build(BuildContext context) {
    final branches = store.accessibleBranches;
    final current = store.currentBranch;
    if (current == null) return const SizedBox.shrink();
    final selectedId = branches.any((branch) => branch.id == current.id)
        ? current.id
        : branches.firstOrNull?.id;
    return Container(
      height: preferredSize.height,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          bottom:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Row(children: [
        Icon(Icons.storefront,
            size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        const Text('Branch',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
        const SizedBox(width: 10),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: selectedId,
              isExpanded: true,
              icon: const Icon(Icons.keyboard_arrow_down),
              items: branches
                  .map((branch) => DropdownMenuItem(
                        value: branch.id,
                        child: Text(
                          branch.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ))
                  .toList(),
              onChanged: branches.length < 2
                  ? null
                  : (branchId) async {
                      if (branchId == null ||
                          branchId == store.assignedBranchId) {
                        return;
                      }
                      final branch = branches
                          .where((item) => item.id == branchId)
                          .firstOrNull;
                      if (branch == null) return;
                      if (store.hasOpenCartItems) {
                        final confirmed = await confirmDanger(
                            context,
                            'Switch branch?',
                            'Open POS carts will be cleared before switching to ${branch.name}.');
                        if (!confirmed) return;
                      }
                      try {
                        await store.assignDeviceToBranch(branch);
                        if (context.mounted) {
                          showMessage(
                              context, 'Now operating as ${branch.name}');
                        }
                      } catch (error) {
                        if (context.mounted)
                          showMessage(context, cleanError(error));
                      }
                    },
            ),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message:
              'Only branches assigned to this user are shown. Owner/all-privilege users see every branch.',
          child: Icon(Icons.verified_user,
              size: 18, color: Theme.of(context).colorScheme.primary),
        ),
      ]),
    );
  }
}

class AppNavItem {
  AppNavItem({required this.label, required this.icon, required this.page});
  final String label;
  final IconData icon;
  final Widget page;
}

List<AppNavItem> appNavItems(AppStore store) {
  final user = store.currentUser!;
  final items = <AppNavItem>[];
  if (user.can(AppPermission.dashboard))
    items.add(AppNavItem(
        label: 'Home',
        icon: Icons.dashboard,
        page: DashboardPage(store: store)));
  if (user.can(AppPermission.profit))
    items.add(AppNavItem(
        label: 'Profit',
        icon: Icons.account_balance,
        page: ProfitLossPage(store: store)));
  if (user.can(AppPermission.pos))
    items.add(AppNavItem(
        label: 'POS', icon: Icons.point_of_sale, page: PosPage(store: store)));
  if (user.can(AppPermission.inventory))
    items.add(AppNavItem(
        label: 'Stock',
        icon: Icons.inventory_2,
        page: InventoryPage(store: store)));
  if (user.can(AppPermission.branches))
    items.add(AppNavItem(
        label: 'Branches',
        icon: Icons.account_tree,
        page: BranchesPage(store: store)));
  if (user.can(AppPermission.customers))
    items.add(AppNavItem(
        label: 'Debt',
        icon: Icons.people,
        page: CustomerDebtPage(store: store)));
  if (user.can(AppPermission.printing))
    items.add(AppNavItem(
        label: 'Print', icon: Icons.print, page: PrintPage(store: store)));
  if (store.fiscalMode && user.can(AppPermission.fiscal))
    items.add(AppNavItem(
        label: 'Fiscal',
        icon: Icons.receipt_long,
        page: FiscalPage(store: store)));
  if (user.can(AppPermission.admin))
    items.add(AppNavItem(
        label: 'Admin',
        icon: Icons.admin_panel_settings,
        page: AdminPage(store: store)));
  return items.isEmpty
      ? [
          AppNavItem(
              label: 'Print', icon: Icons.lock, page: const AccessDeniedPage())
        ]
      : items;
}

class AccessDeniedPage extends StatelessWidget {
  const AccessDeniedPage({super.key});
  @override
  Widget build(BuildContext context) =>
      const PageFrame(title: 'No Access', children: [
        InfoPanel(
            icon: Icons.lock,
            title: 'No privileges assigned',
            body: 'Ask the owner to update this user account.')
      ]);
}

class LicenseGateScreen extends StatefulWidget {
  const LicenseGateScreen({required this.store, super.key});
  final AppStore store;

  @override
  State<LicenseGateScreen> createState() => _LicenseGateScreenState();
}

class _LicenseGateScreenState extends State<LicenseGateScreen> {
  final token = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    token.dispose();
    super.dispose();
  }

  Future<void> verifyLicense() async {
    setState(() => busy = true);
    try {
      await widget.store.useBuiltInCloudSettings();
      await widget.store.applyLicense(token.text);
      if (mounted) {
        showMessage(context, 'License verified. Device unlocked.');
      }
    } catch (error) {
      if (mounted) {
        showMessage(context, error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device License Required'),
        actions: [
          IconButton(
              onPressed: store.logout,
              icon: const Icon(Icons.logout),
              tooltip: 'Logout'),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: DecoratedPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.verified_user, size: 52),
                  const SizedBox(height: 12),
                  const Text('This Device Is Locked',
                      style:
                          TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                    '${store.company!.shopName} - ${store.currentBranch?.name ?? store.company!.branchName}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 16),
                  const WarningPanel(
                      text:
                          'Send this Device ID to Light Winter Technologies. A license voucher will be generated for this exact device. Until the voucher is applied, POS, stock, reports, fiscal tools, users, and branches stay locked.'),
                  const SizedBox(height: 14),
                  DeviceIdCard(deviceUid: store.deviceUid),
                  const SizedBox(height: 14),
                  Field(
                      controller: token,
                      label: 'License voucher',
                      icon: Icons.key,
                      required: true),
                  const InfoPanel(
                      icon: Icons.cloud_done,
                      title: 'Cloud verification is built in',
                      body:
                          'This app verifies license vouchers using the secure Light Winter cloud settings packaged inside the APK. No terminal commands or API keys are needed on customer devices.'),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: busy ? null : verifyLicense,
                    icon: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.lock_open),
                    label: const Text('Verify and Unlock Device'),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: store.deviceUid));
                      if (context.mounted)
                        showMessage(context, 'Device ID copied');
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy Device ID'),
                  ),
                  const SizedBox(height: 12),
                  Text('Status: ${store.licenseCountdownLabel}',
                      textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DeviceIdCard extends StatelessWidget {
  const DeviceIdCard({required this.deviceUid, super.key});
  final String deviceUid;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          const Icon(Icons.devices),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Device ID',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                SelectableText(deviceUid,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w900)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LicenseCountdownBar extends StatelessWidget {
  const LicenseCountdownBar({required this.store, super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final color =
        store.isLicensed ? const Color(0xFF168354) : const Color(0xFFB3261E);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border(bottom: BorderSide(color: color.withValues(alpha: 0.2))),
      ),
      child: Row(
        children: [
          Icon(Icons.verified_user, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              store.licenseCountdownLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}

class SetupStatusBanner extends StatelessWidget {
  const SetupStatusBanner(
      {required this.text, required this.tone, required this.busy, super.key});
  final String text;
  final Tone tone;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      Tone.good => const Color(0xFF168354),
      Tone.warning => const Color(0xFF9A6B00),
      Tone.danger => const Color(0xFFB3261E),
      Tone.neutral => Theme.of(context).colorScheme.primary,
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (busy)
            SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: color))
          else
            Icon(
              tone == Tone.good
                  ? Icons.check_circle
                  : tone == Tone.danger
                      ? Icons.error
                      : tone == Tone.warning
                          ? Icons.sync
                          : Icons.info,
              color: color,
            ),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700))),
        ],
      ),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({required this.store, super.key});
  final AppStore store;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  String period = 'daily';
  bool allBranches = true;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final report = store.reportSnapshot(period, allBranches: allBranches);
    final filePeriod = period.replaceAll(':', '-');
    return PageFrame(
      title: 'Reports and Backup',
      children: [
        MetricGrid(store: store, report: report),
        const SizedBox(height: 16),
        SmartInsightsPanel(
            store: store,
            insights: store.smartInsights(report, allBranches: allBranches)),
        const SizedBox(height: 16),
        DecoratedPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Report Controls',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'daily',
                      icon: Icon(Icons.today),
                      label: Text('Daily')),
                  ButtonSegment(
                      value: 'weekly',
                      icon: Icon(Icons.view_week),
                      label: Text('Weekly')),
                  ButtonSegment(
                      value: 'monthly',
                      icon: Icon(Icons.calendar_month),
                      label: Text('Monthly')),
                  ButtonSegment(
                      value: 'yearly',
                      icon: Icon(Icons.event_note),
                      label: Text('Yearly')),
                  ButtonSegment(
                      value: 'date',
                      icon: Icon(Icons.event),
                      label: Text('Date')),
                ],
                selected: {period.startsWith('date:') ? 'date' : period},
                onSelectionChanged: (value) async {
                  final selected = value.first;
                  if (selected == 'date') {
                    final picked = await showDatePicker(
                        context: context,
                        initialDate:
                            store.customPeriodDate(period) ?? DateTime.now(),
                        firstDate: DateTime(2020),
                        lastDate:
                            DateTime.now().add(const Duration(days: 365)));
                    if (picked != null && mounted) {
                      setState(() => period = store.customDatePeriod(picked));
                    }
                  } else {
                    setState(() => period = selected);
                  }
                },
              ),
            ),
            if (period.startsWith('date:')) ...[
              const SizedBox(height: 8),
              Chip(
                  avatar: const Icon(Icons.event, size: 18),
                  label: Text('Selected date: ${store.periodLabel(period)}')),
            ],
            const SizedBox(height: 10),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: allBranches,
              onChanged: (value) => setState(() => allBranches = value),
              title: const Text('All branches report',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(allBranches
                  ? 'Uses synced sales from every branch/device in this shop.'
                  : 'Uses this branch only: ${store.currentBranch?.name ?? 'current branch'}'),
            ),
            const SizedBox(height: 6),
            CurrencyChoiceRow(
              label: 'Report currency',
              selected: store.displayCurrency,
              onSelected: store.setDisplayCurrency,
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                  onPressed: () async {
                    await ReceiptOutputService.sharePdf(
                        store.reportText(report, allBranches: allBranches),
                        filename: 'light-winter-$filePeriod-report.pdf',
                        brandedReport: true);
                    if (context.mounted)
                      showMessage(context, 'Report PDF ready to share');
                  },
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('PDF / WhatsApp / Bluetooth')),
              OutlinedButton.icon(
                  onPressed: () async {
                    await ReceiptOutputService.printNative(
                        store.reportText(report, allBranches: allBranches),
                        brandedReport: true);
                  },
                  icon: const Icon(Icons.print),
                  label: const Text('Print')),
              OutlinedButton.icon(
                  onPressed: () async {
                    await launchUrl(
                        Uri.parse(
                            'mailto:?subject=${Uri.encodeComponent('Light Winter ${report.title}')}&body=${Uri.encodeComponent(store.reportText(report, allBranches: allBranches))}'),
                        mode: LaunchMode.externalApplication);
                  },
                  icon: const Icon(Icons.email),
                  label: const Text('Email')),
              OutlinedButton.icon(
                  onPressed: () async {
                    await store.syncNow();
                    if (context.mounted)
                      showMessage(context, 'Cloud sync refreshed');
                  },
                  icon: const Icon(Icons.cloud_sync),
                  label: const Text('Sync Cloud')),
              OutlinedButton.icon(
                  onPressed: () async {
                    final confirmed = await confirmTypedDelete(
                        context,
                        'Delete report history?',
                        allBranches
                            ? 'Type DELETE REPORTS to permanently delete all synced sales, debts, voids, and report history for this shop.'
                            : 'Type DELETE REPORTS to permanently delete sales, debts, voids, and report history for this branch.',
                        'DELETE REPORTS');
                    if (!confirmed) return;
                    await store.deleteAllReportHistory(
                        allBranches: allBranches);
                  },
                  icon: const Icon(Icons.delete_sweep),
                  label: const Text('Delete Reports')),
            ]),
          ]),
        ),
        const SizedBox(height: 16),
        ReportBreakdown(store: store, report: report),
        const SizedBox(height: 16),
        UserPerformancePanel(store: store, report: report),
        const SizedBox(height: 16),
        ProductPerformancePanel(store: store, report: report),
        const SizedBox(height: 16),
        TransactionDetailPanel(store: store, report: report),
        const SizedBox(height: 16),
        BackupPanel(store: store),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            HealthTile(
                icon: Icons.cloud_sync,
                title: 'Sync',
                value: 'Offline queue ready'),
            HealthTile(
                icon: Icons.inventory,
                title: 'Low stock',
                value:
                    '${store.lowStockCount} low, ${store.outOfStockCount} out'),
            HealthTile(
                icon: Icons.account_balance_wallet,
                title: 'Debt',
                value: money(store.debtCents)),
            HealthTile(
                icon: Icons.devices, title: 'Device', value: store.deviceUid),
            HealthTile(
                icon: Icons.account_tree,
                title: 'Assigned branch',
                value: store.currentBranch?.name ?? 'Not assigned'),
          ],
        ),
      ],
    );
  }
}

class ProfitLossPage extends StatefulWidget {
  const ProfitLossPage({required this.store, super.key});
  final AppStore store;

  @override
  State<ProfitLossPage> createState() => _ProfitLossPageState();
}

class _ProfitLossPageState extends State<ProfitLossPage> {
  String period = 'daily';
  bool allBranches = true;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final statement =
        store.profitLossStatement(period, allBranches: allBranches);
    final filePeriod = period.replaceAll(':', '-');
    return PageFrame(
      title: 'Profit and Loss',
      children: [
        DecoratedPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Accounting Controls',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'daily',
                      icon: Icon(Icons.today),
                      label: Text('Daily')),
                  ButtonSegment(
                      value: 'weekly',
                      icon: Icon(Icons.view_week),
                      label: Text('Weekly')),
                  ButtonSegment(
                      value: 'monthly',
                      icon: Icon(Icons.calendar_month),
                      label: Text('Monthly')),
                  ButtonSegment(
                      value: 'yearly',
                      icon: Icon(Icons.event_note),
                      label: Text('Yearly')),
                  ButtonSegment(
                      value: 'date',
                      icon: Icon(Icons.event),
                      label: Text('Date')),
                ],
                selected: {period.startsWith('date:') ? 'date' : period},
                onSelectionChanged: (value) async {
                  final selected = value.first;
                  if (selected == 'date') {
                    final picked = await showDatePicker(
                        context: context,
                        initialDate:
                            store.customPeriodDate(period) ?? DateTime.now(),
                        firstDate: DateTime(2020),
                        lastDate:
                            DateTime.now().add(const Duration(days: 365)));
                    if (picked != null && mounted) {
                      setState(() => period = store.customDatePeriod(picked));
                    }
                  } else {
                    setState(() => period = selected);
                  }
                },
              ),
            ),
            if (period.startsWith('date:')) ...[
              const SizedBox(height: 8),
              Chip(
                  avatar: const Icon(Icons.event, size: 18),
                  label: Text('Selected date: ${store.periodLabel(period)}')),
            ],
            const SizedBox(height: 10),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: allBranches,
              onChanged: (value) => setState(() => allBranches = value),
              title: const Text('All branches P/L',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(allBranches
                  ? 'Uses synced sales, stock costs, expenses, and income from all branches.'
                  : 'Uses this branch only: ${store.currentBranch?.name ?? 'current branch'}'),
            ),
            const SizedBox(height: 6),
            CurrencyChoiceRow(
              label: 'Accounting currency',
              selected: store.displayCurrency,
              onSelected: store.setDisplayCurrency,
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                  onPressed: () => showAccountingEntryDialog(context, store,
                      type: AccountingEntryType.expense),
                  icon: const Icon(Icons.receipt_long),
                  label: const Text('Add Expense')),
              FilledButton.icon(
                  onPressed: () => showStockPurchaseDialog(context, store),
                  icon: const Icon(Icons.add_shopping_cart),
                  label: const Text('Stock Purchase')),
              OutlinedButton.icon(
                  onPressed: () => showPurchaseOrderDialog(context, store),
                  icon: const Icon(Icons.assignment),
                  label: const Text('Purchase Order')),
              OutlinedButton.icon(
                  onPressed: () => showStockCountDialog(context, store),
                  icon: const Icon(Icons.fact_check),
                  label: const Text('Stock Count')),
              OutlinedButton.icon(
                  onPressed: () => showAccountingEntryDialog(context, store,
                      type: AccountingEntryType.income),
                  icon: const Icon(Icons.add_card),
                  label: const Text('Add Income')),
              OutlinedButton.icon(
                  onPressed: () => showSupplierPaymentDialog(context, store),
                  icon: const Icon(Icons.payments),
                  label: const Text('Pay Supplier')),
              OutlinedButton.icon(
                  onPressed: () => showPayrollDialog(context, store),
                  icon: const Icon(Icons.badge),
                  label: const Text('Payroll / HR')),
              OutlinedButton.icon(
                  onPressed: () => showCashUpDialog(context, store, statement),
                  icon: const Icon(Icons.point_of_sale),
                  label: const Text('Cash-Up')),
              OutlinedButton.icon(
                  onPressed: () =>
                      showReconciliationDialog(context, store, statement),
                  icon: const Icon(Icons.account_balance),
                  label: const Text('Reconcile')),
              OutlinedButton.icon(
                  onPressed: () => showSupplierStatementDialog(context, store),
                  icon: const Icon(Icons.description),
                  label: const Text('Supplier Statement')),
              OutlinedButton.icon(
                  onPressed: () async {
                    await ReceiptOutputService.sharePdf(
                        store.profitLossText(statement,
                            allBranches: allBranches),
                        filename: 'light-winter-profit-loss-$filePeriod.pdf',
                        brandedReport: true);
                  },
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('PDF / WhatsApp')),
              OutlinedButton.icon(
                  onPressed: () async {
                    await ReceiptOutputService.printNative(
                        store.profitLossText(statement,
                            allBranches: allBranches),
                        brandedReport: true);
                  },
                  icon: const Icon(Icons.print),
                  label: const Text('Print')),
              OutlinedButton.icon(
                  onPressed: () async {
                    await launchUrl(
                        Uri.parse(
                            'mailto:?subject=${Uri.encodeComponent('Light Winter Profit and Loss')}&body=${Uri.encodeComponent(store.profitLossText(statement, allBranches: allBranches))}'),
                        mode: LaunchMode.externalApplication);
                  },
                  icon: const Icon(Icons.email),
                  label: const Text('Email')),
              OutlinedButton.icon(
                  onPressed: () async {
                    final confirmed = await confirmTypedDelete(
                        context,
                        'Delete accounting entries?',
                        allBranches
                            ? 'Type DELETE ACCOUNTING to permanently delete all manual expenses and income entries for this shop.'
                            : 'Type DELETE ACCOUNTING to permanently delete manual expenses and income entries for this branch.',
                        'DELETE ACCOUNTING');
                    if (!confirmed) return;
                    await store.deleteAllAccountingEntries(
                        allBranches: allBranches);
                  },
                  icon: const Icon(Icons.delete_sweep),
                  label: const Text('Delete Entries')),
            ]),
          ]),
        ),
        const SizedBox(height: 16),
        AccountingOverviewPanel(store: store, statement: statement),
        const SizedBox(height: 16),
        ProfitLossSummaryPanel(store: store, statement: statement),
        const SizedBox(height: 16),
        CashbookPanel(store: store, statement: statement),
        const SizedBox(height: 16),
        BalanceTrackerPanel(store: store, statement: statement),
        const SizedBox(height: 16),
        PayrollPanel(
            store: store,
            entries: store.payrollEntriesForPeriod(period,
                allBranches: allBranches)),
        const SizedBox(height: 16),
        BusinessHealthPanel(store: store, statement: statement),
        const SizedBox(height: 16),
        AccountingCategoryPanel(store: store, statement: statement),
        const SizedBox(height: 16),
        AccountingEntryPanel(store: store, statement: statement),
      ],
    );
  }
}

class AccountingOverviewPanel extends StatelessWidget {
  const AccountingOverviewPanel(
      {required this.store, required this.statement, super.key});
  final AppStore store;
  final ProfitLossStatement statement;

  @override
  Widget build(BuildContext context) {
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Accounting Overview',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text(
            'Full shop accounting: sales, stock cost, supplier owing, customer debt, cashbook, owner money, and expenses.'),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          AccountingChip(
              icon: Icons.point_of_sale,
              label: 'Sales income',
              value: store.moneyFor(statement.report.totalSalesCents)),
          AccountingChip(
              icon: Icons.inventory_2,
              label: 'Stock bought',
              value: store.moneyFor(statement.stockPurchasesCents)),
          AccountingChip(
              icon: Icons.local_shipping,
              label: 'Supplier owing',
              value: store.moneyFor(statement.supplierPayablesCents)),
          AccountingChip(
              icon: Icons.account_balance_wallet,
              label: 'Customer debt',
              value: store.moneyFor(statement.customerDebtOutstandingCents)),
          AccountingChip(
              icon: Icons.savings,
              label: 'Owner capital',
              value: store.moneyFor(statement.ownerCapitalCents)),
          AccountingChip(
              icon: Icons.output,
              label: 'Owner drawings',
              value: store.moneyFor(statement.ownerDrawingsCents)),
        ]),
      ]),
    );
  }
}

class AccountingChip extends StatelessWidget {
  const AccountingChip(
      {required this.icon,
      required this.label,
      required this.value,
      super.key});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 190,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900)),
          ]),
        )
      ]),
    );
  }
}

class ProfitLossSummaryPanel extends StatelessWidget {
  const ProfitLossSummaryPanel(
      {required this.store, required this.statement, super.key});
  final AppStore store;
  final ProfitLossStatement statement;

  @override
  Widget build(BuildContext context) {
    final profitColor = statement.netProfitCents >= 0
        ? const Color(0xFF168354)
        : const Color(0xFFB3261E);
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Full Profit / Loss Statement',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 10),
        TotalRow(
            label: 'Net sales',
            value: store.moneyFor(statement.report.totalSalesCents),
            bold: true),
        TotalRow(
            label: 'Cost of goods sold',
            value: store.moneyFor(statement.report.costOfGoodsCents)),
        TotalRow(
            label: 'Gross profit',
            value: store.moneyFor(statement.report.grossProfitCents),
            bold: true),
        TotalRow(
            label: 'Other income',
            value: store.moneyFor(statement.otherIncomeCents)),
        TotalRow(
            label: 'Owner capital',
            value: store.moneyFor(statement.ownerCapitalCents)),
        TotalRow(
            label: 'Operating expenses',
            value: store.moneyFor(statement.operatingExpensesCents)),
        TotalRow(
            label: 'Owner drawings',
            value: store.moneyFor(statement.ownerDrawingsCents)),
        const Divider(height: 20),
        Row(children: [
          Expanded(
            child: Text('Net profit / loss',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          ),
          Text(store.moneyFor(statement.netProfitCents),
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: profitColor)),
        ]),
        const SizedBox(height: 6),
        TotalRow(
            label: 'Net margin',
            value: '${statement.netMarginPercent.toStringAsFixed(1)}%',
            bold: true),
        const Divider(height: 20),
        TotalRow(
            label: 'Stock purchases',
            value: store.moneyFor(statement.stockPurchasesCents)),
        TotalRow(
            label: 'Supplier payments',
            value: store.moneyFor(statement.supplierPaymentsCents)),
        TotalRow(
            label: 'Supplier still owing',
            value: store.moneyFor(statement.supplierPayablesCents),
            bold: true),
        TotalRow(
            label: 'Customer debt outstanding',
            value: store.moneyFor(statement.customerDebtOutstandingCents),
            bold: true),
        const Divider(height: 20),
        TotalRow(
            label: 'Stock value at cost',
            value: store.moneyFor(statement.report.stockValueAtCostCents)),
        TotalRow(
            label: 'Stock value at selling price',
            value: store.moneyFor(statement.report.stockValueAtRetailCents)),
        TotalRow(
            label: 'Potential stock profit',
            value: store.moneyFor(statement.report.potentialStockProfitCents)),
      ]),
    );
  }
}

class AccountingCategoryPanel extends StatelessWidget {
  const AccountingCategoryPanel(
      {required this.store, required this.statement, super.key});
  final AppStore store;
  final ProfitLossStatement statement;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 760;
      final expenses = AccountingCategoryList(
          title: 'Expenses by Category',
          empty: 'No expenses recorded.',
          values: statement.expensesByCategory,
          store: store);
      final income = AccountingCategoryList(
          title: 'Other Income by Category',
          empty: 'No other income recorded.',
          values: statement.incomeByCategory,
          store: store);
      if (wide) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: expenses),
          const SizedBox(width: 12),
          Expanded(child: income),
        ]);
      }
      return Column(children: [expenses, const SizedBox(height: 12), income]);
    });
  }
}

class CashbookPanel extends StatelessWidget {
  const CashbookPanel(
      {required this.store, required this.statement, super.key});
  final AppStore store;
  final ProfitLossStatement statement;

  @override
  Widget build(BuildContext context) {
    final rows = statement.cashbookByMethod.entries.toList();
    final cashIn = rows
        .where((entry) => entry.key.endsWith('in'))
        .fold(0, (sum, entry) => sum + entry.value);
    final cashOut = rows
        .where((entry) => entry.key.endsWith('out'))
        .fold(0, (sum, entry) => sum + entry.value);
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Cashbook',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text(
            'Tracks money entering and leaving cash, card, mobile money, and bank records.'),
        const SizedBox(height: 10),
        TotalRow(label: 'Money in', value: store.moneyFor(cashIn), bold: true),
        TotalRow(
            label: 'Money out', value: store.moneyFor(cashOut), bold: true),
        TotalRow(
            label: 'Net movement',
            value: store.moneyFor(cashIn - cashOut),
            bold: true),
        const Divider(height: 18),
        ...rows.map((entry) =>
            TotalRow(label: entry.key, value: store.moneyFor(entry.value))),
      ]),
    );
  }
}

class BalanceTrackerPanel extends StatelessWidget {
  const BalanceTrackerPanel(
      {required this.store, required this.statement, super.key});
  final AppStore store;
  final ProfitLossStatement statement;

  @override
  Widget build(BuildContext context) {
    final suppliers = statement.supplierBalances.entries
        .where((entry) => entry.value != 0)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 760;
      final supplierPanel = DecoratedPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Supplier Balances',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          const Text('Shows who the shop still owes after stock purchases.'),
          const SizedBox(height: 10),
          if (suppliers.isEmpty)
            const Text('No supplier balances in this period.')
          else
            ...suppliers.map((entry) => TotalRow(
                label: entry.key,
                value: store.moneyFor(entry.value),
                bold: entry.value > 0)),
        ]),
      );
      final debtPanel = DecoratedPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Customer Debt Aging',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          const Text('Shows how old unpaid customer balances are.'),
          const SizedBox(height: 10),
          ...statement.customerDebtAging.entries.map((entry) =>
              TotalRow(label: entry.key, value: store.moneyFor(entry.value))),
        ]),
      );
      if (wide) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: supplierPanel),
          const SizedBox(width: 12),
          Expanded(child: debtPanel),
        ]);
      }
      return Column(children: [
        supplierPanel,
        const SizedBox(height: 12),
        debtPanel,
      ]);
    });
  }
}

class PayrollPanel extends StatelessWidget {
  const PayrollPanel({required this.store, required this.entries, super.key});
  final AppStore store;
  final List<AccountingEntry> entries;

  @override
  Widget build(BuildContext context) {
    final total = entries.fold(0, (sum, entry) => sum + entry.amountCents);
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Employee Payroll / Light HR',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text(
            'Record wages, salaries, advances, deductions, roles, and pay periods. Payroll is included in profit/loss.'),
        const SizedBox(height: 10),
        TotalRow(
            label: 'Payroll in period',
            value: store.moneyFor(total),
            bold: true),
        const SizedBox(height: 8),
        if (entries.isEmpty)
          const Text('No payroll records in this period.')
        else
          ...entries.take(12).map((entry) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.badge),
                title: Text(entry.counterparty.isEmpty
                    ? entry.description
                    : entry.counterparty),
                subtitle: Text(
                    '${shortDate(entry.createdAt)} | ${entry.description} | ${entry.paymentMethod}'),
                trailing: Text(store.moneyFor(entry.amountCents),
                    style: const TextStyle(fontWeight: FontWeight.w900)),
              )),
      ]),
    );
  }
}

class BusinessHealthPanel extends StatelessWidget {
  const BusinessHealthPanel(
      {required this.store, required this.statement, super.key});
  final AppStore store;
  final ProfitLossStatement statement;

  @override
  Widget build(BuildContext context) {
    final alerts = <String>[];
    if (statement.netProfitCents < 0) {
      alerts.add('Net loss detected for this period.');
    }
    if (statement.supplierPayablesCents > 0) {
      alerts.add('Supplier balances need attention.');
    }
    if (statement.customerDebtOutstandingCents > 0) {
      alerts.add('Customer debt is outstanding.');
    }
    if (store.lowStockCount > 0) {
      alerts.add('${store.lowStockCount} products are low stock.');
    }
    if (store.outOfStockCount > 0) {
      alerts.add('${store.outOfStockCount} products are out of stock.');
    }
    final lowMargin = store.products
        .where((product) =>
            product.priceCents > 0 &&
            product.costCents > 0 &&
            ((product.priceCents - product.costCents) / product.priceCents) <
                0.15)
        .take(5)
        .map((product) => product.name)
        .toList();
    if (lowMargin.isNotEmpty) {
      alerts.add('Low margin products: ${lowMargin.join(', ')}.');
    }
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Business Health Alerts',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text(
            'Quick owner warnings from stock, profit, debt, and margins.'),
        const SizedBox(height: 10),
        if (alerts.isEmpty)
          const Text('No major alerts for this period.')
        else
          ...alerts.map((alert) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber,
                          size: 20,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(child: Text(alert)),
                    ]),
              )),
      ]),
    );
  }
}

class AccountingCategoryList extends StatelessWidget {
  const AccountingCategoryList(
      {required this.title,
      required this.empty,
      required this.values,
      required this.store,
      super.key});
  final String title;
  final String empty;
  final Map<String, int> values;
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final rows = values.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        if (rows.isEmpty) Text(empty),
        ...rows.map((entry) => TotalRow(
            label: entry.key, value: store.moneyFor(entry.value), bold: true)),
      ]),
    );
  }
}

class AccountingEntryPanel extends StatelessWidget {
  const AccountingEntryPanel(
      {required this.store, required this.statement, super.key});
  final AppStore store;
  final ProfitLossStatement statement;

  @override
  Widget build(BuildContext context) {
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Expense / Income Register',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text(
            'Record rent, wages, transport, internet, packaging, repairs, bank charges, and other non-stock accounting entries here.'),
        const SizedBox(height: 10),
        if (statement.entries.isEmpty)
          const Text('No accounting entries in this period.')
        else
          ...statement.entries.map((entry) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(entry.type == AccountingEntryType.income
                    ? Icons.add_card
                    : Icons.receipt_long),
                title: Text(entry.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(
                    '${shortDateTime(entry.createdAt)} | ${entry.typeLabel} | ${entry.category}${entry.counterparty.isEmpty ? '' : ' | ${entry.counterparty}'}'),
                trailing: Wrap(
                    spacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(store.moneyFor(entry.amountCents),
                          style: const TextStyle(fontWeight: FontWeight.w900)),
                      IconButton(
                          tooltip: 'Delete entry',
                          onPressed: () async {
                            final confirmed = await confirmDanger(
                                context,
                                'Delete accounting entry?',
                                'Remove ${entry.description}?');
                            if (confirmed)
                              await store.deleteAccountingEntry(entry);
                          },
                          icon: const Icon(Icons.delete)),
                    ]),
              )),
      ]),
    );
  }
}

class SmartInsightsPanel extends StatelessWidget {
  const SmartInsightsPanel(
      {required this.store, required this.insights, super.key});
  final AppStore store;
  final List<SmartInsight> insights;

  @override
  Widget build(BuildContext context) {
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.auto_awesome,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Smart Business Insights',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          ),
        ]),
        const SizedBox(height: 6),
        const Text(
            'Careful suggestions from real shop data. Review before acting.'),
        const SizedBox(height: 12),
        if (insights.isEmpty)
          const Text('No major insights for this period.')
        else
          LayoutBuilder(builder: (context, constraints) {
            final wide = constraints.maxWidth >= 760;
            final width =
                wide ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: insights
                  .map((insight) => SizedBox(
                      width: width, child: SmartInsightCard(insight: insight)))
                  .toList(),
            );
          }),
      ]),
    );
  }
}

class SmartInsightCard extends StatelessWidget {
  const SmartInsightCard({required this.insight, super.key});
  final SmartInsight insight;

  @override
  Widget build(BuildContext context) {
    final color = switch (insight.tone) {
      Tone.good => const Color(0xFF168354),
      Tone.warning => const Color(0xFF9A6700),
      Tone.danger => const Color(0xFFB3261E),
      _ => Theme.of(context).colorScheme.primary,
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(insight.icon, color: color),
        const SizedBox(width: 10),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(insight.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text(insight.body,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ]),
        ),
      ]),
    );
  }
}

class MetricGrid extends StatelessWidget {
  const MetricGrid({required this.store, required this.report, super.key});
  final AppStore store;
  final ReportSnapshot report;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final periodLabel = report.title.startsWith('Weekly')
        ? 'Weekly'
        : report.title.startsWith('Monthly')
            ? 'Monthly'
            : report.title.startsWith('Yearly')
                ? 'Yearly'
                : 'Daily';
    final cardWidth = width >= 1180
        ? (width - 72) / 4
        : width >= 360
            ? (width - 52) / 2
            : width - 32;
    final cards = [
      MetricCard(
          label: '$periodLabel sales',
          value: store.moneyFor(report.totalSalesCents),
          icon: Icons.payments),
      MetricCard(
          label: '$periodLabel transactions',
          value: '${report.transactionCount}',
          icon: Icons.receipt_long),
      MetricCard(
          label: '$periodLabel debt',
          value: store.moneyFor(report.debtCents),
          icon: Icons.account_balance_wallet),
      MetricCard(
          label: '$periodLabel gross profit',
          value: store.moneyFor(report.grossProfitCents),
          icon: Icons.trending_up),
      MetricCard(
          label: '$periodLabel margin',
          value: '${report.grossMarginPercent.toStringAsFixed(1)}%',
          icon: Icons.percent),
      MetricCard(
          label: '$periodLabel average sale',
          value: store.moneyFor(report.averageSaleCents),
          icon: Icons.inventory_2),
      if (store.fiscalMode)
        MetricCard(
            label: 'Fiscal day',
            value:
                store.fiscalDayOpen ? '#${store.fiscalDayNo} open' : 'Closed',
            icon: Icons.receipt_long),
    ];
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: cards
          .map((card) => SizedBox(width: cardWidth, height: 86, child: card))
          .toList(),
    );
  }
}

class ReportBreakdown extends StatelessWidget {
  const ReportBreakdown({required this.store, required this.report, super.key});
  final AppStore store;
  final ReportSnapshot report;

  @override
  Widget build(BuildContext context) {
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Sales Breakdown',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 10),
        TotalRow(
            label: 'Gross recorded sales',
            value: store.moneyFor(report.grossSalesCents),
            bold: true),
        TotalRow(
            label: 'Voids / returns',
            value: store.moneyFor(report.voidedCents)),
        TotalRow(
            label: 'Net sales',
            value: store.moneyFor(report.totalSalesCents),
            bold: true),
        TotalRow(
            label: 'Discounts', value: store.moneyFor(report.discountCents)),
        const Divider(height: 20),
        const Text('Profit / Loss',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        TotalRow(
            label: 'Cost of goods sold',
            value: store.moneyFor(report.costOfGoodsCents)),
        TotalRow(
            label: 'Gross profit',
            value: store.moneyFor(report.grossProfitCents),
            bold: true),
        TotalRow(
            label: 'Gross margin',
            value: '${report.grossMarginPercent.toStringAsFixed(1)}%',
            bold: true),
        TotalRow(
            label: 'Stock value at cost',
            value: store.moneyFor(report.stockValueAtCostCents)),
        TotalRow(
            label: 'Stock value at selling price',
            value: store.moneyFor(report.stockValueAtRetailCents)),
        TotalRow(
            label: 'Potential stock profit',
            value: store.moneyFor(report.potentialStockProfitCents)),
        const Divider(height: 20),
        const Text('Payment Mix',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        TotalRow(label: 'Cash', value: store.moneyFor(report.cashCents)),
        TotalRow(label: 'Card', value: store.moneyFor(report.cardCents)),
        TotalRow(
            label: 'Mobile money',
            value: store.moneyFor(report.mobileMoneyCents)),
        TotalRow(
            label: 'Debt created', value: store.moneyFor(report.debtCents)),
        const SizedBox(height: 12),
        SizedBox(
          height: 130,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ReportBar(
                  label: 'Cash',
                  cents: report.cashCents,
                  maxCents: report.totalSalesCents),
              ReportBar(
                  label: 'Card',
                  cents: report.cardCents,
                  maxCents: report.totalSalesCents),
              ReportBar(
                  label: 'Mobile',
                  cents: report.mobileMoneyCents,
                  maxCents: report.totalSalesCents),
              ReportBar(
                  label: 'Debt',
                  cents: report.debtCents,
                  maxCents: report.totalSalesCents),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Text(
            'Profit is calculated from the buying cost saved on each product at the time of sale. Add buying cost in Stock for accurate P/L.',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class ReportBar extends StatelessWidget {
  const ReportBar(
      {required this.label,
      required this.cents,
      required this.maxCents,
      super.key});
  final String label;
  final int cents;
  final int maxCents;

  @override
  Widget build(BuildContext context) {
    final ratio = maxCents <= 0 ? 0.0 : (cents / maxCents).clamp(0.0, 1.0);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
          Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: max(0.06, ratio),
                widthFactor: 0.75,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(6)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall),
        ]),
      ),
    );
  }
}

class UserPerformancePanel extends StatelessWidget {
  const UserPerformancePanel(
      {required this.store, required this.report, super.key});
  final AppStore store;
  final ReportSnapshot report;

  @override
  Widget build(BuildContext context) {
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('User Performance',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text(
            'Tracks each cashier/operator for the selected daily, weekly, or monthly report period.'),
        const SizedBox(height: 10),
        if (report.userPerformance.isEmpty)
          const Text('No user sales recorded in this period.')
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingTextStyle: const TextStyle(fontWeight: FontWeight.w900),
              columns: const [
                DataColumn(label: Text('User')),
                DataColumn(label: Text('Sales')),
                DataColumn(label: Text('Gross')),
                DataColumn(label: Text('Voided')),
                DataColumn(label: Text('Net')),
                DataColumn(label: Text('Cost')),
                DataColumn(label: Text('Profit')),
                DataColumn(label: Text('Debt')),
              ],
              rows: report.userPerformance
                  .map((user) => DataRow(cells: [
                        DataCell(Text(user.userName)),
                        DataCell(Text('${user.transactionCount}')),
                        DataCell(Text(store.moneyFor(user.grossCents))),
                        DataCell(Text(store.moneyFor(user.voidedCents))),
                        DataCell(Text(store.moneyFor(user.netCents))),
                        DataCell(Text(store.moneyFor(user.costCents))),
                        DataCell(Text(store.moneyFor(user.profitCents))),
                        DataCell(Text(store.moneyFor(user.debtCents))),
                      ]))
                  .toList(),
            ),
          ),
      ]),
    );
  }
}

class ProductPerformancePanel extends StatelessWidget {
  const ProductPerformancePanel(
      {required this.store, required this.report, super.key});
  final AppStore store;
  final ReportSnapshot report;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 760;
      final top = PerformanceList(
          title: 'High Performing Stock',
          empty: 'No sold products in this period yet.',
          items: report.topProducts,
          store: store);
      final slow = PerformanceList(
          title: 'Slow Moving Stock',
          empty: 'No slow moving products detected.',
          items: report.slowProducts,
          store: store,
          slowMode: true);
      if (wide) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: top),
          const SizedBox(width: 12),
          Expanded(child: slow),
        ]);
      }
      return Column(children: [top, const SizedBox(height: 12), slow]);
    });
  }
}

class TransactionDetailPanel extends StatelessWidget {
  const TransactionDetailPanel(
      {required this.store, required this.report, super.key});
  final AppStore store;
  final ReportSnapshot report;

  @override
  Widget build(BuildContext context) {
    final transactions = report.sales.take(40).toList();
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Transaction Details',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text(
            'Shows time, operator, payment method, items, quantities, sales value, cost, and profit for the selected period.'),
        const SizedBox(height: 10),
        if (transactions.isEmpty)
          const Text('No transactions in this period.')
        else
          ...transactions.map((sale) {
            final lineCost =
                sale.lines.fold(0, (sum, line) => sum + line.lineCostCents);
            final lineProfit = sale.totalCents - lineCost;
            return Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(spacing: 10, runSpacing: 6, children: [
                        Text(shortDateTime(sale.createdAt),
                            style:
                                const TextStyle(fontWeight: FontWeight.w900)),
                        Text('Branch: ${store.branchNameForId(sale.branchId)}'),
                        Text('User: ${sale.cashier}'),
                        Text('Payment: ${sale.paymentMethod}'),
                        if (sale.customerName.isNotEmpty)
                          Text('Customer: ${sale.customerName}'),
                      ]),
                      const SizedBox(height: 8),
                      ...sale.lines.map((line) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                                '${store.saleLineDisplayName(line)} | Qty ${line.quantity} | Sales ${store.moneyFor(line.lineTotalCents)} | Cost ${store.moneyFor(line.lineCostCents)}'),
                          )),
                      const Divider(),
                      Wrap(spacing: 14, runSpacing: 6, children: [
                        Text('Net ${store.moneyFor(sale.totalCents)}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w900)),
                        Text('Cost ${store.moneyFor(lineCost)}'),
                        Text('Profit ${store.moneyFor(lineProfit)}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w900)),
                      ]),
                    ]),
              ),
            );
          }),
        if (report.sales.length > transactions.length)
          Text(
              'Showing latest ${transactions.length} transactions here. Export PDF for more details.',
              style: const TextStyle(fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class PerformanceList extends StatelessWidget {
  const PerformanceList(
      {required this.title,
      required this.empty,
      required this.items,
      required this.store,
      this.slowMode = false,
      super.key});
  final String title;
  final String empty;
  final List<ReportProductPerformance> items;
  final AppStore store;
  final bool slowMode;

  @override
  Widget build(BuildContext context) {
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        if (items.isEmpty) Text(empty),
        ...items.map((item) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading:
                  Icon(slowMode ? Icons.hourglass_bottom : Icons.trending_up),
              title: Text(item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(slowMode
                  ? 'No sales in selected period'
                  : '${item.quantity} sold${item.branchName.isEmpty ? '' : ' | ${item.branchName}'} | Profit ${store.moneyFor(item.profitCents)}'),
              trailing: Text(slowMode ? '-' : store.moneyFor(item.revenueCents),
                  style: const TextStyle(fontWeight: FontWeight.w900)),
            )),
      ]),
    );
  }
}

class BackupPanel extends StatelessWidget {
  const BackupPanel({required this.store, super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Recovery and Safekeeping',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        const Text(
            'Save a recovery file and owner recovery summary for support. Business reports are exported from Report Controls or the Profit section. Cloud sync remains the live shared database.'),
        const SizedBox(height: 8),
        SelectableText(
          'Owner recovery code: ${store.recoveryCode.isEmpty ? 'Sync once to generate' : store.recoveryCode}',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
              onPressed: () async {
                final file = await store.createJsonBackupFile();
                if (context.mounted)
                  showMessage(context, 'Recovery file saved: ${file.path}');
              },
              icon: const Icon(Icons.save),
              label: const Text('Save Recovery File')),
          OutlinedButton.icon(
              onPressed: () async {
                await ReceiptOutputService.sharePdf(store.backupText(),
                    filename: 'light-winter-recovery-summary.pdf',
                    brandedReport: true);
              },
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('Recovery Summary PDF')),
          OutlinedButton.icon(
              onPressed: () async {
                await launchUrl(
                    Uri.parse(
                        'mailto:?subject=${Uri.encodeComponent('Light Winter Recovery Summary')}&body=${Uri.encodeComponent(store.backupText())}'),
                    mode: LaunchMode.externalApplication);
              },
              icon: const Icon(Icons.email),
              label: const Text('Email Recovery Summary')),
        ]),
      ]),
    );
  }
}

class PosPage extends StatefulWidget {
  const PosPage({required this.store, super.key});
  final AppStore store;
  @override
  State<PosPage> createState() => _PosPageState();
}

class _PosPageState extends State<PosPage> {
  String query = '';
  final searchController = TextEditingController();

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  String _scanKey(String value) =>
      value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  void _autoAddScannedCode(String value, List<Product> searchScope) {
    final clean = _scanKey(value);
    if (clean.isEmpty) return;
    final store = widget.store;
    final exactMatches = searchScope.where((product) {
      final available =
          product.isCustom ? 999999 : store.sellableQuantityFor(product);
      if (available <= 0) return false;
      return _scanKey(product.barcode) == clean ||
          _scanKey(product.sku) == clean;
    }).toList();
    if (exactMatches.length == 1) {
      store.addToCart(exactMatches.first);
      SystemSound.play(SystemSoundType.click);
      setState(() => query = '');
      searchController.clear();
    } else if (exactMatches.length > 1) {
      showMessage(context, 'Multiple items use this barcode/SKU.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final searchScope = store.allowCatalogueWideSale
        ? store.activeCatalogueProducts
        : store.currentBranchAssignedProducts;
    final products = searchScope.where((product) {
      final q = query.toLowerCase();
      final available =
          product.isCustom ? 999999 : store.sellableQuantityFor(product);
      final matchesQuery = product.name.toLowerCase().contains(q) ||
          product.sku.toLowerCase().contains(q) ||
          product.barcode.contains(q);
      return matchesQuery && available > 0;
    }).toList();
    final hasSearch = query.trim().isNotEmpty;
    final visibleProducts = hasSearch ? products : products.take(2).toList();
    final wide = MediaQuery.sizeOf(context).width >= 980;
    final productPanel = DecoratedPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Product Search',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          TextField(
            controller: searchController,
            onChanged: (value) => setState(() => query = value),
            onSubmitted: (value) => _autoAddScannedCode(value, searchScope),
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Search product or SKU',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final value = await showManualTextPad(context,
                  title: 'Type Product / SKU / Barcode',
                  initialValue: query,
                  allowLetters: true);
              if (value == null) return;
              setState(() => query = value);
              searchController.text = value;
            },
            icon: const Icon(Icons.keyboard),
            label: const Text('Type Manually'),
          ),
          const SizedBox(height: 12),
          Text(
              hasSearch
                  ? 'Showing all ${visibleProducts.length} matching products'
                  : 'Showing ${visibleProducts.length} of ${products.length} matching products',
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: visibleProducts
                .map((product) => QuickProduct(
                    product: product,
                    stockQuantity: store.sellableQuantityFor(product),
                    stockLabel: store.allowCatalogueWideSale
                        ? 'catalogue stock'
                        : 'branch stock',
                    moneyText: store.moneyFor(product.priceCents,
                        currency: store.posCurrency),
                    onTap: () => store.addToCart(product)))
                .toList(),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => showCustomItemDialog(context, store),
            icon: const Icon(Icons.add_box),
            label: const Text('Add Custom Item'),
          ),
        ],
      ),
    );
    final cartPanel = DecoratedPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Active Cart',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
              ),
              DropdownButton<String>(
                value: store.activeCartName,
                items: store.openCartNames
                    .map((name) =>
                        DropdownMenuItem(value: name, child: Text(name)))
                    .toList(),
                onChanged: (value) {
                  if (value != null) store.switchOpenCart(value);
                },
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                  onPressed: store.createOpenCart,
                  icon: const Icon(Icons.person_add),
                  label: const Text('New Customer')),
              OutlinedButton.icon(
                  onPressed: store.openCartNames.length <= 1
                      ? null
                      : () => store.closeOpenCart(store.activeCartName),
                  icon: const Icon(Icons.close),
                  label: const Text('Close Cart')),
            ],
          ),
          const SizedBox(height: 8),
          if (store.cart.isEmpty)
            const Text('Cart is empty. Add products from the left.'),
          ...store.cart.map((item) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(item.product.name,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(item.product.isCustom
                    ? 'Custom item'
                    : '${store.sellableQuantityFor(item.product)} ${store.allowCatalogueWideSale ? 'catalogue stock' : 'branch stock'}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      onPressed: () => store.decrementCartItem(item),
                      icon: const Icon(Icons.remove_circle_outline),
                      tooltip: 'Subtract one'),
                  InkWell(
                    onTap: () => showCartQuantityDialog(context, store, item),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text('${item.quantity}',
                          style: const TextStyle(fontWeight: FontWeight.w900)),
                    ),
                  ),
                  IconButton(
                      onPressed: () => store.incrementCartItem(item),
                      icon: const Icon(Icons.add_circle_outline),
                      tooltip: 'Add one'),
                  Text(
                      store.moneyFor(item.product.priceCents * item.quantity,
                          currency: store.posCurrency),
                      style: const TextStyle(fontWeight: FontWeight.w900)),
                  IconButton(
                      onPressed: () => store.removeFromCart(item),
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Remove line'),
                ]),
              )),
          const Divider(),
          TotalRow(
              label: 'Total',
              value: store.moneyFor(store.cartTotalCents,
                  currency: store.posCurrency),
              bold: true),
          Wrap(
            spacing: 8,
            children: ['USD', 'ZWL', 'ZAR', 'BWP']
                .map((code) => ChoiceChip(
                      label: Text(code),
                      selected: store.posCurrency == code,
                      onSelected: (_) => store.setPosCurrency(code),
                    ))
                .toList(),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: store.cart.isEmpty ? null : _checkout,
            icon: const Icon(Icons.check_circle),
            label: const Text('Checkout and Record Payment'),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(20),
      child: wide
          ? Row(children: [
              Expanded(flex: 3, child: productPanel),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: cartPanel)
            ])
          : ListView(
              children: [productPanel, const SizedBox(height: 16), cartPanel]),
    );
  }

  Future<void> _checkout() async {
    final sale = await showCheckoutDialog(context, widget.store);
    if (sale == null) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Sale recorded. Okae.')));
    await showReceiptActionsDialog(context, widget.store, sale);
  }
}

class InventoryPage extends StatefulWidget {
  const InventoryPage({required this.store, super.key});
  final AppStore store;

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  String query = '';
  String status = 'all';
  bool showingSuppliers = false;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_refreshFromStore);
  }

  @override
  void didUpdateWidget(covariant InventoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store == widget.store) return;
    oldWidget.store.removeListener(_refreshFromStore);
    widget.store.addListener(_refreshFromStore);
  }

  @override
  void dispose() {
    widget.store.removeListener(_refreshFromStore);
    super.dispose();
  }

  void _refreshFromStore() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final stockScope = store.branchScopedProducts;
    final suppliersScope = store.branchScopedSuppliers;
    final selectedProducts = stockScope.length;
    final selectedUnits = store.stockViewTotalUnits;
    final branchUnits = store.currentBranchTotalUnits;
    final allUnits = store.allBranchesTotalUnits;
    final selectedCategories = store.stockViewCategoryCount;
    final selectedLow = store.lowStockCount;
    final selectedOut = store.outOfStockCount;
    final selectedSuppliers = suppliersScope.length;
    final filtered = stockScope.where((product) {
      final q = query.trim().toLowerCase();
      final supplier = supplierName(store, product.supplierId).toLowerCase();
      final quantity = store.stockViewQuantityFor(product);
      final matchesQuery = q.isEmpty ||
          product.name.toLowerCase().contains(q) ||
          product.category.toLowerCase().contains(q) ||
          product.sku.toLowerCase().contains(q) ||
          product.barcode.toLowerCase().contains(q) ||
          supplier.contains(q);
      final matchesStatus = status == 'all' ||
          (status == 'low' &&
              quantity > 0 &&
              quantity <= product.reorderLevel) ||
          (status == 'out' && quantity <= 0);
      return matchesQuery && matchesStatus;
    }).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final compact = MediaQuery.sizeOf(context).width < 620;

    final summaryCards = [
      ShortcutTile(
          key: ValueKey('products-$selectedProducts-$branchUnits-$allUnits'),
          icon: Icons.inventory_2,
          title: 'Shown products',
          value: '$selectedProducts',
          selected: !showingSuppliers && status == 'all',
          onTap: () => setState(() {
                showingSuppliers = false;
                status = 'all';
                query = '';
              })),
      ShortcutTile(
          key: ValueKey('selected-units-$selectedUnits-$branchUnits-$allUnits'),
          icon: Icons.warehouse,
          title: 'Shown pieces',
          value: '$selectedUnits',
          selected: false,
          onTap: () => showMessage(context,
              'Total individual stock quantity in the selected stock view.')),
      ShortcutTile(
          key: ValueKey('branch-units-$branchUnits'),
          icon: Icons.storefront,
          title: 'Branch pieces',
          value: '$branchUnits',
          selected: false,
          onTap: () => showMessage(context,
              'Pieces currently assigned to ${store.currentBranch?.name ?? 'this branch'}.')),
      ShortcutTile(
          key: ValueKey('all-units-$allUnits'),
          icon: Icons.account_tree,
          title: 'All pieces',
          value: '$allUnits',
          selected: false,
          onTap: () => showMessage(context,
              'Pieces across every branch in this shop. Transfers between branches do not change this total.')),
      ShortcutTile(
          key: ValueKey('categories-$selectedCategories-$selectedProducts'),
          icon: Icons.category,
          title: 'Categories',
          value: '$selectedCategories',
          selected: false,
          onTap: () => showCategorySummaryDialog(context, store)),
      ShortcutTile(
          key: ValueKey('low-$selectedLow-$selectedUnits'),
          icon: Icons.warning,
          title: 'Low stock',
          value: '$selectedLow',
          selected: !showingSuppliers && status == 'low',
          onTap: () => setState(() {
                showingSuppliers = false;
                status = 'low';
              })),
      ShortcutTile(
          key: ValueKey('out-$selectedOut-$selectedUnits'),
          icon: Icons.remove_shopping_cart,
          title: 'Out of stock',
          value: '$selectedOut',
          selected: !showingSuppliers && status == 'out',
          onTap: () => setState(() {
                showingSuppliers = false;
                status = 'out';
              })),
      ShortcutTile(
          key: ValueKey('suppliers-$selectedSuppliers-$selectedProducts'),
          icon: Icons.local_shipping,
          title: 'Suppliers',
          value: '$selectedSuppliers',
          selected: showingSuppliers,
          onTap: () => setState(() => showingSuppliers = true)),
    ];

    return PageFrame(
      title: 'Stock Control',
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            OutlinedButton.icon(
                onPressed: () => showSupplierDialog(context, store),
                icon: const Icon(Icons.local_shipping),
                label: const Text('Supplier')),
            const SizedBox(width: 8),
            OutlinedButton.icon(
                onPressed: () => importProductCsv(context, store),
                icon: const Icon(Icons.upload_file),
                label: Text(compact ? 'Import' : 'Import CSV')),
            const SizedBox(width: 8),
            OutlinedButton.icon(
                onPressed: () => showStockExportDialog(context, store),
                icon: const Icon(Icons.ios_share),
                label: const Text('Export')),
            const SizedBox(width: 8),
            FilledButton.icon(
                onPressed: () => showProductDialog(context, store),
                icon: const Icon(Icons.add),
                label: const Text('Product')),
            const SizedBox(width: 8),
            OutlinedButton.icon(
                onPressed: () => showStockBulkDeleteDialog(context, store),
                icon: const Icon(Icons.delete_sweep),
                label: const Text('Delete')),
          ]),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 12, runSpacing: 12, children: summaryCards),
        const SizedBox(height: 12),
        BatchExpiryPanel(store: store),
        const SizedBox(height: 12),
        if (!showingSuppliers) ...[
          BranchCatalogueToggle(
            branchName: store.currentBranch?.name ?? 'Current branch',
            branchStockOnly: !store.catalogueWideViewEnabled,
            canToggle: store.canUseCentralCatalogueMode,
            onChanged: (value) async {
              await store.setCatalogueVisibilityMode(!value);
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 12),
          DecoratedPanel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'Search stock',
                    helperText: 'Product, category, SKU, barcode, or supplier',
                    border: OutlineInputBorder()),
                onChanged: (value) => setState(() => query = value),
              ),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'all',
                        icon: Icon(Icons.list_alt),
                        label: Text('All')),
                    ButtonSegment(
                        value: 'low',
                        icon: Icon(Icons.warning),
                        label: Text('Low')),
                    ButtonSegment(
                        value: 'out',
                        icon: Icon(Icons.remove_shopping_cart),
                        label: Text('Out')),
                  ],
                  selected: {status},
                  onSelectionChanged: (value) =>
                      setState(() => status = value.first),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          if (filtered.isEmpty)
            const InfoPanel(
                icon: Icons.inventory,
                title: 'No matching products',
                body: 'Add products manually or import a CSV stock list.'),
          ...filtered.map((product) => ProductStockCard(
                store: store,
                product: product,
                supplier: supplierName(store, product.supplierId),
                stockQuantity: store.stockViewQuantityFor(product),
                showingCatalogueStock: store.catalogueWideViewEnabled,
              )),
        ] else
          SupplierPanel(store: store, suppliers: suppliersScope),
      ],
    );
  }
}

class BatchExpiryPanel extends StatelessWidget {
  const BatchExpiryPanel({required this.store, super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final records = store.nearExpiryRecords();
    final allRecords = store.batchExpiryRecords;
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Batch and Expiry Tracking',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text(
            'For food and pharmacy stock: enter batch and expiry when receiving stock. Average-cost valuation updates automatically.'),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          AccountingChip(
              icon: Icons.inventory_2,
              label: 'Average-cost stock',
              value: store.moneyFor(store.stockValueAtAverageCostCents)),
          AccountingChip(
              icon: Icons.layers,
              label: 'FIFO layer value',
              value: store.moneyFor(store.stockValueAtFifoCostCents)),
          AccountingChip(
              icon: Icons.event_busy,
              label: 'Near / expired batches',
              value: '${records.length}'),
          AccountingChip(
              icon: Icons.layers,
              label: 'FIFO batch logs',
              value: '${allRecords.length}'),
        ]),
        const SizedBox(height: 10),
        if (allRecords.isEmpty)
          const Text('No batch or expiry records yet.')
        else if (records.isEmpty)
          const Text('No batches expiring in the next 45 days.')
        else
          ...records.take(8).map((record) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                    record.expired ? Icons.dangerous : Icons.warning_amber),
                title: Text(record.productName,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(
                    'Batch ${record.batchNumber.isEmpty ? '-' : record.batchNumber} | Qty ${record.quantity} | Expiry ${shortDate(record.expiryDate)}'),
                trailing: Text(
                    record.expired ? 'Expired' : '${record.daysLeft}d left'),
              )),
      ]),
    );
  }
}

class ShortcutTile extends StatelessWidget {
  const ShortcutTile(
      {required this.icon,
      required this.title,
      required this.value,
      required this.onTap,
      this.selected = false,
      super.key});
  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.outline;
    return SizedBox(
      width: MediaQuery.sizeOf(context).width < 620 ? 142 : 190,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
                : Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, color: color),
              const SizedBox(height: 8),
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(value,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w900)),
            ]),
          ),
        ),
      ),
    );
  }
}

class BranchCatalogueToggle extends StatelessWidget {
  const BranchCatalogueToggle(
      {required this.branchName,
      required this.branchStockOnly,
      required this.canToggle,
      required this.onChanged,
      super.key});
  final String branchName;
  final bool branchStockOnly;
  final bool canToggle;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Product Visibility',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 8),
        Text(
            'Catalogue is central. Stock quantities are per branch. Choose what this screen should show for $branchName.'),
        const SizedBox(height: 12),
        Column(children: [
          StockScopeChoice(
            selected: branchStockOnly,
            enabled: true,
            icon: Icons.storefront,
            title: 'This branch only',
            body: 'Show stock assigned to $branchName.',
            onTap: () => onChanged(true),
          ),
          const SizedBox(height: 8),
          StockScopeChoice(
            selected: !branchStockOnly,
            enabled: canToggle,
            icon: Icons.account_tree,
            title: 'All branches stock',
            body:
                'Show combined stock from every branch in this shop: main, Borrowdale, Karigamombe, and any future branch.',
            onTap: () => onChanged(false),
          ),
        ]),
        const SizedBox(height: 8),
        Text(
          !canToggle
              ? 'This user is locked to this branch stock only. The central catalogue toggle requires owner or stock/branch privileges.'
              : branchStockOnly
                  ? 'Showing only products with quantity in this branch.'
                  : 'Showing central products with stock totals combined across all branches.',
          style: TextStyle(
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.primary),
        ),
      ]),
    );
  }
}

class StockScopeChoice extends StatelessWidget {
  const StockScopeChoice({
    required this.selected,
    required this.enabled,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
    super.key,
  });
  final bool selected;
  final bool enabled;
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.outline;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: enabled ? onTap : null,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon,
                color: enabled ? color : Theme.of(context).disabledColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: enabled
                                ? null
                                : Theme.of(context).disabledColor,
                            fontWeight: FontWeight.w900)),
                    const SizedBox(height: 2),
                    Text(body,
                        style: Theme.of(context).textTheme.bodySmall,
                        softWrap: true),
                  ]),
            ),
            Radio<bool>(
              value: true,
              groupValue: selected,
              onChanged: enabled ? (_) => onTap() : null,
            ),
          ]),
        ),
      ),
    );
  }
}

class ProductStockCard extends StatelessWidget {
  const ProductStockCard(
      {required this.store,
      required this.product,
      required this.supplier,
      required this.stockQuantity,
      required this.showingCatalogueStock,
      super.key});
  final AppStore store;
  final Product product;
  final String supplier;
  final int stockQuantity;
  final bool showingCatalogueStock;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 620;
    final color = stockQuantity <= 0
        ? const Color(0xFFB3261E)
        : stockQuantity <= product.reorderLevel
            ? const Color(0xFF9A6B00)
            : const Color(0xFF168354);
    final status = stockQuantity <= 0
        ? 'Out of stock'
        : stockQuantity <= product.reorderLevel
            ? 'Low stock'
            : 'OK';
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: compact ? double.infinity : 260,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(product.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (product.category.isNotEmpty) product.category,
                          if (product.sku.isNotEmpty) 'SKU ${product.sku}',
                          if (supplier.isNotEmpty) supplier,
                        ].join(' | '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ]),
              ),
              Chip(
                side: BorderSide(color: color.withValues(alpha: 0.35)),
                backgroundColor: color.withValues(alpha: 0.08),
                label: Text(status,
                    style:
                        TextStyle(color: color, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 16, runSpacing: 8, children: [
            Text('Cost: ${store.moneyFor(product.costCents)}',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            Text('Price: ${store.moneyFor(product.priceCents)}',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            Text(
                'Unit profit: ${store.moneyFor(product.priceCents - product.costCents)}',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            Text(
                showingCatalogueStock
                    ? 'Catalogue stock: $stockQuantity'
                    : 'Branch stock: $stockQuantity',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            if (showingCatalogueStock) Text('This branch: ${product.stock}'),
            Text('Low threshold: ${product.reorderLevel}'),
            if (product.barcode.isNotEmpty) Text('Barcode: ${product.barcode}'),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            SizedBox.square(
              dimension: 44,
              child: IconButton.outlined(
                  tooltip: 'Reduce stock',
                  onPressed: () => store.adjustStock(product, -1),
                  icon: const Icon(Icons.remove)),
            ),
            SizedBox.square(
              dimension: 44,
              child: IconButton.filled(
                  tooltip: 'Add stock',
                  onPressed: () => store.adjustStock(product, 1),
                  icon: const Icon(Icons.add)),
            ),
            OutlinedButton.icon(
                onPressed: () =>
                    showProductDialog(context, store, product: product),
                icon: const Icon(Icons.edit),
                label: const Text('Edit')),
            OutlinedButton.icon(
                onPressed: () async {
                  final confirmed = await confirmDanger(
                      context,
                      'Delete product?',
                      'Delete ${product.name}? This removes it from stock and any open carts on this device.');
                  if (confirmed) await store.deleteProduct(product);
                },
                icon: const Icon(Icons.delete),
                label: const Text('Delete')),
          ]),
        ]),
      ),
    );
  }
}

class SupplierPanel extends StatelessWidget {
  const SupplierPanel(
      {required this.store, required this.suppliers, super.key});
  final AppStore store;
  final List<Supplier> suppliers;

  @override
  Widget build(BuildContext context) {
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
              child: Text('Suppliers',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
          FilledButton.tonalIcon(
              onPressed: () => showSupplierDialog(context, store),
              icon: const Icon(Icons.add_business),
              label: const Text('Add')),
        ]),
        const SizedBox(height: 8),
        if (suppliers.isEmpty)
          const Text(
              'No suppliers saved yet. Products can still be added without a supplier.'),
        ...suppliers.map((supplier) {
          final linked = store.branchScopedProducts
              .where((product) => product.supplierId == supplier.id)
              .length;
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Icon(Icons.local_shipping),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(supplier.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      Text(
                        [
                          if (supplier.phone.isNotEmpty) supplier.phone,
                          '$linked linked product${linked == 1 ? '' : 's'}',
                          if (supplier.notes.isNotEmpty) supplier.notes,
                        ].join(' | '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ]),
              ),
              IconButton(
                  tooltip: 'Edit supplier',
                  onPressed: () =>
                      showSupplierDialog(context, store, supplier: supplier),
                  icon: const Icon(Icons.edit)),
              IconButton(
                  tooltip: 'Delete supplier',
                  onPressed: () async {
                    final confirmed = await confirmDanger(
                        context,
                        'Delete supplier?',
                        'Delete ${supplier.name}? Linked products will remain, but their supplier link will be cleared.');
                    if (confirmed) await store.deleteSupplier(supplier);
                  },
                  icon: const Icon(Icons.delete)),
            ]),
          );
        }),
      ]),
    );
  }
}

class CustomerDebtPage extends StatefulWidget {
  const CustomerDebtPage({required this.store, super.key});
  final AppStore store;

  @override
  State<CustomerDebtPage> createState() => _CustomerDebtPageState();
}

class _CustomerDebtPageState extends State<CustomerDebtPage> {
  String customerSearch = '';
  DateTime? customerDateFilter;
  String debtSearch = '';
  DateTime? debtDateFilter;
  String debtStatusFilter = 'All';
  String voidSearch = '';
  DateTime? voidDateFilter;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final filteredCustomers = store.customers.where((customer) {
      final history = store.salesForCustomer(customer);
      if (customerDateFilter != null &&
          !history.any(
              (sale) => sameLocalDay(sale.createdAt, customerDateFilter!))) {
        return false;
      }
      final q = customerSearch.trim().toLowerCase();
      if (q.isEmpty) return true;
      return customer.code.toLowerCase().contains(q) ||
          customer.name.toLowerCase().contains(q) ||
          customer.phone.toLowerCase().contains(q);
    }).toList();
    final filteredDebts = widget.store.allKnownDebtSales.where((sale) {
      if (debtDateFilter != null &&
          !sameLocalDay(sale.createdAt, debtDateFilter!)) {
        return false;
      }
      final status = widget.store.debtStatusForSale(sale);
      if (debtStatusFilter != 'All' && status != debtStatusFilter) {
        return false;
      }
      final q = debtSearch.trim().toLowerCase();
      if (q.isEmpty) return true;
      return sale.id.toLowerCase().contains(q) ||
          sale.customerName.toLowerCase().contains(q) ||
          sale.cashier.toLowerCase().contains(q) ||
          widget.store.branchNameForId(sale.branchId).toLowerCase().contains(q);
    }).toList();
    return PageFrame(
      title: 'Customers and Debt',
      trailing: FilledButton.icon(
          onPressed: () => showCustomerDialog(context, widget.store),
          icon: const Icon(Icons.person_add),
          label: const Text('Customer')),
      children: [
        DecoratedPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Customer Codes',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            const Text(
                'Each customer gets a short code. Search by code, name, phone, or sale date.'),
            const SizedBox(height: 10),
            TextField(
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  labelText: 'Search customer code, name, or phone',
                  border: OutlineInputBorder()),
              onChanged: (value) => setState(() => customerSearch = value),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await showDatePicker(
                        context: context,
                        initialDate: customerDateFilter ?? DateTime.now(),
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 1)));
                    setState(() => customerDateFilter = picked);
                  },
                  icon: const Icon(Icons.calendar_month),
                  label: Text(customerDateFilter == null
                      ? 'Search by Date'
                      : shortDate(customerDateFilter!))),
              if (customerDateFilter != null)
                TextButton.icon(
                    onPressed: () => setState(() => customerDateFilter = null),
                    icon: const Icon(Icons.close),
                    label: const Text('Clear Date')),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        DataStrip(
            headers: const ['Code', 'Customer', 'Phone', 'Last Sale'],
            rows: filteredCustomers.map((c) {
              final history = store.salesForCustomer(c);
              return [
                c.code,
                c.name,
                c.phone,
                history.isEmpty ? '-' : shortDate(history.first.createdAt)
              ];
            }).toList()),
        const SizedBox(height: 12),
        DebtLedgerPanel(
          store: widget.store,
          debts: filteredDebts,
          query: debtSearch,
          selectedDate: debtDateFilter,
          statusFilter: debtStatusFilter,
          onQueryChanged: (value) => setState(() => debtSearch = value),
          onDateChanged: (value) => setState(() => debtDateFilter = value),
          onStatusChanged: (value) => setState(() => debtStatusFilter = value),
        ),
        const SizedBox(height: 12),
        DecoratedPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Customer Statements',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            const Text(
                'Send a customer debt statement showing sale date, paid amount, remaining balance, and payment status.'),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: widget.store.allKnownDebtSales.isEmpty
                      ? null
                      : () =>
                          showCustomerStatementDialog(context, widget.store),
                  icon: const Icon(Icons.description),
                  label: const Text('Debt Statement PDF')),
              OutlinedButton.icon(
                  onPressed: filteredDebts.isEmpty
                      ? null
                      : () => ReceiptOutputService.sharePdf(
                          widget.store.debtLedgerText(filteredDebts),
                          filename: 'light-winter-debt-ledger.pdf',
                          brandedReport: true),
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('Ledger PDF / WhatsApp')),
              OutlinedButton.icon(
                  onPressed: widget.store.customers.isEmpty
                      ? null
                      : () => showCustomerHistoryDialog(context, widget.store),
                  icon: const Icon(Icons.history),
                  label: const Text('Purchase History PDF')),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        DecoratedPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: widget.store.sales.isEmpty
                      ? null
                      : () => showOldReceiptDialog(context, widget.store),
                  icon: const Icon(Icons.receipt),
                  label: const Text('Old Receipt')),
            ]),
            const SizedBox(height: 10),
            const Text('Customer Cleanup',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            const Text(
                'Use only when the owner wants to clear old customer/debt records to save space.'),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: () async {
                    final confirmed = await confirmTypedDelete(
                        context,
                        'Delete all customers?',
                        'Type DELETE CUSTOMERS to permanently delete all saved customer names and phone numbers.',
                        'DELETE CUSTOMERS');
                    if (!confirmed) return;
                    await widget.store.deleteAllCustomers();
                  },
                  icon: const Icon(Icons.person_remove),
                  label: const Text('Delete Customers')),
              OutlinedButton.icon(
                  onPressed: () async {
                    final confirmed = await confirmTypedDelete(
                        context,
                        'Delete all debt history?',
                        'Type DELETE DEBTS to permanently delete debt sales and the report records linked to them.',
                        'DELETE DEBTS');
                    if (!confirmed) return;
                    await widget.store.deleteAllDebtHistory();
                  },
                  icon: const Icon(Icons.delete_sweep),
                  label: const Text('Delete Debt History')),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        SalesHistoryPanel(store: widget.store),
        const SizedBox(height: 12),
        VoidReturnsPanel(
          store: widget.store,
          query: voidSearch,
          selectedDate: voidDateFilter,
          onQueryChanged: (value) => setState(() => voidSearch = value),
          onDateChanged: (value) => setState(() => voidDateFilter = value),
        ),
        const SizedBox(height: 12),
        if (widget.store.saleVoids.isNotEmpty)
          VoidHistoryPanel(store: widget.store),
      ],
    );
  }
}

class DebtLedgerPanel extends StatelessWidget {
  const DebtLedgerPanel({
    required this.store,
    required this.debts,
    required this.query,
    required this.selectedDate,
    required this.statusFilter,
    required this.onQueryChanged,
    required this.onDateChanged,
    required this.onStatusChanged,
    super.key,
  });
  final AppStore store;
  final List<SaleRecord> debts;
  final String query;
  final DateTime? selectedDate;
  final String statusFilter;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<DateTime?> onDateChanged;
  final ValueChanged<String> onStatusChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Debt Ledger',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text(
            'Shows when debt was created, what was paid, what remains, and whether it is unpaid, partially paid, or fully paid.'),
        const SizedBox(height: 10),
        TextField(
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Search debt customer, sale, cashier, or branch',
              border: OutlineInputBorder()),
          onChanged: onQueryChanged,
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: () async {
                final picked = await showDatePicker(
                    context: context,
                    initialDate: selectedDate ?? DateTime.now(),
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 1)));
                onDateChanged(picked);
              },
              icon: const Icon(Icons.calendar_month),
              label: Text(selectedDate == null
                  ? 'Debt Date'
                  : shortDate(selectedDate!))),
          if (selectedDate != null)
            TextButton.icon(
                onPressed: () => onDateChanged(null),
                icon: const Icon(Icons.close),
                label: const Text('Clear Date')),
          DropdownButton<String>(
            value: statusFilter,
            items: const ['All', 'Unpaid', 'Partially paid', 'Fully paid']
                .map((item) => DropdownMenuItem(value: item, child: Text(item)))
                .toList(),
            onChanged: (value) => onStatusChanged(value ?? 'All'),
          ),
        ]),
        const SizedBox(height: 12),
        if (debts.isEmpty)
          const Text('No debt sales match this filter.')
        else
          ...debts.map((sale) {
            final balance = store.debtBalanceForSale(sale);
            final status = store.debtStatusForSale(sale);
            return Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(spacing: 10, runSpacing: 6, children: [
                        Text(shortDateTime(sale.createdAt),
                            style:
                                const TextStyle(fontWeight: FontWeight.w900)),
                        Text(sale.customerName.isEmpty
                            ? 'Customer: -'
                            : 'Customer: ${sale.customerName}'),
                        Text('Cashier: ${sale.cashier}'),
                        Text('Status: $status',
                            style:
                                const TextStyle(fontWeight: FontWeight.w900)),
                      ]),
                      const Divider(height: 18),
                      Wrap(spacing: 14, runSpacing: 6, children: [
                        Text('Sale ${store.moneyFor(sale.totalCents)}'),
                        Text('Paid ${store.moneyFor(sale.paidCents)}'),
                        Text('Balance ${store.moneyFor(balance)}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w900)),
                      ]),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: balance <= 0
                              ? null
                              : () =>
                                  showDebtPaymentDialog(context, store, sale),
                          icon: const Icon(Icons.payments),
                          label: Text(
                              balance <= 0 ? 'Fully Paid' : 'Record Payment'),
                        ),
                      )
                    ]),
              ),
            );
          }),
        if (store.customers.isNotEmpty) ...[
          const Divider(height: 22),
          const Text('Customer Purchase History',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          ...store.customers.take(8).map((customer) {
            final history = store.salesForCustomer(customer);
            if (history.isEmpty) return const SizedBox.shrink();
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.history),
              title: Text('${customer.code} - ${customer.name}',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(
                  '${history.length} sales | Last ${shortDateTime(history.first.createdAt)} | ${store.moneyFor(history.fold(0, (sum, sale) => sum + sale.totalCents))}'),
            );
          }),
        ],
      ]),
    );
  }
}

class SalesHistoryPanel extends StatelessWidget {
  const SalesHistoryPanel({required this.store, super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final sales = store.allKnownSales.take(80).toList();
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Sales History',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text(
            'Latest sales used by reports, debt, receipts, and customer history.'),
        const SizedBox(height: 10),
        if (sales.isEmpty)
          const Text('No sales recorded yet.')
        else
          ...sales.map((sale) {
            final net =
                max(0, sale.totalCents - store.voidedCentsForSale(sale.id));
            return Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant)),
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                leading: const Icon(Icons.receipt_long),
                title: Text(
                    '${sale.customerName.isEmpty ? sale.id : sale.customerName} - ${store.moneyFor(net)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900)),
                subtitle: Text(
                    '${shortDateTime(sale.createdAt)} | ${store.branchNameForId(sale.branchId)} | ${sale.paymentMethod} | ${sale.cashier}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: 'Delete sale',
                  icon: const Icon(Icons.delete),
                  onPressed: () async {
                    final ok = await confirmAction(context, 'Delete this sale?',
                        'This removes the sale from reports, debt, receipts, and cloud sync. Stock is not adjusted again.');
                    if (!ok) return;
                    await store.deleteSaleRecord(sale);
                  },
                ),
              ),
            );
          }),
      ]),
    );
  }
}

class VoidHistoryPanel extends StatelessWidget {
  const VoidHistoryPanel({required this.store, super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final voids = store.saleVoids.take(80).toList();
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Text('Void / Return History',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          ),
          TextButton.icon(
              onPressed: voids.isEmpty
                  ? null
                  : () async {
                      final ok = await confirmTypedDelete(
                          context,
                          'Delete all void history?',
                          'Type DELETE VOIDS to remove all void/return records from this device and cloud. Reports will no longer subtract those voids.',
                          'DELETE VOIDS');
                      if (!ok) return;
                      await store.deleteAllVoidHistory();
                    },
              icon: const Icon(Icons.delete_sweep),
              label: const Text('Delete All')),
        ]),
        const SizedBox(height: 6),
        const Text(
            'These records explain returns and voids. Delete only if the owner intentionally wants to remove that correction history.'),
        const SizedBox(height: 10),
        if (voids.isEmpty)
          const Text('No voids or returns recorded yet.')
        else
          ...voids.map((record) => Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant)),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  leading: const Icon(Icons.undo),
                  title: Text(
                      '${record.type.replaceAll('_', ' ')} - ${store.moneyFor(record.totalCents)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: Text(
                      '${shortDateTime(record.createdAt)} | ${store.branchNameForId(record.branchId)} | ${record.userName} | ${record.reason}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    tooltip: 'Delete void record',
                    icon: const Icon(Icons.delete),
                    onPressed: () async {
                      final ok = await confirmAction(
                          context,
                          'Delete this void record?',
                          'This removes the void/return record from reports and cloud sync. Stock is not adjusted again.');
                      if (!ok) return;
                      await store.deleteVoidRecord(record);
                    },
                  ),
                ),
              )),
      ]),
    );
  }
}

Future<void> showDebtPaymentDialog(
    BuildContext context, AppStore store, SaleRecord sale) async {
  final amount = TextEditingController();
  final balance = store.debtBalanceForSale(sale);
  if (balance <= 0) {
    showMessage(context, 'This debt is already fully paid.');
    return;
  }
  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Record Debt Payment'),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(sale.customerName.isEmpty
                ? 'Customer: -'
                : 'Customer: ${sale.customerName}'),
            const SizedBox(height: 4),
            Text('Created: ${shortDateTime(sale.createdAt)}'),
            const SizedBox(height: 4),
            Text('Balance: ${store.moneyFor(balance)}',
                style: const TextStyle(fontWeight: FontWeight.w900)),
            const SizedBox(height: 12),
            Field(
                controller: amount,
                label: 'Amount paid in ${store.displayCurrency}',
                icon: Icons.payments,
                required: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true)),
            const SizedBox(height: 8),
            const Text(
                'Partial payments are allowed. If the amount is more than the balance, only the remaining balance will be cleared.'),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: () async {
            final cents = store.displayAmountToBaseCents(amount.text);
            if (cents <= 0) {
              showMessage(context, 'Enter a valid payment amount.');
              return;
            }
            await store.settleDebt(sale, cents);
            if (context.mounted) {
              Navigator.pop(context);
              showMessage(context, 'Debt payment recorded.');
            }
          },
          icon: const Icon(Icons.check_circle),
          label: const Text('Record Payment'),
        ),
      ],
    ),
  );
}

class VoidReturnsPanel extends StatelessWidget {
  const VoidReturnsPanel(
      {required this.store,
      required this.query,
      required this.selectedDate,
      required this.onQueryChanged,
      required this.onDateChanged,
      super.key});
  final AppStore store;
  final String query;
  final DateTime? selectedDate;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<DateTime?> onDateChanged;

  @override
  Widget build(BuildContext context) {
    final filtered = store.sales.where((sale) {
      if (selectedDate != null &&
          !sameLocalDay(sale.createdAt, selectedDate!)) {
        return false;
      }
      final q = query.trim().toLowerCase();
      if (q.isEmpty) return true;
      return sale.id.toLowerCase().contains(q) ||
          sale.customerName.toLowerCase().contains(q) ||
          sale.cashier.toLowerCase().contains(q) ||
          sale.paymentMethod.toLowerCase().contains(q) ||
          sale.lines.any((line) => line.name.toLowerCase().contains(q));
    }).toList();
    final groups = groupedSales(filtered);
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Voids and Returns',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text(
            'Find the sale, then record a full or partial return. Stock and synced reports are corrected automatically.'),
        const SizedBox(height: 10),
        TextField(
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Search sale, customer, cashier, payment, or item',
              border: OutlineInputBorder()),
          onChanged: onQueryChanged,
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: () async {
                final picked = await showDatePicker(
                    context: context,
                    initialDate: selectedDate ?? DateTime.now(),
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 1)));
                onDateChanged(picked);
              },
              icon: const Icon(Icons.calendar_month),
              label: Text(selectedDate == null
                  ? 'Choose Date'
                  : 'Date: ${shortDate(selectedDate!)}')),
          if (selectedDate != null)
            TextButton.icon(
                onPressed: () => onDateChanged(null),
                icon: const Icon(Icons.close),
                label: const Text('Clear Date')),
        ]),
        const SizedBox(height: 12),
        if (store.sales.isEmpty)
          const Text('No sales available for voiding yet.')
        else if (filtered.isEmpty)
          const Text('No sales match that search.')
        else
          ...groups.entries.map((entry) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.key,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 8),
                      ...entry.value.map(
                          (sale) => VoidSaleCard(store: store, sale: sale)),
                    ]),
              )),
      ]),
    );
  }
}

class VoidSaleCard extends StatelessWidget {
  const VoidSaleCard({required this.store, required this.sale, super.key});
  final AppStore store;
  final SaleRecord sale;

  @override
  Widget build(BuildContext context) {
    final voided = store.voidedCentsForSale(sale.id);
    final net = max(0, sale.totalCents - voided);
    final fullyVoided = sale.lines.isEmpty || voided >= sale.totalCents;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.receipt_long),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        sale.customerName.isEmpty
                            ? 'Sale ${sale.id}'
                            : sale.customerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w900)),
                    Text(
                        '${shortDateTime(sale.createdAt)} | ${sale.paymentMethod} | ${sale.cashier}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ]),
            ),
            OutlinedButton.icon(
                onPressed: fullyVoided
                    ? null
                    : () => showVoidSaleDialog(context, store, sale),
                icon: const Icon(Icons.undo),
                label: Text(fullyVoided ? 'Voided' : 'Void')),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            Chip(label: Text('Gross ${store.moneyFor(sale.totalCents)}')),
            Chip(label: Text('Voided ${store.moneyFor(voided)}')),
            Chip(label: Text('Net ${store.moneyFor(net)}')),
            Chip(
                label: Text(
                    '${sale.lines.length} line${sale.lines.length == 1 ? '' : 's'}')),
          ]),
          if (sale.lines.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              sale.lines
                  .take(3)
                  .map((line) => '${line.quantity}x ${line.name}')
                  .join(' | '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ]),
      ),
    );
  }
}

Map<String, List<SaleRecord>> groupedSales(List<SaleRecord> sales) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final weekStart = today.subtract(Duration(days: now.weekday - 1));
  final result = <String, List<SaleRecord>>{
    'Today': [],
    'Yesterday': [],
    'This Week': [],
    'Older': [],
  };
  for (final sale in sales) {
    final day =
        DateTime(sale.createdAt.year, sale.createdAt.month, sale.createdAt.day);
    if (day == today) {
      result['Today']!.add(sale);
    } else if (day == yesterday) {
      result['Yesterday']!.add(sale);
    } else if (!day.isBefore(weekStart)) {
      result['This Week']!.add(sale);
    } else {
      result['Older']!.add(sale);
    }
  }
  result.removeWhere((_, value) => value.isEmpty);
  return result;
}

class BranchesPage extends StatelessWidget {
  const BranchesPage({required this.store, super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => PageFrame(
        title: 'Branch Control',
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: () async {
                final draft =
                    await showBranchEditorDialog(context, title: 'Add Branch');
                if (draft != null) await store.addBranch(draft);
              },
              icon: const Icon(Icons.add_business),
              label: const Text('Add Branch'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: store.deviceUid));
                if (context.mounted) showMessage(context, 'Device ID copied');
              },
              icon: const Icon(Icons.devices),
              label: const Text('Copy Device ID'),
            ),
          ]),
          const SizedBox(height: 12),
          InfoPanel(
              icon: Icons.devices,
              title: 'This device',
              body:
                  '${store.deviceUid} is currently operating as ${store.currentBranch?.name ?? 'no branch'}. Switching branch reloads that branch stock/sales from the shared database. Every extra device joins with a branch activation code and still needs its own license voucher.'),
          const SizedBox(height: 12),
          InfoPanel(
              icon: Icons.login,
              title: 'Branch session',
              body:
                  'For an owner, switching branch works like entering that branch: POS carts are cleared, stock quantities change to that branch, sales reports change to that branch, and new transactions are recorded under that branch.'),
          const SizedBox(height: 12),
          TransferHistoryPanel(store: store),
          const SizedBox(height: 12),
          ...store.branches.map((branch) => BranchControlCard(
                key: ValueKey(
                    '${branch.id}-${store.branchTotalStockQuantity(branch.id)}-${store.branchAssignedProductCount(branch.id)}'),
                store: store,
                branch: branch,
                isCurrent: branch.id == store.assignedBranchId,
              )),
        ],
      ),
    );
  }
}

class TransferHistoryPanel extends StatelessWidget {
  const TransferHistoryPanel({required this.store, super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final records = store.stockTransfers.take(8).toList();
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: DecoratedPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.move_down),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Transfer History',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
              ),
              Chip(label: Text('${store.stockTransfers.length} recorded')),
              IconButton(
                  tooltip: 'Delete all transfer history',
                  onPressed: store.stockTransfers.isEmpty
                      ? null
                      : () async {
                          final confirmed = await confirmTypedDelete(
                              context,
                              'Delete transfer history?',
                              'Type DELETE TRANSFERS to permanently delete all transfer history records.',
                              'DELETE TRANSFERS');
                          if (!confirmed) return;
                          await store.deleteAllTransferHistory();
                        },
                  icon: const Icon(Icons.delete_sweep)),
            ]),
            const SizedBox(height: 8),
            if (records.isEmpty)
              const Text(
                  'No branch transfers recorded on this device yet. Transfers made from here will appear here after confirmation.')
            else
              SizedBox(
                height: 280,
                child: ListView.separated(
                  itemCount: records.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final record = records[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading:
                          const CircleAvatar(child: Icon(Icons.swap_horiz)),
                      title: Text('${record.quantity} x ${record.productName}',
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text(
                          '${record.fromBranchName} -> ${record.toBranchName}\n${record.userName} | ${shortDateTime(record.createdAt)}'),
                      isThreeLine: true,
                    );
                  },
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class BranchControlCard extends StatelessWidget {
  const BranchControlCard(
      {required this.store,
      required this.branch,
      required this.isCurrent,
      super.key});
  final AppStore store;
  final BranchProfile branch;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final code = store.activationCodesByBranch[branch.id];
    final color = isCurrent
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.outline;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
              color: isCurrent
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(isCurrent ? Icons.check_circle : Icons.storefront,
                color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(branch.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 19, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text([
                      if (branch.phone.trim().isNotEmpty) branch.phone,
                      if (branch.address.trim().isNotEmpty) branch.address,
                    ].join(' | ')),
                  ]),
            ),
            Chip(
              label: Text(isCurrent ? 'Current' : 'Branch'),
              backgroundColor: color.withValues(alpha: 0.08),
              side: BorderSide(color: color.withValues(alpha: 0.35)),
            ),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (code != null)
              InputChip(
                avatar: const Icon(Icons.key, size: 18),
                label: Text(code),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (context.mounted)
                    showMessage(context, 'Branch activation code copied');
                },
              )
            else
              const Chip(label: Text('No activation code yet')),
            if (isCurrent)
              Chip(
                  avatar: const Icon(Icons.inventory_2, size: 18),
                  label: Text(
                      '${store.currentBranchStockedProductCount} stocked products')),
            if (!isCurrent)
              Chip(
                  avatar: const Icon(Icons.inventory_2, size: 18),
                  label: Text(
                      '${store.branchAssignedProductCount(branch.id)} stocked products')),
            Chip(
                avatar: const Icon(Icons.warehouse, size: 18),
                label: Text(
                    '${store.branchTotalStockQuantity(branch.id)} total pieces')),
            if (isCurrent)
              Chip(
                  avatar: const Icon(Icons.payments, size: 18),
                  label: Text(store.moneyFor(store.salesTodayCents))),
            if (!isCurrent)
              const Chip(label: Text('Switch to inspect live stock')),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonalIcon(
                onPressed: isCurrent
                    ? null
                    : () async {
                        await store.assignDeviceToBranch(branch);
                        if (context.mounted) {
                          showMessage(
                              context, 'Now operating as ${branch.name}');
                        }
                      },
                icon: const Icon(Icons.switch_access_shortcut),
                label: Text(isCurrent ? 'Operating Here' : 'Switch Here')),
            OutlinedButton.icon(
                onPressed: isCurrent
                    ? null
                    : () => showBranchTransferDialog(context, store, branch),
                icon: const Icon(Icons.move_up),
                label: const Text('Transfer Stock')),
            OutlinedButton.icon(
                onPressed: code == null
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(
                            text: store.branchJoinMessage(branch)));
                        if (context.mounted)
                          showMessage(
                              context, 'Complete branch join message copied');
                      },
                icon: const Icon(Icons.copy),
                label: const Text('Copy Join')),
            IconButton.outlined(
              onPressed: () async {
                final draft = await showBranchEditorDialog(context,
                    title: 'Edit Branch', existing: branch);
                if (draft != null) await store.updateBranch(branch, draft);
              },
              icon: const Icon(Icons.edit),
              tooltip: 'Edit branch',
            ),
            IconButton.outlined(
              onPressed: () async {
                final confirmed = await confirmDanger(
                    context,
                    'Delete ${branch.name}?',
                    'This branch will be removed from this shop view. Devices assigned to it should be moved first.');
                if (!confirmed) return;
                try {
                  await store.deleteBranch(branch);
                } catch (error) {
                  if (context.mounted) showMessage(context, cleanError(error));
                }
              },
              icon: const Icon(Icons.delete),
              tooltip: 'Delete branch',
            ),
          ]),
        ]),
      ),
    );
  }
}

class FiscalPage extends StatelessWidget {
  const FiscalPage({required this.store, super.key});
  final AppStore store;
  @override
  Widget build(BuildContext context) {
    final company = store.company!;
    return PageFrame(
      title: 'Fiscalisation and Company Details',
      trailing: Switch(
        value: company.fiscalMode,
        onChanged: store.setFiscalMode,
      ),
      children: [
        CompanyFiscalForm(store: store),
        const SizedBox(height: 12),
        if (!company.fiscalMode)
          const InfoPanel(
              icon: Icons.storefront,
              title: 'Non-fiscal mode active',
              body:
                  'Shop profile, POS, stock, debt, receipts, reports, sync, backups, and licensing remain active without VAT/TIN fiscal submission.')
        else ...[
          WarningPanel(
              text: company.zimraDeviceId.trim().isEmpty
                  ? 'Fiscal mode needs ZIMRA deviceID, certificate setup, TIN/VAT where applicable, and test/live approval before real FDMS submission.'
                  : 'Fiscal Integration Stage Reached - ZIMRA device details captured. Use test FDMS before going live.'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                  onPressed: store.fiscalDayOpen ? null : store.openFiscalDay,
                  icon: const Icon(Icons.today),
                  label: const Text('Open Fiscal Day')),
              FilledButton.tonalIcon(
                  onPressed: store.fiscalDayOpen ? store.closeFiscalDay : null,
                  icon: const Icon(Icons.event_busy),
                  label: const Text('Close Fiscal Day')),
              OutlinedButton.icon(
                  onPressed: () => showMessage(context,
                      'FDMS test: ${company.zimraDeviceId.isEmpty ? 'missing deviceID' : 'device ${company.zimraDeviceId} ready for backend certificate calls'}'),
                  icon: const Icon(Icons.health_and_safety),
                  label: const Text('Diagnostics')),
            ],
          ),
        ],
      ],
    );
  }
}

class CompanyFiscalForm extends StatefulWidget {
  const CompanyFiscalForm({required this.store, super.key});
  final AppStore store;
  @override
  State<CompanyFiscalForm> createState() => _CompanyFiscalFormState();
}

class _CompanyFiscalFormState extends State<CompanyFiscalForm> {
  late final shop = TextEditingController(text: widget.store.company!.shopName);
  late final branch =
      TextEditingController(text: widget.store.company!.branchName);
  late final phone = TextEditingController(text: widget.store.company!.phone);
  late final address =
      TextEditingController(text: widget.store.company!.address);
  late final registered =
      TextEditingController(text: widget.store.company!.registeredName);
  late final tin = TextEditingController(text: widget.store.company!.tin);
  late final vat = TextEditingController(text: widget.store.company!.vatNumber);
  late final deviceId =
      TextEditingController(text: widget.store.company!.zimraDeviceId);
  late final serial =
      TextEditingController(text: widget.store.company!.fiscalSerialNumber);
  late final qr =
      TextEditingController(text: widget.store.company!.fiscalQrUrl);

  @override
  Widget build(BuildContext context) {
    return DecoratedPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Company Profile',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Field(
              controller: shop,
              label: 'Shop name',
              icon: Icons.storefront,
              required: true),
          Field(
              controller: branch,
              label: 'Branch name',
              icon: Icons.account_tree,
              required: true),
          Field(controller: phone, label: 'Phone', icon: Icons.phone),
          Field(controller: address, label: 'Address', icon: Icons.location_on),
          if (widget.store.company!.fiscalMode) ...[
            const Divider(height: 24),
            Field(
                controller: registered,
                label: 'Registered taxpayer/company name',
                icon: Icons.badge),
            Field(controller: tin, label: 'TIN', icon: Icons.numbers),
            Field(controller: vat, label: 'VAT number', icon: Icons.receipt),
            Wrap(spacing: 10, runSpacing: 10, children: [
              SizedBox(
                width: MediaQuery.sizeOf(context).width < 620 ? 380 : 260,
                child: Field(
                    controller: deviceId,
                    label: 'ZIMRA Fiscal Device ID',
                    icon: Icons.devices),
              ),
              SizedBox(
                width: MediaQuery.sizeOf(context).width < 620 ? 380 : 260,
                child: Field(
                    controller: serial,
                    label: 'Fiscal Device Serial',
                    icon: Icons.confirmation_number),
              ),
            ]),
            Field(
                controller: qr,
                label: 'Receipt QR / Verification URL',
                icon: Icons.qr_code),
          ],
          FilledButton.icon(
            onPressed: () {
              final company = widget.store.company!;
              company.shopName = shop.text.trim();
              company.branchName = branch.text.trim();
              company.phone = phone.text.trim();
              company.address = address.text.trim();
              company.registeredName = registered.text.trim();
              company.tin = tin.text.trim();
              company.vatNumber = vat.text.trim();
              company.zimraDeviceId = deviceId.text.trim();
              company.fiscalSerialNumber = serial.text.trim();
              company.fiscalQrUrl = qr.text.trim();
              widget.store.saveCompany(company);
              showMessage(context, 'Company and fiscal details saved');
            },
            icon: const Icon(Icons.save),
            label: const Text('Save Company Details'),
          ),
        ],
      ),
    );
  }
}

class PrintPage extends StatelessWidget {
  const PrintPage({required this.store, super.key});
  final AppStore store;
  @override
  Widget build(BuildContext context) {
    final sale = store.sales.isEmpty ? null : store.sales.last;
    final receipt = sale == null
        ? 'No sale yet. Complete a POS sale first.'
        : store.receiptText(sale);
    return PageFrame(
      title: 'Receipts and Printing',
      children: [
        InfoPanel(
            icon: Icons.print,
            title: 'Holistic printing',
            body:
                'SUNMI native print is the cashier default on SUNMI. RawBT/system print remains here as an owner/admin fallback for Bluetooth printers, iOS AirPrint, Windows print, and unusual device setups.'),
        const SizedBox(height: 12),
        SelectableText(receipt),
        const SizedBox(height: 12),
        FutureBuilder<bool>(
          future: ReceiptOutputService.isSunmiDevice(),
          builder: (context, snapshot) {
            final isSunmi = snapshot.data ?? false;
            return Wrap(spacing: 10, runSpacing: 10, children: [
              if (isSunmi)
                FilledButton.icon(
                    onPressed: sale == null
                        ? null
                        : () async {
                            try {
                              await ReceiptOutputService.printSunmi(receipt);
                              if (context.mounted) {
                                showMessage(
                                    context, 'Printed through SUNMI printer');
                              }
                            } catch (error) {
                              if (context.mounted) {
                                showMessage(context, cleanError(error));
                              }
                            }
                          },
                    icon: const Icon(Icons.point_of_sale),
                    label: const Text('SUNMI Print')),
              FilledButton.icon(
                  onPressed: sale == null
                      ? null
                      : () => ReceiptOutputService.printNative(receipt),
                  icon: const Icon(Icons.print),
                  label: Text(
                      isSunmi ? 'RawBT / System Fallback' : 'Native Print')),
              FilledButton.tonalIcon(
                  onPressed: sale == null
                      ? null
                      : () => ReceiptOutputService.shareText(receipt),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy Text')),
              OutlinedButton.icon(
                  onPressed: sale == null
                      ? null
                      : () => ReceiptOutputService.sharePdf(receipt),
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('Share PDF')),
              OutlinedButton.icon(
                  onPressed: sale == null
                      ? null
                      : () => showWhatsAppReceiptDialog(context, receipt),
                  icon: const Icon(Icons.chat),
                  label: const Text('WhatsApp')),
            ]);
          },
        ),
      ],
    );
  }
}

class AdminPage extends StatefulWidget {
  const AdminPage({required this.store, super.key});
  final AppStore store;
  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  final currentPin = TextEditingController();
  final newPin = TextEditingController();
  late final backend = TextEditingController(text: widget.store.backendUrl);
  late final anonKey =
      TextEditingController(text: widget.store.supabaseAnonKey);
  @override
  Widget build(BuildContext context) {
    final canManageUsers = widget.store.currentUser!.hasAllPrivileges;
    return PageFrame(
      title: 'Admin Control',
      children: [
        if (canManageUsers) ...[
          DeviceIdCard(deviceUid: widget.store.deviceUid),
          const SizedBox(height: 12),
          FiscalModeAdminPanel(store: widget.store),
          const SizedBox(height: 12),
          CompanyFiscalForm(store: widget.store),
          const SizedBox(height: 12),
          DecoratedPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Cloud Connection',
                    style: TextStyle(fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                Field(
                    controller: backend,
                    label: 'Backend / Supabase URL',
                    icon: Icons.cloud,
                    required: true),
                Field(
                    controller: anonKey,
                    label: 'Supabase anon public key',
                    icon: Icons.vpn_key,
                    obscure: true),
                FilledButton.icon(
                  onPressed: () async {
                    await widget.store.updateCloudSettings(
                        backend.text.trim(), anonKey.text.trim());
                    try {
                      await widget.store.testCloudConnection(
                          backend.text.trim(),
                          serverAnonKey: anonKey.text.trim());
                      if (context.mounted) {
                        showMessage(
                            context, 'Cloud connection saved and tested');
                      }
                    } catch (error) {
                      if (context.mounted)
                        showMessage(context, cleanError(error));
                    }
                  },
                  icon: const Icon(Icons.cloud_done),
                  label: const Text('Save and Test Cloud'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          CurrencySettingsPanel(store: widget.store),
          const SizedBox(height: 12),
          AuditDashboardPanel(store: widget.store),
          const SizedBox(height: 12),
        ],
        DecoratedPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Change My PIN',
                  style: TextStyle(fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              Field(
                  controller: currentPin,
                  label: 'Current PIN',
                  icon: Icons.lock,
                  obscure: true,
                  keyboardType: TextInputType.number),
              Field(
                  controller: newPin,
                  label: 'New PIN',
                  icon: Icons.pin,
                  obscure: true,
                  keyboardType: TextInputType.number),
              FilledButton.icon(
                onPressed: () async {
                  try {
                    await widget.store.changePin(widget.store.currentUser!,
                        currentPin.text.trim(), newPin.text.trim());
                    if (context.mounted) showMessage(context, 'PIN changed');
                    currentPin.clear();
                    newPin.clear();
                  } catch (error) {
                    if (context.mounted)
                      showMessage(context,
                          error.toString().replaceFirst('Bad state: ', ''));
                  }
                },
                icon: const Icon(Icons.password),
                label: const Text('Change PIN'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (canManageUsers) ...[
          DecoratedPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Usernames, PINs, and Privileges',
                    style: TextStyle(fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                ...widget.store.users.map(
                  (user) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${user.name} - ${user.role}',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: Text(
                        'Username: ${user.username} | PIN: ${user.pin} | ${user.hasAllPrivileges ? 'All privileges' : '${user.permissions.length} privileges'} | Branches: ${branchAccessLabel(widget.store, user)}'),
                    trailing: Wrap(
                      spacing: 6,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit),
                          onPressed: () async {
                            final draft = await showUserEditorDialog(context,
                                title: 'Edit User',
                                existing: user,
                                branches: widget.store.branches);
                            if (draft == null) return;
                            try {
                              await widget.store.updateUser(user, draft);
                              if (context.mounted)
                                showMessage(context, 'User updated');
                            } catch (error) {
                              if (context.mounted)
                                showMessage(
                                    context,
                                    error
                                        .toString()
                                        .replaceFirst('Bad state: ', ''));
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () async {
                            final confirmed = await confirmDanger(
                                context,
                                'Delete ${user.name}?',
                                'This removes username "${user.username}", PIN access, and all privileges for this user. This cannot be undone on this device.');
                            if (!confirmed) return;
                            try {
                              await widget.store.deleteUser(user);
                              if (context.mounted)
                                showMessage(context, 'User deleted');
                            } catch (error) {
                              if (context.mounted)
                                showMessage(
                                    context,
                                    error
                                        .toString()
                                        .replaceFirst('Bad state: ', ''));
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () async {
              final draft = await showUserEditorDialog(context,
                  title: 'Add User', branches: widget.store.branches);
              if (draft == null) return;
              try {
                await widget.store.addUser(draft.name, draft.username,
                    draft.role, draft.pin, draft.permissions, draft.branchIds);
              } catch (error) {
                if (context.mounted)
                  showMessage(context,
                      error.toString().replaceFirst('Bad state: ', ''));
              }
            },
            icon: const Icon(Icons.person_add),
            label: const Text('Add User'),
          ),
        ],
      ],
    );
  }
}

class AuditDashboardPanel extends StatefulWidget {
  const AuditDashboardPanel({required this.store, super.key});
  final AppStore store;

  @override
  State<AuditDashboardPanel> createState() => _AuditDashboardPanelState();
}

class _AuditDashboardPanelState extends State<AuditDashboardPanel> {
  bool allBranches = true;
  String query = '';
  DateTime? selectedDate;

  @override
  Widget build(BuildContext context) {
    final rows = widget.store.auditRows(allBranches: allBranches).where((row) {
      if (selectedDate != null && !sameLocalDay(row.when, selectedDate!)) {
        return false;
      }
      final q = query.trim().toLowerCase();
      if (q.isEmpty) return true;
      return row.action.toLowerCase().contains(q) ||
          row.actor.toLowerCase().contains(q) ||
          row.branch.toLowerCase().contains(q) ||
          row.detail.toLowerCase().contains(q);
    }).toList();
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Audit Dashboard',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        const Text(
            'Owner view of sales, voids, transfers, accounting, stock counts, payroll, and supplier actions.'),
        const SizedBox(height: 10),
        TextField(
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Search action, user, branch, or detail',
              border: OutlineInputBorder()),
          onChanged: (value) => setState(() => query = value),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilterChip(
              selected: allBranches,
              label: const Text('All branches'),
              onSelected: (value) => setState(() => allBranches = value)),
          OutlinedButton.icon(
              onPressed: () async {
                final picked = await showDatePicker(
                    context: context,
                    initialDate: selectedDate ?? DateTime.now(),
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 1)));
                setState(() => selectedDate = picked);
              },
              icon: const Icon(Icons.calendar_month),
              label: Text(selectedDate == null
                  ? 'Choose Date'
                  : shortDate(selectedDate!))),
          if (selectedDate != null)
            TextButton.icon(
                onPressed: () => setState(() => selectedDate = null),
                icon: const Icon(Icons.close),
                label: const Text('Clear Date')),
        ]),
        const SizedBox(height: 10),
        if (rows.isEmpty)
          const Text('No audit records match this filter.')
        else
          ...rows.take(40).map((row) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.manage_search),
                title: Text('${row.action} | ${row.branch}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(
                    '${shortDateTime(row.when)} | ${row.actor} | ${row.detail}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              )),
      ]),
    );
  }
}

class FiscalModeAdminPanel extends StatelessWidget {
  const FiscalModeAdminPanel({required this.store, super.key});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final enabled = store.fiscalMode;
    return DecoratedPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(enabled ? Icons.receipt_long : Icons.storefront,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Fiscalisation Mode',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
              Text(enabled
                  ? 'Fiscal mode is enabled for this shop.'
                  : 'Non-fiscal mode is active. POS, stock, sync, receipts, debt, and reports continue without VAT/TIN fiscal submission.'),
            ]),
          ),
          Switch(
            value: enabled,
            onChanged: (value) async {
              await store.setFiscalMode(value);
              if (context.mounted) {
                showMessage(
                    context,
                    value
                        ? 'Fiscalisation enabled. Add TIN, VAT, ZIMRA deviceID, serial number, QR URL, then open fiscal day.'
                        : 'Fiscalisation disabled. Non-fiscal receipt mode is active.');
              }
            },
          ),
        ]),
        const SizedBox(height: 10),
        if (enabled)
          const WarningPanel(
              text:
                  'Fiscal Integration Stage Reached - Upload Fiscal API Documentation / Credentials to Continue. Configure taxpayer/company name, TIN, VAT number where applicable, ZIMRA deviceID, fiscal serial number, and FDMS QR/verification URL before fiscal receipts.')
        else
          const InfoPanel(
              icon: Icons.lock_open,
              title: 'Clean non-fiscal flow',
              body:
                  'Fiscal screens and fiscal receipt text stay hidden for normal users until this is enabled and their role has fiscal privileges. License renewal remains on the locked launch screen, not inside Admin.'),
        if (enabled) ...[
          const SizedBox(height: 10),
          InfoPanel(
              icon: store.fiscalDayOpen ? Icons.today : Icons.event_busy,
              title: store.fiscalDayOpen
                  ? 'Fiscal day #${store.fiscalDayNo} open'
                  : 'Fiscal day closed',
              body: store.fiscalDayOpen
                  ? 'Fiscal invoices from this branch are marked pending for FDMS submission until the ZIMRA bridge is connected.'
                  : 'Open fiscal day before issuing fiscal receipts. Closing day is stored in Supabase for audit.'),
          const SizedBox(height: 10),
          Wrap(spacing: 10, runSpacing: 10, children: [
            FilledButton.icon(
                onPressed: store.fiscalDayOpen ? null : store.openFiscalDay,
                icon: const Icon(Icons.today),
                label: const Text('Open Fiscal Day')),
            FilledButton.tonalIcon(
                onPressed: store.fiscalDayOpen ? store.closeFiscalDay : null,
                icon: const Icon(Icons.event_busy),
                label: const Text('Close Fiscal Day')),
          ]),
        ],
      ]),
    );
  }
}

class CurrencySettingsPanel extends StatefulWidget {
  const CurrencySettingsPanel({required this.store, super.key});
  final AppStore store;

  @override
  State<CurrencySettingsPanel> createState() => _CurrencySettingsPanelState();
}

class _CurrencySettingsPanelState extends State<CurrencySettingsPanel> {
  late String currency = widget.store.displayCurrency;
  late final usd = TextEditingController(
      text: (widget.store.exchangeRates['USD'] ?? 1).toString());
  late final zwl = TextEditingController(
      text: (widget.store.exchangeRates['ZWL'] ?? 25000).toString());
  late final zar = TextEditingController(
      text: (widget.store.exchangeRates['ZAR'] ?? 18.5).toString());
  late final bwp = TextEditingController(
      text: (widget.store.exchangeRates['BWP'] ?? 13.6).toString());

  @override
  Widget build(BuildContext context) {
    return DecoratedPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Currency and Exchange Rates',
              style: TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          const Text(
              'Admin-controlled display rates. USD remains the base selling currency; totals can be viewed as USD, ZWL, rand, or pula.'),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: currency,
            items: const ['USD', 'ZWL', 'ZAR', 'BWP']
                .map((code) => DropdownMenuItem(value: code, child: Text(code)))
                .toList(),
            onChanged: (value) => setState(() => currency = value ?? currency),
            decoration: const InputDecoration(
                labelText: 'Default till display currency',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                  width: 150,
                  child: Field(
                      controller: usd,
                      label: 'USD',
                      icon: Icons.attach_money,
                      keyboardType: TextInputType.number)),
              SizedBox(
                  width: 150,
                  child: Field(
                      controller: zwl,
                      label: 'ZWL rate',
                      icon: Icons.currency_exchange,
                      keyboardType: TextInputType.number)),
              SizedBox(
                  width: 150,
                  child: Field(
                      controller: zar,
                      label: 'ZAR rate',
                      icon: Icons.currency_exchange,
                      keyboardType: TextInputType.number)),
              SizedBox(
                  width: 150,
                  child: Field(
                      controller: bwp,
                      label: 'BWP rate',
                      icon: Icons.currency_exchange,
                      keyboardType: TextInputType.number)),
            ],
          ),
          FilledButton.icon(
            onPressed: () async {
              await widget.store.updateExchangeRates({
                'USD': double.tryParse(usd.text.trim()) ?? 1,
                'ZWL': double.tryParse(zwl.text.trim()) ?? 25000,
                'ZAR': double.tryParse(zar.text.trim()) ?? 18.5,
                'BWP': double.tryParse(bwp.text.trim()) ?? 13.6,
              }, currency);
              if (context.mounted)
                showMessage(context, 'Currency settings saved');
            },
            icon: const Icon(Icons.save),
            label: const Text('Save Currency Settings'),
          ),
        ],
      ),
    );
  }
}

class ReceiptOutputService {
  const ReceiptOutputService._();
  static const MethodChannel _printChannel =
      MethodChannel('com.lightwinter.retailos/printing');

  static Future<Uint8List> buildPdf(String receiptText,
      {bool brandedReport = false}) async {
    final doc = pw.Document();
    final lines = receiptText
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) => line.trimRight())
        .toList();
    final title = lines.length > 1 && lines.first.contains('Light Winter')
        ? lines[1].trim()
        : 'RetailOS Document';
    if (!brandedReport) {
      doc.addPage(pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(20),
          build: (_) => [
                pw.Text(receiptText,
                    style: const pw.TextStyle(fontSize: 10, lineSpacing: 2)),
              ]));
    } else {
      doc.addPage(pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(24),
          header: (_) => _pdfHeader(title),
          footer: (context) => _pdfFooter(context),
          build: (_) => _pdfBody(lines)));
    }
    return doc.save();
  }

  static pw.Widget _pdfHeader(String title) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 14),
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: PdfColors.blueGrey900,
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Container(
            width: 42,
            height: 42,
            alignment: pw.Alignment.center,
            decoration: pw.BoxDecoration(
              color: PdfColors.white,
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Text('LWT',
                style: pw.TextStyle(
                    color: PdfColors.teal800,
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold)),
          ),
          pw.SizedBox(width: 12),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('Light Winter Technologies',
                    style: pw.TextStyle(
                        color: PdfColors.white,
                        fontSize: 16,
                        fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 3),
                pw.Text(title,
                    style: const pw.TextStyle(
                        color: PdfColors.cyan100, fontSize: 10)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _pdfFooter(pw.Context context) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 10),
      padding: const pw.EdgeInsets.only(top: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: PdfColors.grey300)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('Provided by Light Winter Technologies',
              style: const pw.TextStyle(color: PdfColors.grey700, fontSize: 8)),
          pw.Text('Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(color: PdfColors.grey700, fontSize: 8)),
        ],
      ),
    );
  }

  static List<pw.Widget> _pdfBody(List<String> lines) {
    final body = <pw.Widget>[];
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trimRight();
      if (index < 2 && lines.first.contains('Light Winter')) continue;
      if (line.trim().isEmpty) {
        body.add(pw.SizedBox(height: 6));
      } else if (_isPdfSection(line)) {
        body.add(_pdfSection(line));
      } else if (_isPdfTransactionHeader(line)) {
        body.add(_pdfTransactionHeader(line));
      } else if (line.startsWith('  ')) {
        body.add(_pdfIndentedLine(line.trim()));
      } else if (_isPdfKeyValue(line)) {
        body.add(_pdfKeyValue(line));
      } else {
        body.add(pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Text(line,
              style: const pw.TextStyle(fontSize: 9, lineSpacing: 2)),
        ));
      }
    }
    return body;
  }

  static bool _isPdfSection(String line) {
    return {
      'Payment mix',
      'High performing stock',
      'Slow moving stock',
      'User performance',
      'Transaction details',
      'Smart Business Insights',
      'Revenue',
      'Cost of Sales',
      'Operating Expenses',
      'Net Profit / Loss',
      'Supplier and Customer Balances',
      'Stock Position',
      'Batch / Expiry Watch',
      'Payroll / HR',
      'Cashbook Summary',
      'Debt Aging',
      'Expense / Income Register',
      'Accounting Entries',
      'Stock Product List',
    }.contains(line.trim());
  }

  static bool _isPdfTransactionHeader(String line) {
    return line.contains(' | Branch: ') && line.contains(' | ');
  }

  static bool _isPdfKeyValue(String line) {
    if (line.startsWith('http')) return false;
    final colon = line.indexOf(':');
    return colon > 0 && colon < 42 && !line.contains(' | ');
  }

  static pw.Widget _pdfSection(String line) {
    return pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(top: 8, bottom: 5),
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: const pw.BoxDecoration(
        color: PdfColors.blueGrey50,
        border: pw.Border(
          left: pw.BorderSide(color: PdfColors.teal700, width: 3),
          bottom: pw.BorderSide(color: PdfColors.blueGrey100),
        ),
      ),
      child: pw.Text(line,
          style: pw.TextStyle(
              color: PdfColors.blueGrey900,
              fontSize: 11,
              fontWeight: pw.FontWeight.bold)),
    );
  }

  static pw.Widget _pdfTransactionHeader(String line) {
    return pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(top: 6, bottom: 3),
      padding: const pw.EdgeInsets.all(6),
      decoration: pw.BoxDecoration(
        color: PdfColors.grey100,
        borderRadius: pw.BorderRadius.circular(5),
        border: pw.Border.all(color: PdfColors.grey300),
      ),
      child: pw.Text(line,
          style: pw.TextStyle(
              fontSize: 8.5,
              color: PdfColors.blueGrey900,
              fontWeight: pw.FontWeight.bold)),
    );
  }

  static pw.Widget _pdfIndentedLine(String line) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(left: 12, bottom: 2),
      padding: const pw.EdgeInsets.only(left: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(left: pw.BorderSide(color: PdfColors.teal100)),
      ),
      child: pw.Text(line, style: const pw.TextStyle(fontSize: 8.5)),
    );
  }

  static pw.Widget _pdfKeyValue(String line) {
    final colon = line.indexOf(':');
    final key = line.substring(0, colon).trim();
    final value = line.substring(colon + 1).trim();
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey200)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            flex: 3,
            child: pw.Text(key,
                style: pw.TextStyle(
                    fontSize: 9,
                    color: PdfColors.blueGrey800,
                    fontWeight: pw.FontWeight.bold)),
          ),
          pw.SizedBox(width: 8),
          pw.Expanded(
            flex: 5,
            child: pw.Text(value.isEmpty ? '-' : value,
                textAlign: pw.TextAlign.right,
                style:
                    const pw.TextStyle(fontSize: 9, color: PdfColors.grey900)),
          ),
        ],
      ),
    );
  }

  static Future<void> printNative(String receiptText,
      {bool brandedReport = false}) async {
    await Printing.layoutPdf(
        name: 'Light Winter RetailOS Receipt',
        onLayout: (_) => buildPdf(receiptText, brandedReport: brandedReport));
  }

  static Future<bool> isSunmiDevice() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _printChannel.invokeMethod<bool>('isSunmiDevice') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> printSunmi(String receiptText) async {
    if (!Platform.isAndroid) {
      throw StateError(
          'SUNMI native print is only available on SUNMI Android devices.');
    }
    await _printChannel
        .invokeMethod<bool>('printSunmiText', {'text': receiptText});
  }

  static Future<void> sharePdf(String receiptText,
      {String filename = 'light-winter-retailos-receipt.pdf',
      bool brandedReport = false}) async {
    final bytes = await buildPdf(receiptText, brandedReport: brandedReport);
    await Printing.sharePdf(bytes: bytes, filename: filename);
  }

  static Future<void> shareText(String receiptText) async {
    await Clipboard.setData(ClipboardData(text: receiptText));
  }

  static Future<File> saveCsv(String csvText,
      {String filename = 'light-winter-stock.csv'}) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$filename');
    await file.writeAsString(csvText);
    return file;
  }

  static Future<void> sendWhatsApp(String phone, String receiptText) async {
    final digits = normalizeWhatsAppNumber(phone);
    final uri = Uri.parse(
        'https://wa.me/$digits?text=${Uri.encodeComponent(receiptText)}');
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      throw StateError(
          'WhatsApp could not be opened. Check that WhatsApp is installed and the number is valid.');
    }
  }
}

Future<void> showReceiptActionsDialog(
    BuildContext context, AppStore store, SaleRecord sale) async {
  String receipt;
  try {
    receipt = store.receiptText(sale);
  } catch (error) {
    if (context.mounted) showMessage(context, cleanError(error));
    return;
  }
  final isSunmi = await ReceiptOutputService.isSunmiDevice();
  bool printing = false;
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(store.fiscalMode ? 'Fiscal Receipt' : 'Receipt'),
        content: SingleChildScrollView(child: SelectableText(receipt)),
        actions: [
          TextButton(
              onPressed: printing ? null : () => Navigator.pop(context),
              child: const Text('Back to Cart')),
          OutlinedButton.icon(
            onPressed: printing
                ? null
                : () => showWhatsAppReceiptDialog(context, receipt),
            icon: const Icon(Icons.chat),
            label: const Text('WhatsApp'),
          ),
          if (isSunmi)
            FilledButton.tonalIcon(
              onPressed: printing
                  ? null
                  : () async {
                      setState(() => printing = true);
                      try {
                        await ReceiptOutputService.printSunmi(receipt);
                        if (context.mounted) {
                          showMessage(context, 'Printed through SUNMI printer');
                        }
                      } catch (error) {
                        if (context.mounted)
                          showMessage(context, cleanError(error));
                      } finally {
                        if (context.mounted) setState(() => printing = false);
                      }
                    },
              icon: printing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.point_of_sale),
              label: Text(printing ? 'Printing...' : 'SUNMI Print'),
            ),
          if (!isSunmi)
            FilledButton.icon(
              onPressed: printing
                  ? null
                  : () async {
                      setState(() => printing = true);
                      try {
                        await ReceiptOutputService.printNative(receipt);
                      } catch (error) {
                        if (context.mounted)
                          showMessage(context, cleanError(error));
                      } finally {
                        if (context.mounted) setState(() => printing = false);
                      }
                    },
              icon: printing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.print),
              label: Text(printing ? 'Printing...' : 'Print'),
            ),
        ],
      ),
    ),
  );
}

Future<void> showWhatsAppReceiptDialog(
    BuildContext context, String receipt) async {
  final phone = TextEditingController();
  bool sending = false;
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Send Receipt via WhatsApp'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const InfoPanel(
              icon: Icons.chat,
              title: 'Direct number chat',
              body:
                  'Enter country code and number. The app opens WhatsApp directly for that number; it does not search contacts.',
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: phone,
              enabled: !sending,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.phone),
                labelText: 'Country code + number, e.g. +263771234567',
                border: OutlineInputBorder(),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: sending ? null : () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: sending
                ? null
                : () async {
                    try {
                      normalizeWhatsAppNumber(phone.text);
                    } catch (error) {
                      showMessage(context, cleanError(error));
                      return;
                    }
                    setState(() => sending = true);
                    try {
                      await ReceiptOutputService.sendWhatsApp(
                          phone.text, receipt);
                      if (context.mounted) Navigator.pop(context);
                    } catch (error) {
                      setState(() => sending = false);
                      if (context.mounted) {
                        showMessage(context,
                            '${cleanError(error)} If the number is not on WhatsApp, WhatsApp will show that in the opened chat.');
                      }
                    }
                  },
            icon: sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send),
            label: const Text('Open WhatsApp'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showStockExportDialog(BuildContext context, AppStore store) async {
  final phone = TextEditingController();
  File? savedFile;
  bool busy = false;
  String filter = 'all';
  bool pdfMode = true;
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Export Stock'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            InfoPanel(
                icon: Icons.ios_share,
                title:
                    '${store.stockFilterLabel(filter)} - ${store.catalogueWideViewEnabled ? 'All branches' : 'Current branch'}',
                body:
                    'Exports product stock only: product name, category, SKU, barcode, cost, selling price, quantity, threshold, supplier, branch, and scope.'),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'all',
                    icon: Icon(Icons.inventory_2),
                    label: Text('All')),
                ButtonSegment(
                    value: 'low',
                    icon: Icon(Icons.warning),
                    label: Text('Low')),
                ButtonSegment(
                    value: 'out',
                    icon: Icon(Icons.remove_shopping_cart),
                    label: Text('Out')),
              ],
              selected: {filter},
              onSelectionChanged:
                  busy ? null : (value) => setState(() => filter = value.first),
            ),
            const SizedBox(height: 10),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: true,
                    icon: Icon(Icons.picture_as_pdf),
                    label: Text('PDF')),
                ButtonSegment(
                    value: false,
                    icon: Icon(Icons.table_chart),
                    label: Text('CSV')),
              ],
              selected: {pdfMode},
              onSelectionChanged: busy
                  ? null
                  : (value) => setState(() => pdfMode = value.first),
            ),
            if (savedFile != null) ...[
              const SizedBox(height: 10),
              SelectableText(savedFile!.path,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            if (pdfMode)
              const WarningPanel(
                  text:
                      'PDF opens the Android share screen. Choose WhatsApp there to send the actual PDF file.')
            else
              TextFormField(
                controller: phone,
                enabled: !busy,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.phone),
                  labelText: 'WhatsApp number, e.g. +263771234567',
                  border: OutlineInputBorder(),
                ),
              ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('Close')),
          OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      try {
                        if (pdfMode) {
                          final bytes = await ReceiptOutputService.buildPdf(
                              store.stockReportText(filter: filter),
                              brandedReport: true);
                          final dir = await getApplicationDocumentsDirectory();
                          final filename =
                              'light-winter-${filter}-stock-${localDateKey(DateTime.now())}.pdf';
                          savedFile = File(
                              '${dir.path}${Platform.pathSeparator}$filename');
                          await savedFile!.writeAsBytes(bytes);
                        } else {
                          savedFile = await ReceiptOutputService.saveCsv(
                              store.exportCurrentStockCsv(filter: filter),
                              filename:
                                  'light-winter-${filter}-stock-${localDateKey(DateTime.now())}.csv');
                        }
                        await Clipboard.setData(
                            ClipboardData(text: savedFile!.path));
                        if (context.mounted) {
                          showMessage(context,
                              '${pdfMode ? 'PDF' : 'CSV'} saved. File path copied.');
                        }
                      } catch (error) {
                        if (context.mounted) {
                          showMessage(context, cleanError(error));
                        }
                      } finally {
                        if (context.mounted) setState(() => busy = false);
                      }
                    },
              icon: const Icon(Icons.save_alt),
              label: const Text('Save')),
          OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      try {
                        if (pdfMode) {
                          await ReceiptOutputService.sharePdf(
                              store.stockReportText(filter: filter),
                              filename:
                                  'light-winter-${filter}-stock-report.pdf',
                              brandedReport: true);
                        } else {
                          final uri = Uri.parse(
                              'mailto:?subject=${Uri.encodeComponent('Light Winter ${store.stockFilterLabel(filter)} Stock CSV')}&body=${Uri.encodeComponent(store.exportCurrentStockCsv(filter: filter))}');
                          final opened = await launchUrl(uri,
                              mode: LaunchMode.externalApplication);
                          if (!opened)
                            throw StateError('Email app not opened.');
                        }
                      } catch (error) {
                        if (context.mounted) {
                          showMessage(context, cleanError(error));
                        }
                      } finally {
                        if (context.mounted) setState(() => busy = false);
                      }
                    },
              icon: const Icon(Icons.email),
              label: Text(pdfMode ? 'Share PDF' : 'Email CSV')),
          FilledButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      try {
                        if (pdfMode) {
                          await ReceiptOutputService.sharePdf(
                              store.stockReportText(filter: filter),
                              filename:
                                  'light-winter-${filter}-stock-report.pdf',
                              brandedReport: true);
                        } else {
                          await ReceiptOutputService.sendWhatsApp(phone.text,
                              store.exportCurrentStockCsv(filter: filter));
                        }
                      } catch (error) {
                        if (context.mounted) {
                          showMessage(context, cleanError(error));
                        }
                      } finally {
                        if (context.mounted) setState(() => busy = false);
                      }
                    },
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chat),
              label: Text(pdfMode ? 'Share PDF / WhatsApp' : 'WhatsApp CSV')),
        ],
      ),
    ),
  );
}

Future<void> showAccountingEntryDialog(BuildContext context, AppStore store,
    {required AccountingEntryType type}) async {
  final amount = TextEditingController();
  final description = TextEditingController();
  final counterparty = TextEditingController();
  final customCategory = TextEditingController();
  String paymentMethod = 'Cash';
  String category =
      type == AccountingEntryType.expense ? 'Rent' : 'Owner cash injection';
  final expenseCategories = [
    'Rent',
    'Wages',
    'Transport',
    'Electricity',
    'Internet / airtime',
    'Packaging',
    'Repairs',
    'Bank charges',
    'Marketing',
    'Licenses',
    'Owner drawings',
    'Other'
  ];
  final incomeCategories = [
    'Owner cash injection',
    'Owner capital',
    'Service income',
    'Delivery fee',
    'Commission',
    'Refund received',
    'Other'
  ];
  final categories = type == AccountingEntryType.expense
      ? expenseCategories
      : incomeCategories;
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(type == AccountingEntryType.expense
            ? 'Add Expense'
            : 'Add Other Income'),
        content: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: category,
                isExpanded: true,
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.category),
                    labelText: 'Category',
                    border: OutlineInputBorder()),
                items: categories
                    .map((item) => DropdownMenuItem(
                        value: item,
                        child: Text(item,
                            maxLines: 1, overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: (value) =>
                    setState(() => category = value ?? category),
              ),
              if (category == 'Other') ...[
                const SizedBox(height: 10),
                Field(
                    controller: customCategory,
                    label: 'Custom category',
                    icon: Icons.edit),
              ],
              const SizedBox(height: 10),
              Field(
                  controller: description,
                  label: type == AccountingEntryType.expense
                      ? 'Expense description'
                      : 'Income description',
                  icon: Icons.notes,
                  required: true),
              Field(
                  controller: amount,
                  label: 'Amount in ${store.displayCurrency}',
                  icon: Icons.payments,
                  required: true,
                  keyboardType: TextInputType.number),
              Field(
                  controller: counterparty,
                  label: type == AccountingEntryType.expense
                      ? 'Paid to / supplier'
                      : 'Received from',
                  icon: Icons.person),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: paymentMethod,
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.wallet),
                    labelText: 'Payment method',
                    border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                  DropdownMenuItem(value: 'Card', child: Text('Card')),
                  DropdownMenuItem(
                      value: 'Mobile money', child: Text('Mobile money')),
                  DropdownMenuItem(
                      value: 'Bank transfer', child: Text('Bank transfer')),
                  DropdownMenuItem(value: 'Other', child: Text('Other')),
                ],
                onChanged: (value) =>
                    setState(() => paymentMethod = value ?? paymentMethod),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () async {
                final cents = store.displayAmountToBaseCents(amount.text);
                final label =
                    category == 'Other' && customCategory.text.trim().isNotEmpty
                        ? customCategory.text.trim()
                        : category;
                if (description.text.trim().isEmpty || cents <= 0) {
                  showMessage(context, 'Enter a description and valid amount.');
                  return;
                }
                await store.addAccountingEntry(AccountingEntry(
                    id: newId(),
                    branchId: store.assignedBranchId ?? '',
                    type: type,
                    category: label,
                    description: description.text.trim(),
                    amountCents: cents,
                    paymentMethod: paymentMethod,
                    counterparty: counterparty.text.trim(),
                    createdAt: DateTime.now()));
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Save')),
        ],
      ),
    ),
  );
}

Future<void> showStockPurchaseDialog(
    BuildContext context, AppStore store) async {
  Product? product = store.products.isEmpty ? null : store.products.first;
  final manualProduct = TextEditingController();
  final supplier = TextEditingController();
  final quantity = TextEditingController(text: '1');
  final total = TextEditingController();
  final paid = TextEditingController(text: '0');
  final batch = TextEditingController();
  DateTime? expiryDate;
  String paymentMethod = 'Cash';
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Record Stock Purchase'),
        content: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (store.products.isNotEmpty)
                DropdownButtonFormField<String>(
                  value: product?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.inventory_2),
                      labelText: 'Product to restock',
                      border: OutlineInputBorder()),
                  items: store.products
                      .map((item) => DropdownMenuItem(
                          value: item.id,
                          child: Text(item.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (value) => setState(() => product = store.products
                      .where((item) => item.id == value)
                      .firstOrNull),
                )
              else
                Field(
                    controller: manualProduct,
                    label: 'Product / purchase name',
                    icon: Icons.inventory_2,
                    required: true),
              const SizedBox(height: 10),
              Field(
                  controller: supplier,
                  label: 'Supplier name',
                  icon: Icons.local_shipping,
                  required: true),
              Field(
                  controller: quantity,
                  label: 'Quantity received',
                  icon: Icons.add_box,
                  keyboardType: TextInputType.number),
              Field(
                  controller: total,
                  label: 'Total invoice amount in ${store.displayCurrency}',
                  icon: Icons.receipt_long,
                  required: true,
                  keyboardType: TextInputType.number),
              Field(
                  controller: paid,
                  label: 'Amount paid now in ${store.displayCurrency}',
                  icon: Icons.payments,
                  keyboardType: TextInputType.number),
              Field(
                  controller: batch,
                  label: 'Batch number (optional)',
                  icon: Icons.qr_code_2),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await showDatePicker(
                          context: context,
                          initialDate:
                              DateTime.now().add(const Duration(days: 90)),
                          firstDate: DateTime(2020),
                          lastDate:
                              DateTime.now().add(const Duration(days: 3650)));
                      if (picked != null) setState(() => expiryDate = picked);
                    },
                    icon: const Icon(Icons.event),
                    label: Text(expiryDate == null
                        ? 'Expiry date (optional)'
                        : 'Expiry: ${shortDate(expiryDate!)}')),
              ),
              DropdownButtonFormField<String>(
                value: paymentMethod,
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.wallet),
                    labelText: 'Payment method',
                    border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                  DropdownMenuItem(value: 'Card', child: Text('Card')),
                  DropdownMenuItem(
                      value: 'Mobile money', child: Text('Mobile money')),
                  DropdownMenuItem(
                      value: 'Bank transfer', child: Text('Bank transfer')),
                ],
                onChanged: (value) =>
                    setState(() => paymentMethod = value ?? paymentMethod),
              ),
              const SizedBox(height: 8),
              const Text(
                  'If paid now is less than the invoice amount, the remaining balance becomes supplier debt.'),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton.icon(
              onPressed: () async {
                final totalCents = store.displayAmountToBaseCents(total.text);
                final paidCents = store.displayAmountToBaseCents(paid.text);
                final qty = int.tryParse(quantity.text.trim()) ?? 0;
                final name = product?.name ?? manualProduct.text.trim();
                if (name.isEmpty ||
                    supplier.text.trim().isEmpty ||
                    totalCents <= 0) {
                  showMessage(context,
                      'Choose a product, supplier, and valid invoice amount.');
                  return;
                }
                await store.recordStockPurchase(
                    product: product,
                    productName: name,
                    supplierName: supplier.text.trim(),
                    quantity: qty,
                    totalCents: totalCents,
                    paidCents: paidCents,
                    paymentMethod: paymentMethod,
                    batchNumber: batch.text.trim(),
                    expiryDate: expiryDate);
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.check_circle),
              label: const Text('Save Purchase')),
        ],
      ),
    ),
  );
}

Future<void> showSupplierPaymentDialog(
    BuildContext context, AppStore store) async {
  final supplier = TextEditingController();
  final invoiceTotal = TextEditingController();
  final paidNow = TextEditingController();
  final note = TextEditingController();
  String paymentMethod = 'Cash';
  bool busy = false;
  int supplierBalance() {
    final clean = supplier.text.trim().toLowerCase();
    if (clean.isEmpty) return 0;
    final balances = store.supplierBalanceMap(store.accountingEntries);
    for (final entry in balances.entries) {
      if (entry.key.trim().toLowerCase() == clean) return entry.value;
    }
    return 0;
  }

  int projectedBalance() {
    final current = supplierBalance();
    final newBill = store.displayAmountToBaseCents(invoiceTotal.text);
    final payment = store.displayAmountToBaseCents(paidNow.text);
    return current + max<int>(0, newBill) - max<int>(0, payment);
  }

  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Supplier Payment / Owing'),
        content: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Field(
                  controller: supplier,
                  label: 'Supplier name',
                  icon: Icons.local_shipping,
                  required: true,
                  onChanged: (_) => setState(() {})),
              Field(
                  controller: invoiceTotal,
                  label: 'New bill / goods in ${store.displayCurrency}',
                  icon: Icons.receipt_long,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {})),
              Field(
                  controller: paidNow,
                  label: 'Paid now in ${store.displayCurrency}',
                  icon: Icons.payments,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {})),
              Field(
                  controller: note,
                  label: 'Note / invoice number',
                  icon: Icons.note_alt),
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: const Color(0xFFE8F3F0),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFB7D7D1))),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'Current owing: ${store.moneyFor(supplierBalance())}',
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      Text(
                          'After saving: ${store.moneyFor(projectedBalance())}',
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      const Text(
                          'Leave the new bill blank when only paying old supplier owing.',
                          style: TextStyle(fontSize: 12)),
                    ]),
              ),
              DropdownButtonFormField<String>(
                value: paymentMethod,
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.wallet),
                    labelText: 'Payment method',
                    border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                  DropdownMenuItem(value: 'Card', child: Text('Card')),
                  DropdownMenuItem(
                      value: 'Mobile money', child: Text('Mobile money')),
                  DropdownMenuItem(
                      value: 'Bank transfer', child: Text('Bank transfer')),
                ],
                onChanged: (value) =>
                    setState(() => paymentMethod = value ?? paymentMethod),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      final billCents =
                          store.displayAmountToBaseCents(invoiceTotal.text);
                      final paidCents =
                          store.displayAmountToBaseCents(paidNow.text);
                      final cleanSupplier = supplier.text.trim();
                      final cleanNote = note.text.trim();
                      if (cleanSupplier.isEmpty ||
                          (billCents <= 0 && paidCents <= 0)) {
                        showMessage(context,
                            'Enter supplier name, bill amount, or payment amount.');
                        return;
                      }
                      if (billCents > 0 && paidCents > billCents) {
                        showMessage(context,
                            'Paid now cannot be more than the new bill. To pay old owing, leave the new bill blank.');
                        return;
                      }
                      setState(() => busy = true);
                      try {
                        final now = DateTime.now();
                        if (billCents > 0) {
                          await store.addAccountingEntry(AccountingEntry(
                              id: newId(),
                              branchId: store.assignedBranchId ?? '',
                              type: AccountingEntryType.expense,
                              category: 'Stock Purchase',
                              description: cleanNote.isEmpty
                                  ? 'Supplier bill / goods received'
                                  : 'Supplier bill / goods received - $cleanNote',
                              amountCents: billCents,
                              paymentMethod: paidCents >= billCents
                                  ? paymentMethod
                                  : 'Supplier debt',
                              counterparty: cleanSupplier,
                              createdAt: now));
                        }
                        if (paidCents > 0) {
                          await store.addAccountingEntry(AccountingEntry(
                              id: newId(),
                              branchId: store.assignedBranchId ?? '',
                              type: AccountingEntryType.expense,
                              category: 'Supplier Payment',
                              description: cleanNote.isEmpty
                                  ? 'Supplier payment'
                                  : 'Supplier payment - $cleanNote',
                              amountCents: paidCents,
                              paymentMethod: paymentMethod,
                              counterparty: cleanSupplier,
                              createdAt:
                                  now.add(const Duration(milliseconds: 1))));
                        }
                        if (context.mounted) Navigator.pop(context);
                      } catch (error) {
                        if (context.mounted)
                          showMessage(context, cleanError(error));
                      } finally {
                        if (context.mounted) setState(() => busy = false);
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save Supplier Record')),
        ],
      ),
    ),
  );
}

Future<void> showPayrollDialog(BuildContext context, AppStore store) async {
  final employee = TextEditingController();
  final role = TextEditingController();
  final period = TextEditingController(
      text:
          '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}');
  final gross = TextEditingController();
  final deductions = TextEditingController(text: '0');
  final note = TextEditingController();
  String paymentMethod = 'Cash';
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Payroll / Light HR'),
        content: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Field(
                  controller: employee,
                  label: 'Employee name',
                  icon: Icons.person,
                  required: true),
              Field(
                  controller: role,
                  label: 'Role / position',
                  icon: Icons.badge),
              Field(
                  controller: period,
                  label: 'Pay period',
                  icon: Icons.calendar_month,
                  required: true),
              Field(
                  controller: gross,
                  label: 'Gross pay in ${store.displayCurrency}',
                  icon: Icons.payments,
                  required: true,
                  keyboardType: TextInputType.number),
              Field(
                  controller: deductions,
                  label: 'Deductions in ${store.displayCurrency}',
                  icon: Icons.remove_circle,
                  keyboardType: TextInputType.number),
              Field(controller: note, label: 'Notes', icon: Icons.note_alt),
              DropdownButtonFormField<String>(
                value: paymentMethod,
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.wallet),
                    labelText: 'Payment method',
                    border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                  DropdownMenuItem(
                      value: 'Bank transfer', child: Text('Bank transfer')),
                  DropdownMenuItem(
                      value: 'Mobile money', child: Text('Mobile money')),
                ],
                onChanged: (value) =>
                    setState(() => paymentMethod = value ?? paymentMethod),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton.icon(
            onPressed: () async {
              final grossCents = store.displayAmountToBaseCents(gross.text);
              final deductionCents =
                  store.displayAmountToBaseCents(deductions.text);
              final netCents = max(0, grossCents - deductionCents);
              if (employee.text.trim().isEmpty || grossCents <= 0) {
                showMessage(
                    context, 'Enter employee name and valid gross pay.');
                return;
              }
              await store.addAccountingEntry(AccountingEntry(
                  id: newId(),
                  branchId: store.assignedBranchId ?? '',
                  type: AccountingEntryType.expense,
                  category: 'Payroll',
                  description:
                      '${period.text.trim()} | ${role.text.trim().isEmpty ? 'Employee' : role.text.trim()} | Gross ${store.moneyFor(grossCents)} | Deductions ${store.moneyFor(deductionCents)}${note.text.trim().isEmpty ? '' : ' | ${note.text.trim()}'}',
                  amountCents: netCents,
                  paymentMethod: paymentMethod,
                  counterparty: employee.text.trim(),
                  createdAt: DateTime.now()));
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.check_circle),
            label: const Text('Save Payroll'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showPurchaseOrderDialog(
    BuildContext context, AppStore store) async {
  Product? product = store.products.isEmpty ? null : store.products.first;
  final manualProduct = TextEditingController();
  final supplier = TextEditingController();
  final quantity = TextEditingController(text: '1');
  final amount = TextEditingController();
  final note = TextEditingController();
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Create Purchase Order'),
        content: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (store.products.isNotEmpty)
                DropdownButtonFormField<String>(
                  value: product?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.inventory_2),
                      labelText: 'Product',
                      border: OutlineInputBorder()),
                  items: store.products
                      .map((item) => DropdownMenuItem(
                          value: item.id,
                          child: Text(item.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (value) => setState(() => product = store.products
                      .where((item) => item.id == value)
                      .firstOrNull),
                )
              else
                Field(
                    controller: manualProduct,
                    label: 'Product name',
                    icon: Icons.inventory_2,
                    required: true),
              const SizedBox(height: 10),
              Field(
                  controller: supplier,
                  label: 'Supplier',
                  icon: Icons.local_shipping,
                  required: true),
              Field(
                  controller: quantity,
                  label: 'Quantity ordered',
                  icon: Icons.add_box,
                  keyboardType: TextInputType.number),
              Field(
                  controller: amount,
                  label: 'Expected amount in ${store.displayCurrency}',
                  icon: Icons.payments,
                  keyboardType: TextInputType.number),
              Field(controller: note, label: 'Note', icon: Icons.notes),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () async {
                final name = product?.name ?? manualProduct.text.trim();
                final qty = int.tryParse(quantity.text.trim()) ?? 0;
                final cents = store.displayAmountToBaseCents(amount.text);
                if (name.isEmpty || supplier.text.trim().isEmpty || qty <= 0) {
                  showMessage(context,
                      'Enter product, supplier, and quantity ordered.');
                  return;
                }
                await store.addAccountingEntry(AccountingEntry(
                    id: newId(),
                    branchId: store.assignedBranchId ?? '',
                    type: AccountingEntryType.expense,
                    category: 'Purchase Order',
                    description:
                        'Order $qty x $name${note.text.trim().isEmpty ? '' : ' - ${note.text.trim()}'}',
                    amountCents: cents,
                    paymentMethod: 'Not received',
                    counterparty: supplier.text.trim(),
                    createdAt: DateTime.now()));
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Save Order')),
        ],
      ),
    ),
  );
}

Future<void> showStockCountDialog(BuildContext context, AppStore store) async {
  Product? product = store.branchScopedProducts.isEmpty
      ? null
      : store.branchScopedProducts.first;
  final counted = TextEditingController();
  final reason = TextEditingController(text: 'Physical stock count');
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Stock Count'),
        content: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: product?.id,
                isExpanded: true,
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.fact_check),
                    labelText: 'Product counted',
                    border: OutlineInputBorder()),
                items: store.branchScopedProducts
                    .map((item) => DropdownMenuItem(
                        value: item.id,
                        child: Text(item.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: (value) => setState(() => product = store
                    .branchScopedProducts
                    .where((item) => item.id == value)
                    .firstOrNull),
              ),
              const SizedBox(height: 10),
              Field(
                  controller: counted,
                  label: 'Physical quantity counted',
                  icon: Icons.numbers,
                  required: true,
                  keyboardType: TextInputType.number),
              Field(
                  controller: reason,
                  label: 'Reason',
                  icon: Icons.notes,
                  required: true),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: product == null
                  ? null
                  : () async {
                      final qty = int.tryParse(counted.text.trim());
                      if (qty == null ||
                          qty < 0 ||
                          reason.text.trim().isEmpty) {
                        showMessage(context,
                            'Enter counted quantity and adjustment reason.');
                        return;
                      }
                      await store.recordStockCount(
                          product: product!,
                          countedQuantity: qty,
                          reason: reason.text.trim());
                      if (context.mounted) Navigator.pop(context);
                    },
              child: const Text('Save Count')),
        ],
      ),
    ),
  );
}

Future<void> showCashUpDialog(
    BuildContext context, AppStore store, ProfitLossStatement statement) async {
  final counted = TextEditingController();
  final note = TextEditingController();
  final expectedCash = statement.cashbookByMethod['Cash in']! -
      statement.cashbookByMethod['Cash out']!;
  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Daily Cash-Up'),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Expected cash: ${store.moneyFor(expectedCash)}',
                style: const TextStyle(fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            Field(
                controller: counted,
                label: 'Actual counted cash in ${store.displayCurrency}',
                icon: Icons.point_of_sale,
                required: true,
                keyboardType: TextInputType.number),
            Field(controller: note, label: 'Note', icon: Icons.notes),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () async {
              final countedCents = store.displayAmountToBaseCents(counted.text);
              final difference = countedCents - expectedCash;
              await store.addAccountingEntry(AccountingEntry(
                  id: newId(),
                  branchId: store.assignedBranchId ?? '',
                  type: AccountingEntryType.expense,
                  category: 'Cash-Up',
                  description:
                      'Expected ${store.moneyFor(expectedCash)}, counted ${store.moneyFor(countedCents)}, difference ${store.moneyFor(difference)}${note.text.trim().isEmpty ? '' : ' - ${note.text.trim()}'}',
                  amountCents: difference.abs(),
                  paymentMethod: difference >= 0 ? 'Surplus' : 'Shortage',
                  counterparty: store.currentUser?.name ?? '',
                  createdAt: DateTime.now()));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save Cash-Up')),
      ],
    ),
  );
}

Future<void> showReconciliationDialog(
    BuildContext context, AppStore store, ProfitLossStatement statement) async {
  final actual = TextEditingController();
  final reference = TextEditingController();
  String method = 'Bank';
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Payment Reconciliation'),
        content: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: method,
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.account_balance),
                    labelText: 'Account',
                    border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'Bank', child: Text('Bank')),
                  DropdownMenuItem(
                      value: 'Mobile money', child: Text('Mobile money')),
                  DropdownMenuItem(value: 'Card', child: Text('Card')),
                ],
                onChanged: (value) => setState(() => method = value ?? method),
              ),
              const SizedBox(height: 10),
              Field(
                  controller: actual,
                  label: 'Statement amount in ${store.displayCurrency}',
                  icon: Icons.payments,
                  required: true,
                  keyboardType: TextInputType.number),
              Field(
                  controller: reference,
                  label: 'Reference / note',
                  icon: Icons.notes),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () async {
                final amount = store.displayAmountToBaseCents(actual.text);
                if (amount <= 0) {
                  showMessage(context, 'Enter a valid statement amount.');
                  return;
                }
                await store.addAccountingEntry(AccountingEntry(
                    id: newId(),
                    branchId: store.assignedBranchId ?? '',
                    type: AccountingEntryType.income,
                    category: 'Reconciliation',
                    description:
                        '$method statement checked${reference.text.trim().isEmpty ? '' : ' - ${reference.text.trim()}'}',
                    amountCents: amount,
                    paymentMethod: method,
                    counterparty: store.currentUser?.name ?? '',
                    createdAt: DateTime.now()));
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Save')),
        ],
      ),
    ),
  );
}

Future<void> showSupplierStatementDialog(
    BuildContext context, AppStore store) async {
  final supplier = TextEditingController();
  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Supplier Statement'),
      content: Field(
          controller: supplier,
          label: 'Supplier name',
          icon: Icons.local_shipping,
          required: true),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton.icon(
            onPressed: () async {
              if (supplier.text.trim().isEmpty) {
                showMessage(context, 'Enter supplier name.');
                return;
              }
              await ReceiptOutputService.sharePdf(
                  store.supplierStatementText(supplier.text.trim()),
                  filename: 'light-winter-supplier-statement.pdf',
                  brandedReport: true);
              if (context.mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.picture_as_pdf),
            label: const Text('PDF / WhatsApp')),
      ],
    ),
  );
}

Future<void> showCustomerStatementDialog(
    BuildContext context, AppStore store) async {
  SaleRecord? sale =
      store.allKnownDebtSales.isEmpty ? null : store.allKnownDebtSales.first;
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Customer Statement'),
        content: DropdownButtonFormField<String>(
          value: sale?.id,
          isExpanded: true,
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.person),
              labelText: 'Customer / debt sale',
              border: OutlineInputBorder()),
          items: store.allKnownDebtSales
              .map((item) => DropdownMenuItem(
                  value: item.id,
                  child: Text(
                      '${item.customerName.isEmpty ? 'Customer' : item.customerName} | ${shortDateTime(item.createdAt)} | ${store.moneyFor(store.debtBalanceForSale(item))}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged: (value) => setState(() => sale = store.allKnownDebtSales
              .where((item) => item.id == value)
              .firstOrNull),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton.icon(
              onPressed: sale == null
                  ? null
                  : () async {
                      await ReceiptOutputService.sharePdf(
                          store.customerStatementText(sale!),
                          filename: 'light-winter-customer-statement.pdf',
                          brandedReport: true);
                      if (context.mounted) Navigator.pop(context);
                    },
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('PDF / WhatsApp')),
        ],
      ),
    ),
  );
}

Future<void> showCustomerHistoryDialog(
    BuildContext context, AppStore store) async {
  Customer? customer = store.customers.isEmpty ? null : store.customers.first;
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Customer Purchase History'),
        content: DropdownButtonFormField<String>(
          value: customer?.id,
          isExpanded: true,
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.person_search),
              labelText: 'Customer',
              border: OutlineInputBorder()),
          items: store.customers
              .map((item) => DropdownMenuItem(
                  value: item.id,
                  child: Text('${item.code} | ${item.name}',
                      maxLines: 1, overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged: (value) => setState(() => customer =
              store.customers.where((item) => item.id == value).firstOrNull),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton.icon(
              onPressed: customer == null
                  ? null
                  : () async {
                      await ReceiptOutputService.sharePdf(
                          store.customerPurchaseHistoryText(customer!.name),
                          filename:
                              'light-winter-customer-purchase-history.pdf',
                          brandedReport: true);
                      if (context.mounted) Navigator.pop(context);
                    },
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('PDF / WhatsApp')),
        ],
      ),
    ),
  );
}

Future<void> showOldReceiptDialog(BuildContext context, AppStore store) async {
  SaleRecord? sale =
      store.allKnownSales.isEmpty ? null : store.allKnownSales.first;
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Old Receipt'),
        content: DropdownButtonFormField<String>(
          value: sale?.id,
          isExpanded: true,
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.receipt),
              labelText: 'Sale receipt',
              border: OutlineInputBorder()),
          items: store.allKnownSales
              .take(200)
              .map((item) => DropdownMenuItem(
                  value: item.id,
                  child: Text(
                      '${shortDateTime(item.createdAt)} | ${item.customerName.isEmpty ? item.paymentMethod : item.customerName} | ${store.moneyFor(item.totalCents)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged: (value) =>
              setState(() => sale = store.saleById(value ?? '')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          OutlinedButton.icon(
              onPressed: sale == null
                  ? null
                  : () async {
                      await ReceiptOutputService.sharePdf(
                          store.receiptText(sale!),
                          filename: 'light-winter-receipt-${sale!.id}.pdf');
                    },
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('PDF / WhatsApp')),
          FilledButton.icon(
              onPressed: sale == null
                  ? null
                  : () async {
                      await ReceiptOutputService.printNative(
                          store.receiptText(sale!));
                    },
              icon: const Icon(Icons.print),
              label: const Text('Print')),
        ],
      ),
    ),
  );
}

Future<void> showCustomItemDialog(BuildContext context, AppStore store) async {
  final name = TextEditingController();
  final price = TextEditingController();
  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Add Custom Item'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Field(
              controller: name,
              label: 'Item name',
              icon: Icons.add_box,
              required: true),
          Field(
              controller: price,
              label: 'Price in USD, e.g. 1.50',
              icon: Icons.attach_money,
              required: true,
              keyboardType: TextInputType.number),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final cents = parseMoneyCents(price.text);
            if (name.text.trim().isEmpty || cents <= 0) return;
            store.addCustomItem(name.text.trim(), cents);
            Navigator.pop(context);
          },
          child: const Text('Add'),
        ),
      ],
    ),
  );
}

Future<SaleRecord?> showCheckoutDialog(
    BuildContext context, AppStore store) async {
  String paymentMethod = 'Cash';
  String currency = store.posCurrency;
  final discount = TextEditingController(text: '0');
  final paid = TextEditingController(
      text: ((store.cartTotalCents / 100) *
              (store.exchangeRates[store.posCurrency] ?? 1))
          .toStringAsFixed(2));
  final splitCash = TextEditingController(text: '0');
  final splitCard = TextEditingController(text: '0');
  final splitMobile = TextEditingController(text: '0');
  final customerName = TextEditingController();
  final customerPhone = TextEditingController();
  bool completing = false;
  bool reviewing = false;

  return showDialog<SaleRecord>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final discountCents =
            store.displayAmountToBaseCents(discount.text, currency: currency);
        final totalCents =
            (store.cartTotalCents - discountCents).clamp(0, 1 << 31).toInt();
        final splitCashCents =
            store.displayAmountToBaseCents(splitCash.text, currency: currency);
        final splitCardCents =
            store.displayAmountToBaseCents(splitCard.text, currency: currency);
        final splitMobileCents = store
            .displayAmountToBaseCents(splitMobile.text, currency: currency);
        final splitTotalCents =
            splitCashCents + splitCardCents + splitMobileCents;
        final paidCents = paymentMethod == 'Split'
            ? splitTotalCents
            : store.displayAmountToBaseCents(paid.text, currency: currency);
        final debtCents = (totalCents - paidCents).clamp(0, 1 << 31).toInt();
        final changeCents = (paidCents - totalCents).clamp(0, 1 << 31).toInt();
        return AlertDialog(
          title: Text(reviewing ? 'Review Sale' : 'Checkout'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const InfoPanel(
                  icon: Icons.fact_check,
                  title: 'Payment record only',
                  body:
                      'Cash, card, and mobile money are recorded for reports. The app is not processing bank card or wallet payments here.',
                ),
                const SizedBox(height: 12),
                if (!reviewing)
                  Wrap(
                    spacing: 8,
                    children: ['USD', 'ZWL', 'ZAR', 'BWP']
                        .map((code) => ChoiceChip(
                              label: Text(code),
                              selected: currency == code,
                              onSelected: completing
                                  ? null
                                  : (_) => setState(() {
                                        currency = code;
                                        store.setPosCurrency(code);
                                        paid.text = ((totalCents / 100) *
                                                (store.exchangeRates[code] ??
                                                    1))
                                            .toStringAsFixed(2);
                                      }),
                            ))
                        .toList(),
                  ),
                if (!reviewing) const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: paymentMethod,
                  items: const ['Cash', 'Card', 'Mobile Money', 'Split', 'Debt']
                      .map((item) =>
                          DropdownMenuItem(value: item, child: Text(item)))
                      .toList(),
                  onChanged: completing || reviewing
                      ? null
                      : (value) => setState(() {
                            paymentMethod = value ?? 'Cash';
                          }),
                  decoration: const InputDecoration(
                      labelText: 'Payment mode used',
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TextFormField(
                    controller: discount,
                    enabled: !completing && !reviewing,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.currency_exchange),
                        labelText: 'Discount in $currency',
                        border: const OutlineInputBorder()),
                  ),
                ),
                Text('Discount currency: $currency',
                    style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(height: 8),
                if (paymentMethod == 'Debt') ...[
                  Field(
                      controller: customerName,
                      label: 'Debt customer name',
                      icon: Icons.person,
                      required: true),
                  Field(
                      controller: customerPhone,
                      label: 'Customer phone',
                      icon: Icons.phone),
                ],
                if (paymentMethod == 'Split') ...[
                  Field(
                      controller: splitCash,
                      label: 'Cash amount in $currency',
                      icon: Icons.payments,
                      keyboardType: TextInputType.number),
                  Field(
                      controller: splitCard,
                      label: 'Card amount in $currency',
                      icon: Icons.credit_card,
                      keyboardType: TextInputType.number),
                  Field(
                      controller: splitMobile,
                      label: 'Mobile money amount in $currency',
                      icon: Icons.phone_android,
                      keyboardType: TextInputType.number),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TextFormField(
                      controller: paid,
                      enabled: !completing && !reviewing,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.payments),
                          labelText: paymentMethod == 'Debt'
                              ? 'Amount paid now in $currency'
                              : 'Amount received in $currency',
                          border: const OutlineInputBorder()),
                    ),
                  ),
                const Divider(height: 24),
                TotalRow(
                    label: 'Subtotal',
                    value: store.moneyFor(store.cartTotalCents,
                        currency: currency)),
                TotalRow(
                    label: 'Discount',
                    value: store.moneyFor(discountCents, currency: currency)),
                TotalRow(
                    label: 'Total',
                    value: store.moneyFor(totalCents, currency: currency),
                    bold: true),
                TotalRow(
                    label: 'Paid',
                    value: store.moneyFor(paidCents, currency: currency)),
                TotalRow(
                    label: 'Change',
                    value: store.moneyFor(changeCents, currency: currency)),
                TotalRow(
                    label: 'Debt',
                    value: store.moneyFor(debtCents, currency: currency)),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed:
                    completing ? null : () => Navigator.pop(context, null),
                child: Text(reviewing ? 'Cancel' : 'Back')),
            if (reviewing)
              OutlinedButton(
                onPressed:
                    completing ? null : () => setState(() => reviewing = false),
                child: const Text('Edit Sale'),
              ),
            FilledButton(
              onPressed: completing
                  ? null
                  : () async {
                      if (paymentMethod == 'Debt' &&
                          customerName.text.trim().isEmpty) {
                        showMessage(
                            context, 'Customer name is required for debt.');
                        return;
                      }
                      if (store.discountExceedsCashierLimit(discountCents)) {
                        showMessage(context,
                            'Discount is above cashier limit. Ask owner/manager.');
                        return;
                      }
                      if (!reviewing) {
                        setState(() => reviewing = true);
                        return;
                      }
                      setState(() => completing = true);
                      try {
                        Customer? customer;
                        if (paymentMethod == 'Debt') {
                          customer = await store.addCustomer(
                              customerName.text.trim(),
                              customerPhone.text.trim());
                        }
                        final sale = await store.checkout(
                          paymentMethod == 'Split'
                              ? 'Split: Cash ${store.moneyFor(splitCashCents, currency: currency)}, Card ${store.moneyFor(splitCardCents, currency: currency)}, Mobile ${store.moneyFor(splitMobileCents, currency: currency)}'
                              : paymentMethod,
                          customer: customer,
                          discountCents: discountCents,
                          paidCents: paidCents,
                          changeCents: changeCents,
                          debtCents: debtCents,
                        );
                        if (context.mounted) Navigator.pop(context, sale);
                      } catch (error) {
                        setState(() => completing = false);
                        if (context.mounted) {
                          showMessage(context, cleanError(error));
                        }
                      }
                    },
              child: completing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(reviewing ? 'Confirm and Record' : 'Review'),
            ),
          ],
        );
      },
    ),
  );
}

Future<void> showCartQuantityDialog(
    BuildContext context, AppStore store, CartItem item) async {
  final quantity = TextEditingController(text: '${item.quantity}');
  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Quantity - ${item.product.name}'),
      content: Field(
          controller: quantity,
          label: 'Quantity',
          icon: Icons.numbers,
          required: true,
          keyboardType: TextInputType.number),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () {
              final qty = int.tryParse(quantity.text.trim());
              if (qty == null || qty < 0) {
                showMessage(context, 'Enter a valid quantity.');
                return;
              }
              store.setCartItemQuantity(item, qty);
              Navigator.pop(context);
            },
            child: const Text('Set Quantity')),
      ],
    ),
  );
}

Future<void> showProductDialog(BuildContext context, AppStore store,
    {Product? product}) async {
  final editing = product != null;
  final name = TextEditingController(text: product?.name ?? '');
  final category = TextEditingController(text: product?.category ?? '');
  final sku = TextEditingController(text: product?.sku ?? '');
  final barcode = TextEditingController(text: product?.barcode ?? '');
  final cost = TextEditingController(
      text: product == null || product.costCents <= 0
          ? ''
          : (product.costCents / 100).toStringAsFixed(2));
  final price = TextEditingController(
      text:
          product == null ? '' : (product.priceCents / 100).toStringAsFixed(2));
  final stock = TextEditingController(text: '${product?.stock ?? 0}');
  final reorder = TextEditingController(text: '${product?.reorderLevel ?? 5}');
  String supplierId = product?.supplierId ?? '';
  final categories = store.products
      .map((item) => item.category.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList()
    ..sort();
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(editing ? 'Edit Product' : 'Add Product'),
        content: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Field(
                  controller: name,
                  label: 'Product name',
                  icon: Icons.inventory_2,
                  required: true),
              Field(
                  controller: category,
                  label: 'Category',
                  icon: Icons.category),
              if (categories.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: categories
                        .take(8)
                        .map((item) => ActionChip(
                            label: Text(item),
                            onPressed: () =>
                                setState(() => category.text = item)))
                        .toList(),
                  ),
                ),
              Field(controller: sku, label: 'SKU', icon: Icons.tag),
              Field(controller: barcode, label: 'Barcode', icon: Icons.qr_code),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final value = await showManualTextPad(context,
                        title: 'Type Barcode',
                        initialValue: barcode.text,
                        allowLetters: true);
                    if (value != null) barcode.text = value;
                  },
                  icon: const Icon(Icons.keyboard),
                  label: const Text('Type Barcode Manually'),
                ),
              ),
              const SizedBox(height: 10),
              Field(
                  controller: cost,
                  label: 'Buying cost in USD',
                  icon: Icons.shopping_bag,
                  keyboardType: TextInputType.number),
              Field(
                  controller: price,
                  label: 'Selling price in USD',
                  icon: Icons.attach_money,
                  required: true,
                  keyboardType: TextInputType.number),
              Field(
                  controller: stock,
                  label: editing ? 'Current stock' : 'Initial stock',
                  icon: Icons.numbers,
                  keyboardType: TextInputType.number),
              Field(
                  controller: reorder,
                  label: 'Low threshold',
                  icon: Icons.warning,
                  keyboardType: TextInputType.number),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: supplierId.isEmpty ? '' : supplierId,
                isExpanded: true,
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.local_shipping),
                    labelText: 'Supplier',
                    border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem(value: '', child: Text('No supplier')),
                  ...store.suppliers.map((supplier) => DropdownMenuItem(
                      value: supplier.id,
                      child: Text(supplier.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis))),
                ],
                onChanged: (value) => setState(() => supplierId = value ?? ''),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final productName = name.text.trim();
              final cents = parseMoneyCents(price.text);
              final costCents = parseMoneyCents(cost.text);
              if (productName.isEmpty || cents <= 0) {
                showMessage(
                    context, 'Product name and valid price are required.');
                return;
              }
              final next = Product(
                  id: product?.id ?? newId(),
                  name: productName,
                  category: category.text.trim(),
                  sku: sku.text.trim(),
                  barcode: barcode.text.trim(),
                  priceCents: cents,
                  costCents: costCents,
                  stock: int.tryParse(stock.text.trim()) ?? 0,
                  reorderLevel: int.tryParse(reorder.text.trim()) ?? 5,
                  supplierId: supplierId);
              if (editing) {
                await store.updateProduct(next);
              } else {
                await store.addProduct(next);
              }
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showSupplierDialog(BuildContext context, AppStore store,
    {Supplier? supplier}) async {
  final editing = supplier != null;
  final name = TextEditingController(text: supplier?.name ?? '');
  final phone = TextEditingController(text: supplier?.phone ?? '');
  final notes = TextEditingController(text: supplier?.notes ?? '');
  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(editing ? 'Edit Supplier' : 'Add Supplier'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Field(
              controller: name,
              label: 'Supplier name',
              icon: Icons.local_shipping,
              required: true),
          Field(
              controller: phone, label: 'Phone (optional)', icon: Icons.phone),
          Field(
              controller: notes, label: 'Notes (optional)', icon: Icons.notes),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) {
                showMessage(context, 'Supplier name is required.');
                return;
              }
              final next = Supplier(
                  id: supplier?.id ?? newId(),
                  name: name.text.trim(),
                  phone: phone.text.trim(),
                  notes: notes.text.trim());
              if (editing) {
                await store.updateSupplier(next);
              } else {
                await store.addSupplier(next);
              }
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save')),
      ],
    ),
  );
}

String supplierName(AppStore store, String supplierId) {
  if (supplierId.trim().isEmpty) return '';
  for (final supplier in store.suppliers) {
    if (supplier.id == supplierId) return supplier.name;
  }
  return '';
}

String branchAccessLabel(AppStore store, AppUser user) {
  if (user.isOwner || user.hasAllPrivileges) return 'All branches';
  if (user.branchIds.isEmpty) return 'No branch assigned';
  final names = user.branchIds.map((branchId) {
    return store.branches
            .where((branch) => branch.id == branchId)
            .firstOrNull
            ?.name ??
        branchId;
  }).toList();
  return names.join(', ');
}

Future<void> showCategorySummaryDialog(
    BuildContext context, AppStore store) async {
  final categories = <String, int>{};
  for (final product in store.products) {
    final category =
        product.category.trim().isEmpty ? 'Uncategorised' : product.category;
    categories[category] = (categories[category] ?? 0) + 1;
  }
  final entries = categories.entries.toList()
    ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Product Categories'),
      content: SizedBox(
        width: 420,
        child: entries.isEmpty
            ? const Text('No categories yet.')
            : ListView.separated(
                shrinkWrap: true,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.category),
                    title: Text(entry.key),
                    trailing: Text('${entry.value}',
                        style: const TextStyle(fontWeight: FontWeight.w900)),
                  );
                },
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemCount: entries.length,
              ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ],
    ),
  );
}

Future<void> showStockBulkDeleteDialog(
    BuildContext context, AppStore store) async {
  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete Stock Data'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const WarningPanel(
              text:
                  'Bulk deletion is permanent on this device and clears related open POS carts. Use this only before a fresh import or when correcting setup data.'),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.inventory_2),
            title: const Text('Delete all products'),
            subtitle:
                Text('${store.products.length} products will be removed.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final confirmed = await confirmTypedDelete(
                  context,
                  'Delete all products?',
                  'Type DELETE PRODUCTS to remove every product and clear open carts.',
                  'DELETE PRODUCTS');
              if (!confirmed) return;
              await store.deleteAllProducts();
              if (context.mounted) Navigator.pop(context);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.local_shipping),
            title: const Text('Delete all suppliers'),
            subtitle:
                Text('${store.suppliers.length} suppliers will be removed.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final confirmed = await confirmTypedDelete(
                  context,
                  'Delete all suppliers?',
                  'Type DELETE SUPPLIERS to remove every supplier and clear supplier links on products.',
                  'DELETE SUPPLIERS');
              if (!confirmed) return;
              await store.deleteAllSuppliers();
              if (context.mounted) Navigator.pop(context);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_forever),
            title: const Text('Delete all stock data'),
            subtitle: Text(
                '${store.products.length} products and ${store.suppliers.length} suppliers will be removed.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final confirmed = await confirmTypedDelete(
                  context,
                  'Delete all stock data?',
                  'Type DELETE STOCK to remove every product, supplier, and open cart item.',
                  'DELETE STOCK');
              if (!confirmed) return;
              await store.deleteAllStockData();
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
      ],
    ),
  );
}

Future<bool> confirmTypedDelete(BuildContext context, String title, String body,
    String requiredText) async {
  final controller = TextEditingController();
  var valid = false;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              WarningPanel(text: body),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Type exactly: $requiredText',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                    labelText: 'Confirmation text',
                    border: OutlineInputBorder()),
                onChanged: (value) =>
                    setState(() => valid = value.trim() == requiredText),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton.tonalIcon(
            onPressed: valid ? () => Navigator.pop(context, true) : null,
            icon: const Icon(Icons.delete_forever),
            label: const Text('Delete'),
          ),
        ],
      ),
    ),
  );
  return result ?? false;
}

Future<void> importProductCsv(BuildContext context, AppStore store) async {
  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'txt'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final bytes = file.bytes ??
        (file.path == null ? null : await File(file.path!).readAsBytes());
    if (bytes == null) throw StateError('Could not read selected CSV file.');
    final text = utf8.decode(bytes, allowMalformed: true);
    final products = productsFromCsv(text, store);
    if (products.isEmpty) {
      throw StateError(
          'No products found. CSV columns should include Product Name, Product Category, SKU number, Cost Price, Selling Price, Initial Stock, Low Stock Threshold, and optionally Supplier.');
    }
    await store.importProducts(products);
    if (context.mounted) {
      showMessage(context, 'Imported ${products.length} products from CSV.');
    }
  } catch (error) {
    if (context.mounted) showMessage(context, cleanError(error));
  }
}

List<Product> productsFromCsv(String text, AppStore store) {
  final rows = parseCsvRows(text)
      .where((row) => row.any((cell) => cell.trim().isNotEmpty))
      .toList();
  if (rows.isEmpty) return [];
  final headers = rows.first.map(normalizeHeader).toList();
  final products = <Product>[];
  for (final row in rows.skip(1)) {
    String value(List<String> keys) {
      for (final key in keys) {
        final index = headers.indexOf(key);
        if (index >= 0 && index < row.length) return row[index].trim();
      }
      return '';
    }

    final name = value(['productname', 'name', 'product']);
    if (name.isEmpty) continue;
    final supplierText = value(['supplier', 'suppliername']);
    var supplierId = '';
    if (supplierText.isNotEmpty) {
      final existing = store.suppliers
          .where((supplier) =>
              supplier.name.toLowerCase() == supplierText.toLowerCase())
          .firstOrNull;
      if (existing == null) {
        final supplier = Supplier(id: newId(), name: supplierText);
        store.suppliers.add(supplier);
        supplierId = supplier.id;
      } else {
        supplierId = existing.id;
      }
    }
    products.add(Product(
      id: newId(),
      name: name,
      category: value(['productcategory', 'category']),
      sku: value(['skunumber', 'sku']),
      barcode: value(['barcode']),
      priceCents:
          parseMoneyCents(value(['sellingprice', 'price', 'retailprice'])),
      costCents: parseMoneyCents(
          value(['costprice', 'buyingcost', 'purchaseprice', 'unitcost'])),
      stock: int.tryParse(value(['initialstock', 'stock', 'quantity'])) ?? 0,
      reorderLevel: int.tryParse(
              value(['lowstockthreshold', 'threshold', 'reorderlevel'])) ??
          5,
      supplierId: supplierId,
    ));
  }
  return products;
}

String normalizeHeader(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

List<List<String>> parseCsvRows(String input) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < input.length; i++) {
    final char = input[i];
    if (char == '"') {
      if (quoted && i + 1 < input.length && input[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (char == ',' && !quoted) {
      row.add(cell.toString());
      cell.clear();
    } else if ((char == '\n' || char == '\r') && !quoted) {
      if (char == '\r' && i + 1 < input.length && input[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = <String>[];
    } else {
      cell.write(char);
    }
  }
  row.add(cell.toString());
  rows.add(row);
  return rows;
}

String csvLine(List<String> values) => values.map((value) {
      final escaped = value.replaceAll('"', '""');
      return '"$escaped"';
    }).join(',');

Future<void> showCustomerDialog(BuildContext context, AppStore store) async {
  final name = TextEditingController();
  final phone = TextEditingController();
  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Add Customer'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Field(
            controller: name,
            label: 'Customer name',
            icon: Icons.person,
            required: true),
        Field(controller: phone, label: 'Phone', icon: Icons.phone),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () async {
              await store.addCustomer(name.text.trim(), phone.text.trim());
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save')),
      ],
    ),
  );
}

Future<BranchDraft?> showBranchEditorDialog(BuildContext context,
    {required String title, BranchProfile? existing}) async {
  final name = TextEditingController(text: existing?.name ?? '');
  final phone = TextEditingController(text: existing?.phone ?? '');
  final address = TextEditingController(text: existing?.address ?? '');
  return showDialog<BranchDraft>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Field(
                controller: name,
                label: 'Branch name',
                icon: Icons.account_tree,
                required: true),
            Field(controller: phone, label: 'Branch phone', icon: Icons.phone),
            Field(
                controller: address,
                label: 'Branch address',
                icon: Icons.location_on),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (name.text.trim().isEmpty) return;
            Navigator.pop(
                context,
                BranchDraft(
                    name: name.text.trim(),
                    phone: phone.text.trim(),
                    address: address.text.trim()));
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<void> showBranchTransferDialog(
    BuildContext context, AppStore store, BranchProfile targetBranch) async {
  BranchProfile sourceBranch = store.branches
          .where((branch) => branch.id != targetBranch.id)
          .where((branch) =>
              store.transferableProductsFromBranch(branch.id).isNotEmpty)
          .firstOrNull ??
      store.branches
          .where((branch) => branch.id != targetBranch.id)
          .firstOrNull ??
      targetBranch;
  Product? product =
      store.transferableProductsFromBranch(sourceBranch.id).firstOrNull;
  final qty = TextEditingController(text: '1');
  final search = TextEditingController();
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final movableProducts =
            store.transferableProductsFromBranch(sourceBranch.id);
        if (product != null &&
            !movableProducts.any((item) => item.id == product!.id)) {
          product = movableProducts.firstOrNull;
        }
        final q = search.text.trim().toLowerCase();
        final filteredProducts = movableProducts
            .where((item) =>
                q.isEmpty ||
                item.name.toLowerCase().contains(q) ||
                item.sku.toLowerCase().contains(q) ||
                item.category.toLowerCase().contains(q))
            .take(12)
            .toList();
        return AlertDialog(
          title: Text('Transfer to ${targetBranch.name}'),
          content: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                InfoPanel(
                    icon: Icons.move_up,
                    title: 'Branch stock transfer',
                    body:
                        'Moves stock between branches without switching sessions. Product master data is shared; branch quantities are separate.'),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: sourceBranch.id,
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.storefront),
                      labelText: 'From branch',
                      border: OutlineInputBorder()),
                  items: store.branches
                      .where((branch) => branch.id != targetBranch.id)
                      .map((branch) => DropdownMenuItem(
                          value: branch.id,
                          child: Text(
                              '${branch.name} (${store.branchTotalStockQuantity(branch.id)} pieces)')))
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      sourceBranch = store.branches
                              .where((branch) => branch.id == value)
                              .firstOrNull ??
                          sourceBranch;
                      product = store
                          .transferableProductsFromBranch(sourceBranch.id)
                          .firstOrNull;
                    });
                  },
                ),
                const SizedBox(height: 12),
                if (movableProducts.isEmpty)
                  WarningPanel(
                      text:
                          '${sourceBranch.name} has no stock available to transfer. Choose another source branch with stock.')
                else ...[
                  TextField(
                    controller: search,
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        labelText: 'Search product to transfer',
                        border: OutlineInputBorder()),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  if (filteredProducts.isEmpty)
                    const Text('No matching stocked products.')
                  else
                    ...filteredProducts.map((item) => RadioListTile<Product>(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: item,
                          groupValue: product,
                          onChanged: (value) => setState(() => product = value),
                          title: Text(item.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text([
                            '${store.branchStockQuantity(sourceBranch.id, item)} available',
                            if (item.sku.trim().isNotEmpty) 'SKU ${item.sku}',
                            if (item.category.trim().isNotEmpty) item.category,
                          ].join(' | ')),
                        )),
                ],
                const SizedBox(height: 10),
                Field(
                    controller: qty,
                    label: 'Quantity',
                    icon: Icons.numbers,
                    required: true,
                    keyboardType: TextInputType.number),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton.icon(
                onPressed: product == null || movableProducts.isEmpty
                    ? null
                    : () async {
                        final amount = int.tryParse(qty.text.trim()) ?? 0;
                        final selected = product!;
                        if (amount <= 0) {
                          showMessage(context, 'Enter a quantity above zero.');
                          return;
                        }
                        final available = store.branchStockQuantity(
                            sourceBranch.id, selected);
                        if (amount > available) {
                          showMessage(context,
                              'Only $available available in ${sourceBranch.name}.');
                          return;
                        }
                        final confirmed = await confirmAction(
                            context,
                            'Transfer stock?',
                            'Move $amount ${selected.name} from ${sourceBranch.name} to ${targetBranch.name}?',
                            actionLabel: 'OK',
                            icon: Icons.check_circle);
                        if (!confirmed) return;
                        try {
                          await store.transferStockBetweenBranches(
                              selected, sourceBranch, targetBranch, amount);
                          if (context.mounted) {
                            showMessage(context,
                                'Transferred $amount ${selected.name} to ${targetBranch.name}');
                          }
                          if (context.mounted) Navigator.pop(context);
                        } catch (error) {
                          if (context.mounted)
                            showMessage(context, cleanError(error));
                        }
                      },
                icon: const Icon(Icons.move_up),
                label: const Text('Transfer')),
          ],
        );
      },
    ),
  );
}

Future<void> showVoidSaleDialog(
    BuildContext context, AppStore store, SaleRecord sale) async {
  final reason = TextEditingController();
  final quantities = <String, TextEditingController>{};
  for (final line in sale.lines) {
    final alreadyVoided = store.voidedQuantityForLine(sale.id, line);
    final remaining = max(0, line.quantity - alreadyVoided);
    quantities[lineKey(line)] = TextEditingController(text: '$remaining');
  }
  bool fullVoid = true;
  await showDialog(
    context: context,
    builder: (context) => StatefulBuilder(builder: (context, setState) {
      final selectedLines = <ReceiptLineSnapshot>[];
      for (final line in sale.lines) {
        final alreadyVoided = store.voidedQuantityForLine(sale.id, line);
        final remaining = max(0, line.quantity - alreadyVoided);
        final entered = fullVoid
            ? remaining
            : int.tryParse(quantities[lineKey(line)]?.text.trim() ?? '0') ?? 0;
        final qty = entered.clamp(0, remaining);
        if (qty > 0) {
          selectedLines.add(ReceiptLineSnapshot(
            productId: line.productId,
            name: line.name,
            quantity: qty,
            unitPriceCents: line.unitPriceCents,
            lineTotalCents: line.unitPriceCents * qty,
          ));
        }
      }
      final amount =
          selectedLines.fold(0, (sum, line) => sum + line.lineTotalCents);
      return AlertDialog(
        title: const Text('Void / Return Sale'),
        content: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              InfoPanel(
                  icon: Icons.undo,
                  title: fullVoid ? 'Full void' : 'Partial void',
                  body:
                      'Stock is restored to the original branch and reports subtract the voided amount. The original sale remains in audit history.'),
              const SizedBox(height: 10),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: fullVoid,
                onChanged: (value) => setState(() => fullVoid = value),
                title: const Text('Full void / return all remaining items',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 8),
              ...sale.lines.map((line) {
                final alreadyVoided =
                    store.voidedQuantityForLine(sale.id, line);
                final remaining = max(0, line.quantity - alreadyVoided);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(
                        child: Text(
                            '${line.name}\nRemaining: $remaining of ${line.quantity}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis)),
                    SizedBox(
                      width: 92,
                      child: TextField(
                        controller: quantities[lineKey(line)],
                        enabled: !fullVoid && remaining > 0,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'Qty', border: OutlineInputBorder()),
                        onChanged: (_) => setState(() {}),
                      ),
                    )
                  ]),
                );
              }),
              Field(
                  controller: reason,
                  label: 'Reason',
                  icon: Icons.edit_note,
                  required: true),
              TotalRow(
                  label: 'Void amount',
                  value: store.moneyFor(amount),
                  bold: true),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton.icon(
              onPressed: selectedLines.isEmpty
                  ? null
                  : () async {
                      if (reason.text.trim().isEmpty) {
                        showMessage(context, 'Enter a reason.');
                        return;
                      }
                      final confirmed = await confirmAction(
                          context,
                          fullVoid
                              ? 'Confirm full void?'
                              : 'Confirm partial void?',
                          'This will restore stock and reduce reports by ${store.moneyFor(amount)}.',
                          actionLabel: 'OK',
                          icon: Icons.check_circle);
                      if (!confirmed) return;
                      try {
                        await store.voidSale(
                            sale, selectedLines, reason.text.trim());
                        if (context.mounted) {
                          showMessage(context, 'Void recorded and synced.');
                          Navigator.pop(context);
                        }
                      } catch (error) {
                        if (context.mounted)
                          showMessage(context, cleanError(error));
                      }
                    },
              icon: const Icon(Icons.undo),
              label: const Text('Record Void')),
        ],
      );
    }),
  );
}

String lineKey(ReceiptLineSnapshot line) => line.productId.isNotEmpty
    ? line.productId
    : '${line.name}-${line.unitPriceCents}';

Future<UserDraft?> showUserEditorDialog(BuildContext context,
    {required String title,
    AppUser? existing,
    required List<BranchProfile> branches}) async {
  final name = TextEditingController(text: existing?.name ?? '');
  final username = TextEditingController(text: existing?.username ?? '');
  final pin = TextEditingController(text: existing?.pin ?? '');
  String role =
      existing?.role == 'Owner' ? 'Owner' : existing?.role ?? 'Cashier';
  List<String> permissions = existing == null
      ? defaultPermissionsForRole(role)
      : [...existing.permissions];
  List<String> branchIds = existing == null
      ? (branches.length == 1 ? [branches.first.id] : [])
      : [...existing.branchIds];
  if (existing?.isOwner == true) permissions = AppPermission.all;
  return showDialog<UserDraft>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Field(
                controller: name,
                label: 'Name',
                icon: Icons.person,
                required: true),
            Field(
                controller: username,
                label: 'Username',
                icon: Icons.alternate_email,
                required: true),
            if (existing?.isOwner == true)
              const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.admin_panel_settings),
                  title: Text('Owner'),
                  subtitle: Text('Owner account keeps all privileges.'))
            else
              DropdownButtonFormField(
                initialValue: role == 'Owner' ? 'Cashier' : role,
                items: const [
                  'Manager',
                  'Cashier',
                  'Auditor',
                  'Stock Clerk',
                  'Branch Supervisor'
                ]
                    .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                    .toList(),
                onChanged: (value) => setState(() {
                  role = value ?? role;
                  permissions = defaultPermissionsForRole(role);
                }),
                decoration: const InputDecoration(labelText: 'Role'),
              ),
            const SizedBox(height: 10),
            Field(
                controller: pin,
                label: 'PIN / password',
                icon: Icons.pin,
                required: true,
                obscure: true,
                keyboardType: TextInputType.number),
            const Align(
                alignment: Alignment.centerLeft,
                child: Text('Privileges',
                    style: TextStyle(fontWeight: FontWeight.w900))),
            ...AppPermission.labels.entries.map(
              (entry) => CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: existing?.isOwner == true
                    ? true
                    : permissions.contains(entry.key),
                onChanged: existing?.isOwner == true
                    ? null
                    : (checked) => setState(() {
                          permissions = [...permissions];
                          if (checked == true &&
                              !permissions.contains(entry.key)) {
                            permissions.add(entry.key);
                          }
                          if (checked == false) {
                            permissions.remove(entry.key);
                          }
                        }),
                title: Text(entry.value),
              ),
            ),
            if (branches.isNotEmpty && existing?.isOwner != true) ...[
              const Divider(height: 24),
              const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Branch Access',
                      style: TextStyle(fontWeight: FontWeight.w900))),
              const SizedBox(height: 4),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    'Owner/all-privilege users can work across branches. Staff must be assigned to at least one branch.'),
              ),
              ...branches.map(
                (branch) => CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: branchIds.contains(branch.id),
                  onChanged: (checked) => setState(() {
                    branchIds = [...branchIds];
                    if (checked == true && !branchIds.contains(branch.id)) {
                      branchIds.add(branch.id);
                    }
                    if (checked == false) branchIds.remove(branch.id);
                  }),
                  title: Text(branch.name),
                ),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isEmpty ||
                  username.text.trim().isEmpty ||
                  pin.text.trim().isEmpty) return;
              final isFullAccess =
                  AppPermission.all.every((item) => permissions.contains(item));
              if (branches.isNotEmpty &&
                  existing?.isOwner != true &&
                  !isFullAccess &&
                  branchIds.isEmpty) {
                showMessage(
                    context, 'Assign this user to at least one branch.');
                return;
              }
              Navigator.pop(
                  context,
                  UserDraft(
                      name: name.text.trim(),
                      username: username.text.trim(),
                      role: role,
                      pin: pin.text.trim(),
                      permissions: permissions,
                      branchIds: branchIds));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

Future<String?> showManualTextPad(BuildContext context,
    {required String title,
    String initialValue = '',
    bool allowLetters = true}) async {
  var value = initialValue.trim();
  final keys = [
    ...'1234567890'.split(''),
    if (allowLetters) ...'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''),
    '-',
    '.',
    '/',
  ];
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                value.isEmpty ? 'Type here' : value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final key in keys)
                  SizedBox(
                    width: 48,
                    height: 44,
                    child: OutlinedButton(
                      onPressed: () => setState(() => value += key),
                      style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8))),
                      child: Text(key,
                          style: const TextStyle(fontWeight: FontWeight.w900)),
                    ),
                  ),
              ],
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: value.isEmpty
                  ? null
                  : () => setState(() =>
                      value = value.substring(0, max(0, value.length - 1))),
              child: const Text('Backspace')),
          TextButton(
              onPressed:
                  value.isEmpty ? null : () => setState(() => value = ''),
              child: const Text('Clear')),
          FilledButton(
              onPressed: () => Navigator.pop(context, value.trim()),
              child: const Text('OK')),
        ],
      ),
    ),
  );
}

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

Future<bool> confirmDanger(
    BuildContext context, String title, String body) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton.tonalIcon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.delete),
          label: const Text('Delete'),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String body, {
  String actionLabel = 'OK',
  IconData icon = Icons.check,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: Icon(icon),
          label: Text(actionLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

enum Tone { good, warning, danger, neutral }

class StatusPill extends StatelessWidget {
  const StatusPill(
      {required this.label, required this.icon, required this.tone, super.key});
  final String label;
  final IconData icon;
  final Tone tone;
  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      Tone.good => const Color(0xFF168354),
      Tone.warning => const Color(0xFF9A6B00),
      Tone.danger => const Color(0xFFB3261E),
      Tone.neutral => const Color(0xFF53606A),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          border: Border.all(color: color.withValues(alpha: 0.25)),
          borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w700, fontSize: 12))
      ]),
    );
  }
}

class PageFrame extends StatelessWidget {
  const PageFrame(
      {required this.title, required this.children, this.trailing, super.key});
  final String title;
  final List<Widget> children;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 620;
    return ListView(
      padding: EdgeInsets.all(compact ? 14 : 20),
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: trailing == null || compact
                  ? double.infinity
                  : max(220, MediaQuery.sizeOf(context).width - 360),
              child: Text(title,
                  softWrap: true,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      fontSize: compact ? 24 : null)),
            ),
            if (trailing != null) trailing!
          ],
        ),
        const SizedBox(height: 16),
        ...children,
      ],
    );
  }
}

class DecoratedPanel extends StatelessWidget {
  const DecoratedPanel({required this.child, super.key});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
      decoration: panelDecoration(context),
      child: Padding(padding: const EdgeInsets.all(16), child: child));
}

class Field extends StatelessWidget {
  const Field(
      {required this.controller,
      required this.label,
      required this.icon,
      this.required = false,
      this.obscure = false,
      this.keyboardType,
      this.onChanged,
      super.key});
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool required;
  final bool obscure;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        onChanged: onChanged,
        validator: required
            ? (value) => (value ?? '').trim().isEmpty ? 'Required' : null
            : null,
        decoration: InputDecoration(
            prefixIcon: Icon(icon),
            labelText: label,
            border: const OutlineInputBorder()),
      ),
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard(
      {required this.label,
      required this.value,
      required this.icon,
      super.key});
  final String label;
  final String value;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(children: [
            Icon(icon, size: 24, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 2),
                  FittedBox(
                    alignment: Alignment.centerLeft,
                    fit: BoxFit.scaleDown,
                    child: Text(value,
                        maxLines: 1,
                        style: const TextStyle(
                            fontSize: 19, fontWeight: FontWeight.w900)),
                  )
                ])),
          ]),
        ),
      );
}

class QuickProduct extends StatelessWidget {
  const QuickProduct(
      {required this.product,
      required this.stockQuantity,
      required this.stockLabel,
      required this.moneyText,
      required this.onTap,
      super.key});
  final Product product;
  final int stockQuantity;
  final String stockLabel;
  final String moneyText;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 190,
      height: 108,
      child: OutlinedButton(
        onPressed: stockQuantity <= 0 ? null : onTap,
        style: OutlinedButton.styleFrom(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            alignment: Alignment.centerLeft),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(product.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900)),
              Text(moneyText),
              Text('$stockQuantity $stockLabel',
                  style: Theme.of(context).textTheme.labelSmall),
            ]),
      ),
    );
  }
}

class HealthTile extends StatelessWidget {
  const HealthTile(
      {required this.icon,
      required this.title,
      required this.value,
      super.key});
  final IconData icon;
  final String title;
  final String value;
  @override
  Widget build(BuildContext context) => SizedBox(
      width: 260, child: InfoPanel(icon: icon, title: title, body: value));
}

class InfoPanel extends StatelessWidget {
  const InfoPanel(
      {required this.icon, required this.title, required this.body, super.key});
  final IconData icon;
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) => DecoratedPanel(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                Text(body)
              ])),
        ]),
      );
}

class WarningPanel extends StatelessWidget {
  const WarningPanel({required this.text, super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: const Color(0xFFFFF7E1),
            border: Border.all(color: const Color(0xFFD49B00)),
            borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          const Icon(Icons.warning_amber, color: Color(0xFF9A6B00)),
          const SizedBox(width: 12),
          Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, color: Color(0xFF6E4B00))))
        ]),
      );
}

class DataStrip extends StatelessWidget {
  const DataStrip({required this.headers, required this.rows, super.key});
  final List<String> headers;
  final List<List<String>> rows;
  @override
  Widget build(BuildContext context) {
    return DecoratedPanel(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingTextStyle: const TextStyle(fontWeight: FontWeight.w900),
          columns:
              headers.map((header) => DataColumn(label: Text(header))).toList(),
          rows: rows.isEmpty
              ? [
                  DataRow(
                      cells: headers
                          .map((_) => const DataCell(Text('-')))
                          .toList())
                ]
              : rows
                  .map((row) => DataRow(
                      cells: row.map((cell) => DataCell(Text(cell))).toList()))
                  .toList(),
        ),
      ),
    );
  }
}

class TotalRow extends StatelessWidget {
  const TotalRow(
      {required this.label, required this.value, this.bold = false, super.key});
  final String label;
  final String value;
  final bool bold;
  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
        fontWeight: bold ? FontWeight.w900 : FontWeight.w500,
        fontSize: bold ? 18 : 14);
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: style)),
          Text(value, style: style)
        ]));
  }
}

class CurrencyChoiceRow extends StatelessWidget {
  const CurrencyChoiceRow(
      {required this.label,
      required this.selected,
      required this.onSelected,
      super.key});
  final String label;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: ['USD', 'ZWL', 'ZAR', 'BWP']
            .map((code) => ChoiceChip(
                  label: Text(code),
                  selected: selected == code,
                  onSelected: (_) => onSelected(code),
                ))
            .toList(),
      ),
    ]);
  }
}

BoxDecoration panelDecoration(BuildContext context) {
  return BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFE0E5DD)),
      borderRadius: BorderRadius.circular(8),
      boxShadow: const [
        BoxShadow(
            color: Color(0x0A000000), blurRadius: 12, offset: Offset(0, 4))
      ]);
}
