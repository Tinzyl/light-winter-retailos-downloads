import 'package:flutter_test/flutter_test.dart';
import 'package:light_winter_retailos/main.dart';

void main() {
  Product product({
    required String id,
    required String name,
    required int stock,
    int price = 100,
    int cost = 40,
    int reorder = 5,
    String category = 'General',
    String sku = '',
  }) =>
      Product(
        id: id,
        name: name,
        category: category,
        sku: sku,
        barcode: '',
        priceCents: price,
        costCents: cost,
        stock: stock,
        reorderLevel: reorder,
      );

  AppStore storeWithBranches() {
    final store = AppStore();
    store.branches = [
      BranchProfile(id: 'main', name: 'Main Branch'),
      BranchProfile(id: 'borrowdale', name: 'Borrowdale'),
    ];
    store.assignedBranchId = 'main';
    store.currentUser = AppUser(
      name: 'Cashier',
      username: 'cashier',
      role: 'Cashier',
      pin: '0000',
      permissions: [AppPermission.pos],
      branchIds: ['main'],
    );
    store.products = [
      product(id: 'bread', name: 'Bread', stock: 10, sku: 'BREAD'),
      product(id: 'mazoe', name: 'Mazoe', stock: 0, sku: 'MAZOE'),
      product(id: 'fanta', name: 'Fanta', stock: 0, sku: 'FANTA'),
    ];
    store.branchStockSnapshots = {
      'main': {'bread': 10, 'mazoe': 0},
      'borrowdale': {'mazoe': 5, 'fanta': 0},
    };
    store.branchStockInitialized = {'main', 'borrowdale'};
    return store;
  }

  test('current branch stock shows assigned zero-stock products for restocking',
      () {
    final store = storeWithBranches();

    expect(store.catalogueWideViewEnabled, isFalse);
    expect(store.branchScopedProducts.map((item) => item.name),
        ['Bread', 'Mazoe']);
    expect(store.stockViewProductCount, 2);
    expect(store.stockViewTotalUnits, 10);
    expect(store.outOfStockCount, 1);
    expect(
        store.sellableQuantityFor(
            store.products.firstWhere((item) => item.name == 'Mazoe')),
        0);
  });

  test(
      'all branches mode uses central catalogue totals only for privileged user',
      () {
    final store = storeWithBranches();
    store.currentUser = AppUser(
      name: 'Owner',
      username: 'owner',
      role: 'Owner',
      pin: '1234',
      permissions: AppPermission.all,
      branchIds: [],
    );
    store.allCatalogueProductsVisible = true;

    expect(store.catalogueWideViewEnabled, isTrue);
    expect(store.stockViewProductCount, 3);
    expect(store.stockViewTotalUnits, 15);
    expect(store.allBranchesStockedProductCount, 2);
  });

  test('CSV import reads category, cost, selling price, stock and supplier',
      () {
    final store = AppStore();
    final csv = [
      'Product Name,Product Category,SKU number,Cost Price,Selling Price,Initial Stock,Low Stock Threshold,Supplier,Supplier Phone',
      'Rice 2kg,Groceries,RICE2,1.20,2.00,30,5,Best Supplier,0777000000',
    ].join('\n');

    final products = productsFromCsv(csv, store);

    expect(products, hasLength(1));
    expect(products.first.name, 'Rice 2kg');
    expect(products.first.category, 'Groceries');
    expect(products.first.sku, 'RICE2');
    expect(products.first.costCents, 120);
    expect(products.first.priceCents, 200);
    expect(products.first.stock, 30);
    expect(products.first.reorderLevel, 5);
    expect(store.suppliers, hasLength(1));
    expect(products.first.supplierId, store.suppliers.first.id);
  });

  test('CSV import updates existing product stock for current branch',
      () async {
    final store = AppStore();
    store.branches = [BranchProfile(id: 'main', name: 'Main Branch')];
    store.assignedBranchId = 'main';
    store.products = [
      product(id: 'eggs-old', name: 'Eggs Tray', stock: 0, sku: 'EGGSTRAY'),
    ];
    store.branchStockSnapshots = {
      'main': {'eggs-old': 0}
    };
    store.branchStockInitialized = {'main'};
    final imported = [
      product(
          id: 'eggs-new',
          name: 'Eggs Tray',
          stock: 10,
          sku: 'EGGSTRAY',
          price: 450,
          cost: 320),
    ];

    await store.importProducts(imported);

    expect(store.products, hasLength(1));
    expect(store.products.single.id, 'eggs-old');
    expect(store.stockViewQuantityFor(store.products.single), 10);
    expect(store.branchScopedProducts.single.name, 'Eggs Tray');
  });

  test('same SKU in another branch creates a separate branch product',
      () async {
    final store = AppStore();
    store.branches = [
      BranchProfile(id: 'main', name: 'Main Branch'),
      BranchProfile(id: 'hardware', name: 'Hardware'),
    ];
    store.assignedBranchId = 'hardware';
    store.products = [
      product(id: 'main-nails', name: 'Nails 1kg', stock: 12, sku: 'NAILS'),
    ];
    store.branchStockSnapshots = {
      'main': {'main-nails': 12},
      'hardware': {},
    };
    store.branchStockInitialized = {'main', 'hardware'};

    await store.importProducts([
      product(id: 'hardware-nails', name: 'Nails 1kg', stock: 7, sku: 'NAILS'),
    ]);

    expect(store.products.map((item) => item.id).toSet(),
        {'main-nails', 'hardware-nails'});
    expect(store.branchStockSnapshots['main'], {'main-nails': 12});
    expect(store.branchStockSnapshots['hardware'], {'hardware-nails': 7});
    expect(
        store.branchScopedProducts.map((item) => item.id), ['hardware-nails']);
  });

  test('unassigned ghost catalogue products are hidden from branch stock views',
      () {
    final store = storeWithBranches();
    store.products.add(product(id: 'ghost', name: 'Ghost Item', stock: 0));
    store.currentUser = AppUser(
      name: 'Owner',
      username: 'owner',
      role: 'Owner',
      pin: '1234',
      permissions: AppPermission.all,
      branchIds: [],
    );
    store.allCatalogueProductsVisible = true;

    expect(store.activeCatalogueProducts.map((item) => item.id),
        isNot(contains('ghost')));
    expect(store.branchScopedProducts.map((item) => item.id),
        isNot(contains('ghost')));
  });

  test('out-of-stock branch products remain visible for restocking', () {
    final store = storeWithBranches();
    final mazoe = store.products.firstWhere((item) => item.id == 'mazoe');

    expect(store.currentBranchAssignedProducts.map((item) => item.id),
        contains('mazoe'));
    expect(store.stockViewQuantityFor(mazoe), 0);
    expect(store.outOfStockCount, 1);
  });

  test('profit report subtracts voided revenue and voided cost correctly', () {
    final store = AppStore();
    store.branches = [BranchProfile(id: 'main', name: 'Main Branch')];
    store.assignedBranchId = 'main';
    store.products = [
      product(id: 'bread', name: 'Bread', stock: 8, price: 100, cost: 40),
    ];
    store.branchStockSnapshots = {
      'main': {'bread': 8}
    };
    store.branchStockInitialized = {'main'};
    final sale = SaleRecord(
      id: 'sale-1',
      branchId: 'main',
      totalCents: 180,
      paymentMethod: 'Cash',
      cashier: 'Tino',
      customerName: '',
      discountCents: 20,
      paidCents: 180,
      lines: [
        ReceiptLineSnapshot(
          productId: 'bread',
          name: 'Bread',
          quantity: 2,
          unitPriceCents: 100,
          lineTotalCents: 200,
          unitCostCents: 40,
        )
      ],
      createdAt: DateTime.now(),
    );
    store.sales = [sale];
    store.saleVoids = [
      SaleVoidRecord(
        id: 'void-1',
        saleId: sale.id,
        branchId: 'main',
        type: 'partial_return',
        reason: 'Returned one',
        userName: 'Tino',
        totalCents: 90,
        lines: [
          ReceiptLineSnapshot(
            productId: 'bread',
            name: 'Bread',
            quantity: 1,
            unitPriceCents: 100,
            lineTotalCents: 90,
            unitCostCents: 40,
          )
        ],
        createdAt: DateTime.now(),
      )
    ];

    final report = store.reportSnapshot('daily', allBranches: false);

    expect(report.grossSalesCents, 180);
    expect(report.voidedCents, 90);
    expect(report.totalSalesCents, 90);
    expect(report.costOfGoodsCents, 40);
    expect(report.grossProfitCents, 50);
    expect(report.topProducts.single.branchName, isEmpty);
  });

  test('custom item report keeps its display name', () {
    final store = AppStore();
    store.branches = [BranchProfile(id: 'main', name: 'Main Branch')];
    store.assignedBranchId = 'main';
    store.sales = [
      SaleRecord(
        id: 'sale-custom',
        branchId: 'main',
        totalCents: 350,
        paymentMethod: 'Cash',
        cashier: 'Tino',
        customerName: '',
        lines: [
          ReceiptLineSnapshot(
            productId: 'CUSTOM-123',
            name: 'Plastic Bag',
            quantity: 1,
            unitPriceCents: 350,
            lineTotalCents: 350,
          )
        ],
        createdAt: DateTime.now(),
      )
    ];

    final report = store.reportSnapshot('daily', allBranches: false);

    expect(report.topProducts.single.name, 'Plastic Bag');
  });

  test('debt ledger tracks partial and full payment status', () async {
    final store = AppStore();
    final sale = SaleRecord(
      id: 'debt-1',
      branchId: 'main',
      totalCents: 1000,
      paymentMethod: 'Debt',
      cashier: 'Cashier',
      customerName: 'Customer One',
      paidCents: 200,
      debtCents: 800,
      lines: [
        ReceiptLineSnapshot(
          productId: 'bread',
          name: 'Bread',
          quantity: 1,
          unitPriceCents: 1000,
          lineTotalCents: 1000,
        )
      ],
      createdAt: DateTime.now(),
    );
    store.sales = [sale];

    expect(store.debtStatusForSale(sale), 'Partially paid');
    expect(store.debtBalanceForSale(sale), 800);

    await store.settleDebt(sale, 300);

    expect(store.debtStatusForSale(sale), 'Partially paid');
    expect(store.debtBalanceForSale(sale), 500);
    expect(sale.paidCents, 500);

    await store.settleDebt(sale, 1000);

    expect(store.debtStatusForSale(sale), 'Fully paid');
    expect(store.debtBalanceForSale(sale), 0);
    expect(sale.debtCents, 0);
  });

  test('accounting separates supplier bills from operating expenses', () {
    final store = AppStore();
    store.accountingEntries = [
      AccountingEntry(
        id: 'po',
        branchId: 'main',
        type: AccountingEntryType.expense,
        category: 'Purchase Order',
        description: 'Order 10 x Rice',
        amountCents: 5000,
        counterparty: 'Best Supplier',
        createdAt: DateTime.now(),
      ),
      AccountingEntry(
        id: 'stock',
        branchId: 'main',
        type: AccountingEntryType.expense,
        category: 'Stock Purchase',
        description: '10 x Rice',
        amountCents: 5000,
        counterparty: 'Best Supplier',
        createdAt: DateTime.now(),
      ),
      AccountingEntry(
        id: 'pay',
        branchId: 'main',
        type: AccountingEntryType.expense,
        category: 'Supplier Payment',
        description: 'Supplier payment',
        amountCents: 2000,
        counterparty: 'Best Supplier',
        createdAt: DateTime.now(),
      ),
      AccountingEntry(
        id: 'rent',
        branchId: 'main',
        type: AccountingEntryType.expense,
        category: 'Rent',
        description: 'Shop rent',
        amountCents: 1000,
        createdAt: DateTime.now(),
      ),
    ];

    final statement = store.profitLossStatement('daily', allBranches: true);

    expect(statement.operatingExpensesCents, 1000);
    expect(statement.stockPurchasesCents, 5000);
    expect(statement.supplierPaymentsCents, 2000);
    expect(statement.supplierPayablesCents, 3000);
  });

  test('POS customer codes and cashier discount limits are enforced', () {
    final store = AppStore();
    store.currentUser = AppUser(
      name: 'Cashier',
      username: 'cashier',
      role: 'Cashier',
      pin: '0000',
      permissions: [AppPermission.pos],
    );
    store.cart = [
      CartItem(
          product: product(id: 'bread', name: 'Bread', stock: 10, price: 1000),
          quantity: 1)
    ];
    final customer = Customer(id: 'customer-123456', name: 'Tino', phone: '');

    expect(customer.code, 'C-123456');
    expect(store.discountExceedsCashierLimit(99), isFalse);
    expect(store.discountExceedsCashierLimit(101), isTrue);
  });

  test('stock purchase uses current branch quantity for weighted average cost',
      () async {
    final store = storeWithBranches();
    final bread = store.products.firstWhere((item) => item.id == 'bread');

    await store.recordStockPurchase(
        product: bread,
        productName: bread.name,
        supplierName: 'Bakery Supplier',
        quantity: 10,
        totalCents: 800,
        paidCents: 800,
        paymentMethod: 'Cash',
        batchNumber: 'BATCH-1',
        expiryDate: DateTime(2026, 6, 30));

    expect(store.stockViewQuantityFor(bread), 20);
    expect(bread.costCents, 60);
    expect(store.branchStockSnapshots['main']?[bread.id], 20);
    expect(store.batchExpiryRecords.single.batchNumber, 'BATCH-1');
    expect(store.batchExpiryRecords.single.productName, 'Bread');
    expect(store.stockValueAtAverageCostCents, 20 * 60);
    expect(store.stockValueAtFifoCostCents, 10 * 80 + 10 * 60);
  });

  test('customer search dates can be derived from sales history', () {
    final store = AppStore();
    final customer = Customer(id: 'cust-abcdef', name: 'Anephen', phone: '077');
    store.customers = [customer];
    store.sales = [
      SaleRecord(
        id: 'sale-date',
        branchId: 'main',
        totalCents: 100,
        paymentMethod: 'Cash',
        cashier: 'Cashier',
        customerName: 'Anephen',
        lines: [
          ReceiptLineSnapshot(
            productId: 'bread',
            name: 'Bread',
            quantity: 1,
            unitPriceCents: 100,
            lineTotalCents: 100,
          )
        ],
        createdAt: DateTime(2026, 5, 19, 9),
      )
    ];

    expect(customer.code, 'C-ABCDEF');
    expect(store.salesForCustomer(customer).single.createdAt.day, 19);
  });

  test('smart insights are factual and stock-driven', () {
    final store = storeWithBranches();
    final report = store.reportSnapshot('daily', allBranches: false);

    final insights = store.smartInsights(report, allBranches: false);

    expect(insights.map((item) => item.title).join(' | '),
        contains('1 items out of stock'));
    expect(insights.map((item) => item.body).join(' '),
        contains('Record sales first'));
  });

  test('top branch switcher only exposes assigned staff branches', () {
    final store = storeWithBranches();
    store.currentUser = AppUser(
      name: 'Branch Cashier',
      username: 'branchcashier',
      role: 'Cashier',
      pin: '0000',
      permissions: [AppPermission.pos],
      branchIds: ['borrowdale'],
    );

    expect(store.accessibleBranches.map((branch) => branch.id), ['borrowdale']);
    expect(store.currentUser!.canLoginAtBranch('main'), isFalse);
    expect(store.currentUser!.canLoginAtBranch('borrowdale'), isTrue);
  });
}
