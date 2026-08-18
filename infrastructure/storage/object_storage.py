from pathlib import Path
from typing import Any, Protocol

from shared.errors import DomainError


class ObjectStorage(Protocol):
    def put_object(self, key: str, content: bytes) -> None: ...
    def get_object(self, key: str) -> bytes: ...
    def delete_object(self, key: str) -> None: ...
    def exists(self, key: str) -> bool: ...
    def get_metadata(self, key: str) -> dict[str, Any]: ...
    def create_signed_url(self, key: str, expires_seconds: int) -> str: ...


class LocalPrivateStorage:
    """Development adapter. Files are outside the public web tree and have no public URL."""

    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, key: str) -> Path:
        path = (self.root / key).resolve()
        if self.root not in path.parents:
            raise DomainError("STORAGE_UPLOAD_FAILED", "Invalid storage key", 500)
        return path

    def put_object(self, key: str, content: bytes) -> None:
        path = self._path(key)
        temporary = path.with_suffix(".uploading")
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary.write_bytes(content)
            temporary.replace(path)
        except OSError as exc:
            temporary.unlink(missing_ok=True)
            raise DomainError("STORAGE_UPLOAD_FAILED", "Document storage failed", 503) from exc

    def get_object(self, key: str) -> bytes:
        try:
            return self._path(key).read_bytes()
        except OSError as exc:
            raise DomainError("STORAGE_READ_FAILED", "Document could not be read", 503) from exc

    def delete_object(self, key: str) -> None:
        try:
            self._path(key).unlink(missing_ok=True)
        except OSError as exc:
            raise DomainError(
                "STORAGE_DELETE_FAILED", "Document could not be deleted", 503
            ) from exc

    def exists(self, key: str) -> bool:
        return self._path(key).is_file()

    def get_metadata(self, key: str) -> dict[str, Any]:
        path = self._path(key)
        try:
            return {"size": path.stat().st_size}
        except OSError as exc:
            raise DomainError("STORAGE_READ_FAILED", "Document metadata failed", 503) from exc

    def create_signed_url(self, key: str, expires_seconds: int) -> str:
        del key, expires_seconds
        raise DomainError(
            "SIGNED_URL_UNAVAILABLE", "Local private storage does not issue signed URLs", 503
        )


class S3CompatibleObjectStorage:
    """Production adapter for private AWS S3, MinIO, R2 and compatible services."""

    def __init__(
        self,
        bucket: str,
        region: str,
        endpoint_url: str | None,
        access_key_id: str | None,
        secret_access_key: str | None,
    ) -> None:
        import boto3  # type: ignore[import-not-found]

        self.bucket = bucket
        self.client = boto3.client(
            "s3",
            region_name=region,
            endpoint_url=endpoint_url,
            aws_access_key_id=access_key_id,
            aws_secret_access_key=secret_access_key,
        )

    def put_object(self, key: str, content: bytes) -> None:
        try:
            self.client.put_object(
                Bucket=self.bucket,
                Key=key,
                Body=content,
                ServerSideEncryption="AES256",
            )
        except Exception as exc:
            raise DomainError("STORAGE_UPLOAD_FAILED", "Document storage failed", 503) from exc

    def get_object(self, key: str) -> bytes:
        try:
            return bytes(self.client.get_object(Bucket=self.bucket, Key=key)["Body"].read())
        except Exception as exc:
            raise DomainError("STORAGE_READ_FAILED", "Document could not be read", 503) from exc

    def delete_object(self, key: str) -> None:
        try:
            self.client.delete_object(Bucket=self.bucket, Key=key)
        except Exception as exc:
            raise DomainError("STORAGE_DELETE_FAILED", "Document deletion failed", 503) from exc

    def exists(self, key: str) -> bool:
        try:
            self.client.head_object(Bucket=self.bucket, Key=key)
            return True
        except Exception:
            return False

    def get_metadata(self, key: str) -> dict[str, Any]:
        try:
            result = self.client.head_object(Bucket=self.bucket, Key=key)
            return {"size": result["ContentLength"], "etag": result.get("ETag")}
        except Exception as exc:
            raise DomainError("STORAGE_READ_FAILED", "Document metadata failed", 503) from exc

    def create_signed_url(self, key: str, expires_seconds: int) -> str:
        try:
            return str(
                self.client.generate_presigned_url(
                    "get_object",
                    Params={"Bucket": self.bucket, "Key": key},
                    ExpiresIn=expires_seconds,
                )
            )
        except Exception as exc:
            raise DomainError(
                "SIGNED_URL_FAILED", "Signed access could not be created", 503
            ) from exc
