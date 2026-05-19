"""Call Tencent Cloud cam:GetUserAppId via raw HTTPS + TC3-HMAC-SHA256 signing.
Reads SecretId/SecretKey from ~/.config/voice-stt/secrets/tencent.env, prints AppID.
"""
import hashlib
import hmac
import json
import time
import urllib.request
from pathlib import Path

SECRETS = Path.home() / ".config" / "voice-stt" / "secrets" / "tencent.env"


def _parse_env(path: Path) -> dict[str, str]:
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def call_get_user_appid(secret_id: str, secret_key: str) -> dict:
    service = "cam"
    host = "cam.tencentcloudapi.com"
    endpoint = f"https://{host}"
    region = ""  # cam is global
    action = "GetUserAppId"
    version = "2019-01-16"
    algorithm = "TC3-HMAC-SHA256"
    timestamp = int(time.time())
    date = time.strftime("%Y-%m-%d", time.gmtime(timestamp))
    payload = "{}"

    # 1. canonical request
    http_method = "POST"
    canonical_uri = "/"
    canonical_querystring = ""
    canonical_headers = (
        f"content-type:application/json; charset=utf-8\n"
        f"host:{host}\n"
        f"x-tc-action:{action.lower()}\n"
    )
    signed_headers = "content-type;host;x-tc-action"
    hashed_payload = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    canonical_request = (
        f"{http_method}\n{canonical_uri}\n{canonical_querystring}\n"
        f"{canonical_headers}\n{signed_headers}\n{hashed_payload}"
    )

    # 2. string to sign
    credential_scope = f"{date}/{service}/tc3_request"
    hashed_canonical = hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
    string_to_sign = (
        f"{algorithm}\n{timestamp}\n{credential_scope}\n{hashed_canonical}"
    )

    # 3. signing key
    def _hmac(key, msg):
        return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

    secret_date = _hmac(("TC3" + secret_key).encode("utf-8"), date)
    secret_service = _hmac(secret_date, service)
    secret_signing = _hmac(secret_service, "tc3_request")

    # 4. signature
    signature = hmac.new(secret_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    # 5. authorization header
    authorization = (
        f"{algorithm} Credential={secret_id}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    req = urllib.request.Request(
        endpoint,
        data=payload.encode("utf-8"),
        method="POST",
        headers={
            "Authorization": authorization,
            "Content-Type": "application/json; charset=utf-8",
            "Host": host,
            "X-TC-Action": action,
            "X-TC-Timestamp": str(timestamp),
            "X-TC-Version": version,
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = resp.read().decode("utf-8")
    return json.loads(body)


if __name__ == "__main__":
    creds = _parse_env(SECRETS)
    sid = creds["TENCENT_SECRET_ID"]
    skey = creds["TENCENT_SECRET_KEY"]
    print(f"SecretId: {sid[:8]}...{sid[-4:]}")
    result = call_get_user_appid(sid, skey)
    print(f"Response: {json.dumps(result, indent=2, ensure_ascii=False)}")
