import argparse
import secrets


ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def token() -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(10))


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate strict random Light Winter Supabase license voucher SQL.")
    parser.add_argument("--mode", choices=["days", "minutes"], required=True)
    parser.add_argument("--value", type=int, required=True)
    parser.add_argument("--quantity", type=int, default=1)
    parser.add_argument("--device", default="", help="Optional target device UID. If set, voucher works only on that device.")
    args = parser.parse_args()

    if args.value <= 0 or args.quantity <= 0:
        raise SystemExit("value and quantity must be positive.")

    print("insert into public.lwr_license_tokens(token, duration_mode, duration_value, target_device_uid)")
    print("values")
    rows = []
    for _ in range(args.quantity):
        clean = token()
        device = args.device.strip()
        target = "null" if not device else "'" + device.replace("'", "''") + "'"
        rows.append(f"  ('{clean}', '{args.mode}', {args.value}, {target})")
    print(",\n".join(rows) + ";")
    print("\n-- Send only the voucher token to the customer. Keep this SQL private.")


if __name__ == "__main__":
    main()
