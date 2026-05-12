from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models.domain import (
    AuditLog,
    Branch,
    BranchStock,
    Customer,
    Debt,
    DebtStatus,
    Device,
    FiscalMode,
    PaymentMethod,
    Product,
    ReversalType,
    Sale,
    SaleLine,
    SaleReversal,
    SaleStatus,
    StockMovement,
    StockMovementType,
    SyncStatus,
)
from app.schemas.api import CreateSaleRequest, ReversalRequest


class RetailError(ValueError):
    pass


def cents(value: int) -> int:
    if value < 0:
        raise RetailError("Money values cannot be negative.")
    return value


def get_or_create_stock(db: Session, *, branch_id: str, product_id: str) -> BranchStock:
    stock = db.scalar(select(BranchStock).where(BranchStock.branch_id == branch_id, BranchStock.product_id == product_id))
    if stock:
        return stock
    stock = BranchStock(branch_id=branch_id, product_id=product_id, quantity=0)
    db.add(stock)
    db.flush()
    return stock


def audit(
    db: Session,
    *,
    action: str,
    entity_type: str,
    entity_id: str | None = None,
    branch_id: str | None = None,
    device_id: str | None = None,
    user_id: str | None = None,
    detail: str | None = None,
) -> None:
    db.add(
        AuditLog(
            branch_id=branch_id,
            device_id=device_id,
            user_id=user_id,
            action=action,
            entity_type=entity_type,
            entity_id=entity_id,
            detail=detail,
        )
    )


def adjust_stock(
    db: Session,
    *,
    branch_id: str,
    product_id: str,
    movement_type: StockMovementType,
    quantity_delta: int,
    reason: str,
    user_id: str | None = None,
    reference_id: str | None = None,
) -> BranchStock:
    branch = db.get(Branch, branch_id)
    product = db.get(Product, product_id)
    if branch is None or product is None:
        raise RetailError("Branch or product was not found.")
    if branch.organization_id != product.organization_id:
        raise RetailError("Product does not belong to this branch organization.")

    stock = get_or_create_stock(db, branch_id=branch_id, product_id=product_id)
    new_quantity = stock.quantity + quantity_delta
    if new_quantity < 0:
        raise RetailError("Stock cannot go negative.")
    stock.quantity = new_quantity
    stock.updated_at = datetime.now(timezone.utc)
    db.add(
        StockMovement(
            branch_id=branch_id,
            product_id=product_id,
            movement_type=movement_type,
            quantity_delta=quantity_delta,
            reference_id=reference_id,
            reason=reason,
            user_id=user_id,
        )
    )
    audit(
        db,
        action="stock.adjusted",
        entity_type="product",
        entity_id=product_id,
        branch_id=branch_id,
        user_id=user_id,
        detail=f"{movement_type.value}: {quantity_delta}. {reason}",
    )
    return stock


def create_sale(db: Session, payload: CreateSaleRequest) -> Sale:
    device = db.scalar(select(Device).where(Device.device_uid == payload.device_uid))
    if device is None or not device.activated:
        raise RetailError("Activated device not found.")

    if payload.payment_method == PaymentMethod.debt and payload.customer_id is None:
        raise RetailError("Debt sales require a customer.")
    customer = db.get(Customer, payload.customer_id) if payload.customer_id else None
    if payload.customer_id and customer is None:
        raise RetailError("Customer was not found.")

    subtotal = 0
    line_records: list[SaleLine] = []
    stock_updates: list[tuple[str, int]] = []
    for line in payload.lines:
        product = db.get(Product, line.product_id)
        if product is None or not product.active:
            raise RetailError("Product was not found or is inactive.")
        if product.organization_id != device.branch.organization_id:
            raise RetailError("Product does not belong to this device organization.")
        unit_price = cents(line.unit_price_cents if line.unit_price_cents is not None else product.selling_price_cents)
        line_total = (unit_price * line.quantity) - cents(line.discount_cents)
        if line_total < 0:
            raise RetailError("Line discount cannot exceed line total.")
        stock = get_or_create_stock(db, branch_id=device.branch_id, product_id=product.id)
        if stock.quantity < line.quantity:
            raise RetailError(f"Insufficient stock for {product.name}.")
        subtotal += line_total
        line_records.append(
            SaleLine(
                product_id=product.id,
                quantity=line.quantity,
                unit_price_cents=unit_price,
                discount_cents=line.discount_cents,
                total_cents=line_total,
            )
        )
        stock_updates.append((product.id, -line.quantity))

    total = subtotal - cents(payload.discount_cents)
    if total < 0:
        raise RetailError("Sale discount cannot exceed subtotal.")
    paid = total if payload.payment_method == PaymentMethod.debt else cents(payload.paid_cents)
    if payload.payment_method != PaymentMethod.debt and paid < total:
        raise RetailError("Paid amount is below sale total.")

    sale = Sale(
        branch_id=device.branch_id,
        device_id=device.id,
        cashier_user_id=payload.cashier_user_id,
        customer_id=payload.customer_id,
        payment_method=payload.payment_method,
        subtotal_cents=subtotal,
        discount_cents=payload.discount_cents,
        tax_cents=0,
        total_cents=total,
        paid_cents=paid,
        change_cents=max(0, paid - total),
        fiscal_submission_status=SyncStatus.pending if device.branch.organization.fiscal_mode == FiscalMode.fiscal else SyncStatus.synced,
        lines=line_records,
    )
    db.add(sale)
    db.flush()

    for product_id, delta in stock_updates:
        adjust_stock(
            db,
            branch_id=device.branch_id,
            product_id=product_id,
            movement_type=StockMovementType.sale,
            quantity_delta=delta,
            reason="Sale completed",
            user_id=payload.cashier_user_id,
            reference_id=sale.id,
        )

    if payload.payment_method == PaymentMethod.debt and customer:
        debt = Debt(customer_id=customer.id, sale_id=sale.id, principal_cents=total, balance_cents=total)
        db.add(debt)

    audit(
        db,
        action="sale.completed",
        entity_type="sale",
        entity_id=sale.id,
        branch_id=device.branch_id,
        device_id=device.id,
        user_id=payload.cashier_user_id,
        detail=f"Sale total {total} cents",
    )
    db.commit()
    db.refresh(sale)
    return sale


def reverse_sale(db: Session, *, sale_id: str, payload: ReversalRequest) -> SaleReversal:
    sale = db.get(Sale, sale_id)
    if sale is None:
        raise RetailError("Sale was not found.")
    if sale.status in {SaleStatus.voided, SaleStatus.returned}:
        raise RetailError("Sale has already been fully reversed.")

    full = payload.reversal_type in {ReversalType.full_void, ReversalType.full_return}
    line_quantities = {line.id: line.quantity - line.reversed_quantity for line in sale.lines} if full else {}
    if not full:
        if not payload.lines:
            raise RetailError("Partial reversal requires line quantities.")
        for item in payload.lines:
            sale_line = next((line for line in sale.lines if line.id == item.sale_line_id), None)
            if sale_line is None:
                raise RetailError("Sale line was not found.")
            available = sale_line.quantity - sale_line.reversed_quantity
            if item.quantity > available:
                raise RetailError("Reversal quantity exceeds available sale quantity.")
            line_quantities[sale_line.id] = item.quantity

    amount = 0
    for line in sale.lines:
        qty = line_quantities.get(line.id, 0)
        if qty <= 0:
            continue
        amount += round(line.total_cents * (qty / line.quantity))
        line.reversed_quantity += qty
        restore_type = StockMovementType.void_restore if "void" in payload.reversal_type.value else StockMovementType.return_to_stock
        adjust_stock(
            db,
            branch_id=sale.branch_id,
            product_id=line.product_id,
            movement_type=restore_type,
            quantity_delta=qty,
            reason=payload.reason,
            user_id=payload.user_id,
            reference_id=sale.id,
        )

    if amount <= 0:
        raise RetailError("Nothing could be reversed.")

    if sale.debt and sale.debt.status == DebtStatus.open:
        sale.debt.balance_cents = max(0, sale.debt.balance_cents - amount)
        if sale.debt.balance_cents == 0:
            sale.debt.status = DebtStatus.settled

    all_reversed = all(line.reversed_quantity >= line.quantity for line in sale.lines)
    if payload.reversal_type == ReversalType.full_void or (all_reversed and "void" in payload.reversal_type.value):
        sale.status = SaleStatus.voided
    elif payload.reversal_type == ReversalType.full_return or (all_reversed and "return" in payload.reversal_type.value):
        sale.status = SaleStatus.returned
    elif "void" in payload.reversal_type.value:
        sale.status = SaleStatus.partially_voided
    else:
        sale.status = SaleStatus.partially_returned
    sale.fiscal_submission_status = SyncStatus.pending

    reversal = SaleReversal(
        sale_id=sale.id,
        reversal_type=payload.reversal_type,
        reason=payload.reason,
        user_id=payload.user_id,
        amount_cents=amount,
    )
    db.add(reversal)
    audit(
        db,
        action=f"sale.{payload.reversal_type.value}",
        entity_type="sale",
        entity_id=sale.id,
        branch_id=sale.branch_id,
        device_id=sale.device_id,
        user_id=payload.user_id,
        detail=payload.reason,
    )
    db.commit()
    db.refresh(reversal)
    return reversal


def organization_debt_balance(db: Session, organization_id: str) -> int:
    return int(
        db.scalar(
            select(func.coalesce(func.sum(Debt.balance_cents), 0))
            .join(Customer, Customer.id == Debt.customer_id)
            .where(Customer.organization_id == organization_id, Debt.status == DebtStatus.open)
        )
        or 0
    )
