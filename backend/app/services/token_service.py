from __future__ import annotations

import secrets

SAFE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def generate_random_token(groups: int = 3, group_size: int = 4) -> str:
    """Generate a short human-readable token using cryptographic randomness."""
    if groups < 2 or group_size < 3:
        raise ValueError("Token format would be too short to be commercially safe.")
    parts = []
    for _ in range(groups):
        parts.append("".join(secrets.choice(SAFE_ALPHABET) for _ in range(group_size)))
    return "-".join(parts)


def normalize_token(token: str) -> str:
    return token.strip().upper().replace(" ", "-")
