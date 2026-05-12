import argparse
import secrets


ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def token() -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(10))


def sql_text(value: str) -> str:
    return value.replace("'", "''")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate strict random Light Winter owner reset voucher SQL."
    )
    parser.add_argument("--quantity", type=int, default=1)
    parser.add_argument(
        "--device",
        default="",
        help="Optional target device UID. If set, reset voucher works only on that device.",
    )
    parser.add_argument(
        "--organization",
        default="",
        help="Optional organization/shop ID. If set, reset voucher works only for that shop.",
    )
    parser.add_argument(
        "--purpose",
        choices=["owner_pin_reset", "owner_username_lookup", "owner_access_reset"],
        default="owner_access_reset",
    )
    args = parser.parse_args()

    if args.quantity <= 0:
        raise SystemExit("quantity must be positive.")

    print(
        "insert into public.lwr_owner_reset_tokens(token, organization_id, target_device_uid, purpose)"
    )
    print("values")
    rows = []
    for _ in range(args.quantity):
        clean = token()
        org = "null" if not args.organization.strip() else f"'{sql_text(args.organization.strip())}'"
        device = "null" if not args.device.strip() else f"'{sql_text(args.device.strip())}'"
        rows.append(f"  ('{clean}', {org}, {device}, '{args.purpose}')")
    print(",\n".join(rows) + ";")
    print("\n-- Send only the reset voucher token to the customer. Keep this SQL private.")


if __name__ == "__main__":
    main()
