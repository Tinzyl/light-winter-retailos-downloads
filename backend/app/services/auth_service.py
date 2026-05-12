from __future__ import annotations

from datetime import datetime, timedelta, timezone

from jose import jwt
from passlib.context import CryptContext
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.models.domain import AuthSession, Device, User, UserRole

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


class AuthError(ValueError):
    pass


def hash_secret(secret: str) -> str:
    if len(secret) < 4:
        raise AuthError("Secret must be at least 4 characters.")
    return pwd_context.hash(secret)


def verify_secret(secret: str, hashed: str | None) -> bool:
    if not hashed:
        return False
    return pwd_context.verify(secret, hashed)


def create_user(
    db: Session,
    *,
    organization_id: str,
    name: str,
    role: UserRole,
    pin: str | None = None,
    password: str | None = None,
) -> User:
    if pin is None and password is None:
        raise AuthError("Either PIN or password is required.")
    user = User(
        organization_id=organization_id,
        name=name,
        username=name,
        role=role,
        pin_plain=pin,
        pin_hash=hash_secret(pin) if pin else None,
        password_hash=hash_secret(password) if password else None,
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def login_with_pin(db: Session, *, organization_id: str, pin: str, device_uid: str | None = None) -> tuple[User, str]:
    users = db.scalars(select(User).where(User.organization_id == organization_id, User.active.is_(True))).all()
    user = next((candidate for candidate in users if verify_secret(pin, candidate.pin_hash)), None)
    if user is None:
        raise AuthError("Invalid PIN.")
    return user, issue_session_token(db, user=user, device_uid=device_uid)


def login_with_password(db: Session, *, organization_id: str, name: str, password: str, device_uid: str | None = None) -> tuple[User, str]:
    user = db.scalar(select(User).where(User.organization_id == organization_id, User.username == name, User.active.is_(True)))
    if user is None:
        user = db.scalar(select(User).where(User.organization_id == organization_id, User.name == name, User.active.is_(True)))
    if user is None or not verify_secret(password, user.password_hash):
        raise AuthError("Invalid credentials.")
    return user, issue_session_token(db, user=user, device_uid=device_uid)


def issue_session_token(db: Session, *, user: User, device_uid: str | None = None) -> str:
    settings = get_settings()
    now = datetime.now(timezone.utc)
    expires = now + timedelta(minutes=settings.access_token_minutes)
    device = db.scalar(select(Device).where(Device.device_uid == device_uid)) if device_uid else None
    session = AuthSession(user_id=user.id, device_id=device.id if device else None, issued_at=now, expires_at=expires)
    db.add(session)
    db.commit()
    claims = {
        "sub": user.id,
        "sid": session.id,
        "org": user.organization_id,
        "role": user.role.value,
        "exp": expires,
    }
    return jwt.encode(claims, settings.jwt_secret, algorithm=settings.jwt_algorithm)
