from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field

from domain.user.models import ConsentType, UserRole, UserStatus


class ConsentInput(BaseModel):
    consent_type: ConsentType
    consent_version: str = Field(min_length=1, max_length=50)
    agreed: bool


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=12, max_length=128)
    display_name: str = Field(min_length=1, max_length=100)
    phone: str | None = Field(default=None, max_length=30)
    consents: list[ConsentInput] = Field(default_factory=list)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    user_id: UUID
    email: str
    display_name: str
    phone: str | None
    role: UserRole
    status: UserStatus
    mfa_enabled: bool
    created_at: datetime


class MessageResponse(BaseModel):
    message: str
